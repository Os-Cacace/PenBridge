#!/bin/zsh
# Adds IntelISH.kext to the OpenCore EFI of the startup disk, or switches it off.
#   sudo zsh Driver/IntelISH/install.sh [IntelISH.kext]   install or update, then restart
#   sudo zsh Driver/IntelISH/install.sh off               keep the kext, disable it in config.plist
# config.plist is backed up first to ~/Library/Application Support/Touchintosh/EFI-Backups.
# Keep a bootable USB with a working EFI before changing how the Mac boots.
set -e
HERE=${0:A:h}
fail() { print -u2 "$1"; exit 1 }
[[ $EUID == 0 ]] || fail "Run with sudo."
OWNER=${SUDO_USER:-$USER}; HOMEDIR=$(eval echo ~$OWNER)
MODE=on KEXT=
if [[ $1 == off ]]; then MODE=off
else
  for k in "$1" $HERE/IntelISH.kext $HERE/build/IntelISH.kext; do
    [[ -n $k && -f $k/Contents/MacOS/IntelISH ]] && { KEXT=$k; break }
  done
  [[ -n $KEXT ]] || fail "IntelISH.kext not found. Build it with: zsh $HERE/build.sh"
fi

# The EFI partition on the startup disk.
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
  MP=$(diskutil info -plist $ESP | plutil -extract MountPoint raw - 2>/dev/null)
fi
OC=$MP/EFI/OC; CFG=$OC/config.plist
[[ -f $CFG ]] || fail "No OpenCore config at $CFG."
VAULT=$(plutil -extract Misc.Security.Vault raw $CFG 2>/dev/null || print Optional)
[[ $VAULT == Optional ]] || fail "OpenCore Vault is on ($VAULT), so config.plist can't be changed. Nothing was changed."

BACKUPS="$HOMEDIR/Library/Application Support/Touchintosh/EFI-Backups"
[[ -d "$HOMEDIR/Library/Application Support/PenBridge/EFI-Backups" ]] && BACKUPS="$HOMEDIR/Library/Application Support/PenBridge/EFI-Backups"
mkdir -p "$BACKUPS"
BACKUP="$BACKUPS/config-$(date +%Y%m%d-%H%M%S)-pre-intelish.plist"
cp $CFG "$BACKUP"; chown -R $OWNER "$BACKUPS"
print "Backed up config.plist to $BACKUP"

# plistlib keeps the Kernel > Add array in order (PlistBuddy's array Add misplaces entries).
python3 -I - "$CFG" $MODE <<'PY'
import plistlib, sys
path, mode = sys.argv[1], sys.argv[2]
with open(path, 'rb') as f: c = plistlib.load(f)
add = c['Kernel']['Add']
entry = next((k for k in add if isinstance(k, dict) and k.get('BundlePath') == 'IntelISH.kext'), None)
if mode == 'off':
    if entry: entry['Enabled'] = False
elif entry: entry['Enabled'] = True
else:
    add.append({'Arch': 'x86_64', 'BundlePath': 'IntelISH.kext', 'Comment': 'Intel sensor hub accelerometer (auto-rotate)',
                'Enabled': True, 'ExecutablePath': 'Contents/MacOS/IntelISH', 'MaxKernel': '', 'MinKernel': '',
                'PlistPath': 'Contents/Info.plist'})
with open(path, 'wb') as f: plistlib.dump(c, f, sort_keys=False)
PY
plutil -lint $CFG >/dev/null || { cp "$BACKUP" $CFG; fail "config.plist didn't validate; the backup was put back." }
if [[ $MODE == off ]]; then sync; diskutil unmount $ESP >/dev/null 2>&1; print "IntelISH is switched off. Restart to apply."; exit 0; fi
rm -rf $OC/Kexts/IntelISH.kext
cp -R $KEXT $OC/Kexts/IntelISH.kext
[[ $(md5 -q $OC/Kexts/IntelISH.kext/Contents/MacOS/IntelISH) == $(md5 -q $KEXT/Contents/MacOS/IntelISH) ]] || fail "The copied kext doesn't match. Check the EFI partition."
# Unmount so every write reaches the disk before a restart; otherwise OpenCore can boot
# without the kext.
sync; diskutil unmount $ESP >/dev/null 2>&1 || true
print "IntelISH.kext $(plutil -extract CFBundleShortVersionString raw $KEXT/Contents/Info.plist) installed. Restart to load it."
