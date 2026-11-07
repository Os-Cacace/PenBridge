# PenBridge Installer: guide for Claude Code

You're helping someone install PenBridge on their own hackintosh, usually because the
installer's checks failed and they pasted its "Copy for Claude" report. Read this file
fully before changing anything.

## Ground rules

- **Never write to the EFI partition without the user's explicit go-ahead**, and only
  through `Driver/pentool.sh install` (it backs up `EFI/OC` first and verifies bytes).
  A bad kext or config.plist can stop the Mac from booting. Before any EFI change, make
  sure the user has a bootable USB with a working EFI.
- Mounting the EFI and `pentool.sh diagnose|install|restore` need root. Give the user
  the exact `sudo` command, or have them use the installer's buttons. Don't guess passwords.
- Explain every change before making it. Prefer editing `Driver/patches.conf` over
  editing `pentool.sh`, and both over shipping prebuilt binaries.
- VoodooI2C is GPL-2.0. The installer patches the user's own copy, and every change is
  listed in `patches.conf` and below. Keep it that way: no closed binaries.

## What's in the package

| Path | What it is |
|---|---|
| `PenBridge Installer.app` | SwiftUI installer. Reads `Driver/` next to the app first, else its bundled copy, so editing `Driver/*` needs no rebuild |
| `Driver/pentool.sh` | Root tool: `selftest`, `diagnose`, `install`, `restore` (usage at the top of the file) |
| `Driver/patches.conf` | VoodooI2CHID patch table, one `build` block per supported original binary |
| `Source/PenBridge/` | PenBridge source (Swift, AppKit + SwiftUI, no Xcode project) |
| `Source/Installer/Installer.swift` | The installer app |
| `Source/build.sh` | Rebuilds both apps and the zip. Needs Command Line Tools (`xcode-select --install`) |

Backups go to `~/Library/Application Support/PenBridge/EFI-Backups/`: `EFI-<date>/OC` per
install, `latest` → the newest, `original` → the first backup taken before any patch.
`restore` copies VoodooI2CHID.kext, VoodooI2C's Info.plist and config.plist back from `original`.

## The reference machine

Dell Latitude 7410 2-in-1: Wacom AES digitizer `WCOM4957` (HID 056A:4957) on I2C0
(`PciRoot(0x0)/Pci(0x15,0x0)`), Cirque touchpad on I2C1, OpenCore 1.0.8, VoodooI2C 2.9.1,
macOS 26 Tahoe, HP Active Pen G3 (Bluetooth top button: 04F2:1850).

## What the driver step changes, and why

1. **`force-polling = 1`** under `DeviceProperties > Add > <touchscreen controller>`.
   With GPIO interrupts the touchscreen went permanently silent after a pen + finger burst
   (interrupt counter stuck at 0). Polling never froze. The PCI path comes from walking up
   the IORegistry from the 056A:4957 HID device to its `IOPCIDevice` (`pcidebug` "0:21:0").
2. **VoodooI2CHID binary patches** (all in `patches.conf`). File offsets equal vmaddr in
   this kext (`__TEXT` fileoff 0, vmaddr 0), so `otool -tV` addresses are file offsets.

   **a. Pen first** in `VoodooI2CTouchscreenHIDEventDriver::forwardReport`. Pen reports
   carry no contact count, so a stale count ≥ 2 sent them down the multi-touch branch and
   the pen stuck until a finger touched (VoodooI2C issue #317). The patch moves the
   `checkStylus` call ahead of the `cmpb $0x1, %r12b` contact-count test:

   ```
   original @0x21be                          patched @0x21be
   cmpb   $0x1, %r12b                         movq  %rbx, %rdi
   jne    0x222a                              movq  %r15, %rsi
   movq   %rbx, %rdi                          movq  %r14, %rcx
   movq   %r15, %rsi                          callq checkStylus      (rel32 adjusted)
   movq   %r14, %rcx                          testb %al, %al
   callq  checkStylus                         jne   0x21ef           (rel8 adjusted)
   testb  %al, %al                            cmpb  $0x1, %r12b
   jne    0x21ef                              jne   0x222a           (rel8 adjusted)
   ; 0x21d6: checkFingerTouch, unchanged
   ```

   The 24 bytes are the same instructions reordered, so every relative branch/call
   displacement changes. Recompute them for another build.

   **b. Polling rate** in `VoodooI2CHIDDevice::simulateInterrupt`, which re-arms its timer
   via `setTimeoutMS` (vtable `0x1d0`). Immediates, original → patched:

   | Offset | Instruction | Meaning |
   |---|---|---|
   | 0x78fd | `movl $0x1,%edi` → `$0x0` before `IOSleep` | no 1 ms sleep per poll |
   | 0x7948 | `movl $0x32,%eax` → `$0x8` | idle (no report for ≥1.5 s, `cmpq $0x59682f01`) 50 → 8 ms |
   | 0x794d | `movl $0x2,%esi` → `$0x1` | active 2 → 1 ms |
   | 0x797c | `movl $0x5,%esi` → `$0x8` | before any report 5 → 8 ms |
   | 0x7994 | `movl $0x2,%esi` → `$0x1` | right after a new report 2 → 1 ms |

   (The patch lines point at the immediate byte, one past the opcode.)
3. **VoodooI2C.kext Info.plist** (2.9.1 only): adds `IOParentMatch → IOProviderClass =
   VoodooI2CPrecisionTouchpadHIDEventDriver` to the `Native Multitouch Engine` personality,
   so the touchscreen doesn't get a second virtual trackpad (it stalled WindowServer ~40 s).

Measured result on the reference machine: pen ~300 reports/s, idle kernel_task ~10 %
(vs ~15 % with 1 ms polling all the time), no freezes.

## Porting to a different VoodooI2CHID build

1. Get the user's binary: `diagnose` prints `hid_md5`; the kext is at
   `/Volumes/EFI/EFI/OC/Kexts/VoodooI2CHID.kext` once mounted (`sudo diskutil mount disk0s1`,
   or whichever ESP `diagnose` reports). Copy it somewhere writable.
2. Disassemble: `otool -tV VoodooI2CHID > dis.txt`. Find
   `__ZN34VoodooI2CTouchscreenHIDEventDriver13forwardReport…` and
   `__ZN18VoodooI2CHIDDevice17simulateInterrupt…`. Match them against the listings above.
   If the source changed a lot, read upstream `VoodooI2CTouchscreenHIDEventDriver.cpp` and
   `VoodooI2CHIDDevice.cpp` for that release.
3. Write a new `build` block in `patches.conf`: original md5, then `patch` lines with the
   offset, original hex and new hex. Hand-assemble the reordered block and recompute
   rel8/rel32 displacements (target − address of the next instruction).
4. Run `zsh Driver/pentool.sh selftest <copy of VoodooI2CHID.kext>`. It applies the block to a
   temp copy and checks the md5. Put the resulting md5 into the `build` line's second field.
5. `otool -tV` the patched copy and check that the instructions read as intended.
6. Only then, with the user's OK: installer → Touchscreen driver → Install, then restart.

If the build is very different, it's fine to ship only the polling change (step 1, which
is config-only) and skip binary patches, and say so.

## Porting PenBridge to a different digitizer

PenBridge decodes raw HID reports. On the reference machine:
- `main.swift`: `vendorID = 0x056A`, `productID = 0x4957`, pen report ID 6 (18 bytes:
  [1] bits tip 0x01, barrel 0x02, eraser 0x04, invert 0x08, in range 0x20; [2..3] X,
  [4..5] Y, [6..7] pressure 0-4095, [16]/[17] tilt X/Y in signed degrees),
  `penMaxX = 30931`, `penMaxY = 17399`.
- `Touch.swift`: touch report 12 (40 bytes: contact count at [2], 5 × 7-byte slots from [3]).
- `ButtonTest.swift`: the pen's Bluetooth top button, HID 04F2:1850, sends ⌘F20 / ⌘F19 / ⌘F18.

Get the real values from the device's report descriptor (`ioreg -r -c IOHIDDevice -l`
shows `ReportDescriptor`), then rebuild with `zsh Source/build.sh`.

## Rules learned the hard way (keep them)

- Never open the digitizer and then exit. A permission-failure restart loop wedged the
  kernel HID connection until reboot, so PenBridge waits for permissions before opening.
- `IOHIDDeviceGetValue` and element value callbacks hang on the VoodooI2C device. Read raw reports.
- Never drop a `leftMouseUp` in the event tap; every gesture begin needs an end.
- Don't run `sample` on PenBridge (it stalled the event tap).
- The Input Monitoring prompt reads as keystroke recording. Warn the user before anything
  triggers it.
- GPIO interrupt patches to VoodooGPIO (routing bits, parent IOAPIC disable) did not fix
  the freeze. Polling did. Don't spend time there again.
