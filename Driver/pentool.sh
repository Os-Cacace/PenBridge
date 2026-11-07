#!/bin/zsh
# PenBridge driver tool: patches VoodooI2CHID in the OpenCore EFI for smooth pen input,
# turns on touchscreen polling, and can undo both. See CLAUDE.md before changing anything.
#
#   pentool.sh selftest <VoodooI2CHID.kext>                  no root, no EFI: patches a temp copy
#   pentool.sh diagnose <backup-dir> <owner> <pci-path>      root: reads the EFI, changes nothing
#   pentool.sh install  <backup-dir> <owner> <pci-path>      root: backs up, then patches
#   pentool.sh restore  <backup-dir> <owner> <pci-path>      root: puts the original files back
#
# <pci-path> is the touchscreen's I2C controller, e.g. PciRoot(0x0)/Pci(0x15,0x0).
# Output lines start with INFO, STEP, WARN, FAIL or DONE; the installer app shows them.
setopt no_unset pipe_fail
CMD=${1:-} BACKUPS=${2:-} OWNER=${3:-} PCI=${4:-}
HERE=${0:A:h}
CONF=$HERE/patches.conf
PB=/usr/libexec/PlistBuddy
MOUNTED_HERE=0 ESP=

say()  { print -r -- "$*" }
cleanup() { [[ $MOUNTED_HERE == 1 ]] && diskutil unmount $ESP >/dev/null 2>&1; true }
fail() { say "FAIL $*"; cleanup; exit 1 }

hexbytes() {  # "4180fc" -> the printf escapes \x41\x80\xfc
  local h=$1 out= i
  for (( i = 1; i <= ${#h}; i += 2 )); do out+="\\x${h[i,i+1]}"; done
  print -r -- $out
}

# Sets HID_STATE (original / patched / unknown), BUILD_LINE and RESULT_MD5 for an md5.
match_build() {
  local md5=$1 n=0 line parts
  HID_STATE=unknown BUILD_LINE=0 RESULT_MD5=
  while IFS= read -r line; do
    (( n++ ))
    [[ $line == build\ * ]] || continue
    parts=(${=line})
    if [[ ${parts[2]} == $md5 ]]; then HID_STATE=original BUILD_LINE=$n RESULT_MD5=${parts[3]}; say "INFO hid_build=${parts[4,-1]}"; fi
    if [[ ${parts[3]} == $md5 ]]; then HID_STATE=patched; say "INFO hid_build=${parts[4,-1]}"; fi
  done < $CONF
}

# Applies the patch lines under BUILD_LINE to a binary, checking every original byte first.
apply_patches() {
  local bin=$1 n=0 line p off old new len have
  while IFS= read -r line; do
    (( n++ ))
    (( n > BUILD_LINE )) || continue
    [[ $line == build\ * ]] && break
    [[ $line == patch\ * ]] || continue
    p=(${=line})
    off=$(( p[2] )) old=${p[3]} new=${p[4]} len=$(( ${#p[3]} / 2 ))
    [[ ${#old} == ${#new} ]] || fail "patches.conf: original and new bytes differ in length at ${p[2]}."
    have=$(xxd -s $off -l $len -p $bin | tr -d '\n')
    [[ $have == $old ]] || fail "Byte check failed at ${p[2]} (found $have, expected $old). Nothing in the EFI was changed."
    printf "$(hexbytes $new)" | dd of=$bin bs=1 seek=$off conv=notrunc 2>/dev/null || fail "Couldn't write the patch at ${p[2]}."
    say "STEP Patched ${p[2]}: ${p[5,-1]}"
  done < $CONF
  [[ $(md5 -q $bin) == $RESULT_MD5 ]] || fail "The patched driver's md5 is $(md5 -q $bin), not the expected $RESULT_MD5. Nothing in the EFI was changed."
}

if [[ $CMD == selftest ]]; then
  KEXT=${2:-}
  [[ -f $KEXT/Contents/MacOS/VoodooI2CHID ]] || fail "Usage: pentool.sh selftest <VoodooI2CHID.kext>"
  match_build $(md5 -q $KEXT/Contents/MacOS/VoodooI2CHID)
  say "INFO hid_state=$HID_STATE"
  [[ $HID_STATE == original ]] || fail "This binary isn't an original listed in patches.conf."
  TMP=$(mktemp -d)
  cp -R $KEXT $TMP/VoodooI2CHID.kext
  apply_patches $TMP/VoodooI2CHID.kext/Contents/MacOS/VoodooI2CHID
  say "DONE selftest: patched copy at $TMP/VoodooI2CHID.kext matches $RESULT_MD5"
  exit 0
fi

[[ $EUID == 0 ]] || fail "This needs administrator rights."
[[ -n $CMD && -n $BACKUPS && -n $OWNER ]] || fail "Usage: pentool.sh diagnose|install|restore <backup-dir> <owner> <pci-path>"

# --- The EFI partition on the startup disk ----------------------------------------------
find_esp() {
  local store whole i=0 id content
  store=$(diskutil info -plist / | plutil -extract APFSPhysicalStores.0.APFSPhysicalStore raw - 2>/dev/null) || return 1
  whole=$(diskutil info -plist $store | plutil -extract ParentWholeDisk raw - 2>/dev/null) || return 1
  while id=$(diskutil list -plist $whole | plutil -extract AllDisksAndPartitions.0.Partitions.$i.DeviceIdentifier raw - 2>/dev/null); do
    content=$(diskutil list -plist $whole | plutil -extract AllDisksAndPartitions.0.Partitions.$i.Content raw - 2>/dev/null)
    [[ $content == EFI ]] && { print $id; return 0 }
    (( i++ ))
  done
  return 1
}

ESP=$(find_esp) || fail "Couldn't find the EFI partition of the startup disk."
MP=$(diskutil info -plist $ESP | plutil -extract MountPoint raw - 2>/dev/null)
if [[ -z $MP ]]; then
  diskutil mount $ESP >/dev/null || fail "Couldn't mount the EFI partition $ESP."
  MOUNTED_HERE=1
  MP=$(diskutil info -plist $ESP | plutil -extract MountPoint raw - 2>/dev/null)
fi
OC=$MP/EFI/OC
CFG=$OC/config.plist
HID=$OC/Kexts/VoodooI2CHID.kext
HIDBIN=$HID/Contents/MacOS/VoodooI2CHID
I2C=$OC/Kexts/VoodooI2C.kext
[[ -f $OC/OpenCore.efi && -f $CFG ]] || fail "No OpenCore found on $ESP ($MP/EFI/OC)."
say "INFO esp=$ESP"
say "INFO opencore=$(nvram 4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102:opencore-version 2>/dev/null | awk '{print $2}')"

# --- Current state ------------------------------------------------------------------------
VAULT=$($PB -c "Print :Misc:Security:Vault" $CFG 2>/dev/null)
say "INFO vault=$VAULT"
HIDMD5=$([[ -f $HIDBIN ]] && md5 -q $HIDBIN || print missing)
say "INFO hid_md5=$HIDMD5"
I2CMD5=$([[ -f $I2C/Contents/MacOS/VoodooI2C ]] && md5 -q $I2C/Contents/MacOS/VoodooI2C || print missing)
say "INFO voodooi2c_md5=$I2CMD5"
say "INFO voodooi2c_version=$($PB -c 'Print :CFBundleShortVersionString' $I2C/Contents/Info.plist 2>/dev/null)"

HID_ENABLED=no
i=0
while BP=$($PB -c "Print :Kernel:Add:$i:BundlePath" $CFG 2>/dev/null); do
  [[ $BP == VoodooI2CHID.kext && $($PB -c "Print :Kernel:Add:$i:Enabled" $CFG) == true ]] && HID_ENABLED=yes
  (( i++ ))
done
say "INFO hid_enabled=$HID_ENABLED"

match_build $HIDMD5
say "INFO hid_state=$HID_STATE"

POLL=
[[ $PCI == PciRoot* ]] && POLL=$($PB -c "Print :DeviceProperties:Add:$PCI:force-polling" $CFG 2>/dev/null)
say "INFO polling=${POLL:-off}"

# VoodooI2C 2.9.1 adds a second virtual trackpad for the touchscreen, which stalls
# WindowServer; limiting its Native Multitouch Engine to the touchpad avoids it.
MT_KEY=":IOKitPersonalities:Native Multitouch Engine"
MT_STATE=n/a
if [[ $I2CMD5 == f8ec82bb5c8bae6ef4d9d625526fcd40 ]]; then
  $PB -c "Print $MT_KEY:IOParentMatch" $I2C/Contents/Info.plist >/dev/null 2>&1 && MT_STATE=done || MT_STATE=needed
fi
say "INFO multitouch_fix=$MT_STATE"
say "INFO original_backup=$([[ -e $BACKUPS/original ]] && readlink $BACKUPS/original || print none)"

backup() {
  local dir=$BACKUPS/EFI-$(date +%Y%m%d-%H%M%S)
  mkdir -p $dir || fail "Couldn't create the backup folder $dir."
  cp -R $OC $dir/OC || fail "Couldn't back up the EFI."
  ln -sfn $dir $BACKUPS/latest
  # The first backup taken before any change is what Restore goes back to.
  [[ -e $BACKUPS/original || $HID_STATE != original ]] || ln -sfn $dir $BACKUPS/original
  chown -R $OWNER $BACKUPS 2>/dev/null
  say "STEP Backed up the whole EFI/OC folder to $dir"
}

case $CMD in
diagnose)
  say "DONE diagnose"
  ;;

install)
  [[ $VAULT == Optional ]] || fail "OpenCore Vault is on ($VAULT). Changing kexts or config.plist would stop the Mac from booting, so nothing was changed."
  [[ $HID_ENABLED == yes ]] || fail "VoodooI2CHID.kext isn't enabled in this config.plist, so this setup doesn't match. Nothing was changed."
  [[ $HID_STATE != unknown ]] || fail "This VoodooI2CHID ($HIDMD5) isn't in patches.conf. Nothing was changed. Use the Claude helper to add it."
  [[ $PCI == PciRoot* ]] || fail "The touchscreen controller's PCI path is unknown. Nothing was changed."
  plutil -lint -s $CFG || fail "config.plist doesn't pass plutil -lint. Nothing was changed."
  backup

  if [[ $HID_STATE == original ]]; then
    TMP=$(mktemp -d)/VoodooI2CHID.kext
    cp -R $HID $TMP || fail "Couldn't copy VoodooI2CHID."
    apply_patches $TMP/Contents/MacOS/VoodooI2CHID
    rm -rf $HID && cp -R $TMP $HID || fail "Couldn't copy the patched driver into the EFI. Restore from $BACKUPS/latest."
    say "STEP Installed the patched VoodooI2CHID ($(md5 -q $HIDBIN))"
  else
    say "STEP VoodooI2CHID was already patched"
  fi

  if [[ -z $POLL ]]; then
    $PB -c "Add :DeviceProperties:Add:$PCI dict" $CFG 2>/dev/null
    $PB -c "Add :DeviceProperties:Add:$PCI:force-polling integer 1" $CFG || fail "Couldn't add touchscreen polling to config.plist. Restore from $BACKUPS/latest."
    plutil -lint -s $CFG || fail "config.plist no longer passes plutil -lint. Restore from $BACKUPS/latest."
    say "STEP Turned on touchscreen polling for $PCI"
  else
    say "STEP Touchscreen polling was already on"
  fi

  if [[ $MT_STATE == needed ]]; then
    $PB -c "Add $MT_KEY:IOParentMatch dict" -c "Add $MT_KEY:IOParentMatch:IOProviderClass string VoodooI2CPrecisionTouchpadHIDEventDriver" $I2C/Contents/Info.plist \
      || fail "Couldn't change VoodooI2C's Info.plist. Restore from $BACKUPS/latest."
    say "STEP Limited VoodooI2C's multitouch engine to the touchpad"
  fi
  say "DONE install"
  ;;

restore)
  [[ $VAULT == Optional ]] || fail "OpenCore Vault is on ($VAULT), so nothing was changed."
  SRC=$BACKUPS/original/OC
  [[ -d $SRC ]] || SRC=$BACKUPS/latest/OC
  [[ -d $SRC/Kexts/VoodooI2CHID.kext && -f $SRC/config.plist ]] || fail "No complete backup found in $BACKUPS. Nothing was changed."
  rm -rf $HID && cp -R $SRC/Kexts/VoodooI2CHID.kext $HID || fail "Couldn't restore VoodooI2CHID. The full backup is in $SRC."
  [[ -f $SRC/Kexts/VoodooI2C.kext/Contents/Info.plist ]] && cp $SRC/Kexts/VoodooI2C.kext/Contents/Info.plist $I2C/Contents/Info.plist
  cp $SRC/config.plist $CFG || fail "Couldn't restore config.plist. The full backup is in $SRC."
  say "STEP Restored VoodooI2CHID, VoodooI2C's Info.plist and config.plist from ${SRC:h}"
  say "DONE restore"
  ;;

*) fail "Unknown command $CMD" ;;
esac
cleanup
