# IntelISH (Comet Lake port): the accelerometer behind auto-rotate

A macOS kernel extension for the Intel Integrated Sensor Hub. It reads the laptop's
accelerometer and publishes each reading in IORegistry, where Touchintosh's auto-rotate
picks it up. No Lilu or VirtualSMC needed.

This is a port of [yjmd2222/IntelISH](https://github.com/yjmd2222/IntelISH) (commit in
`UPSTREAM.txt`), which was written for the HP Elite x2 1012 G2. It is licensed
**GPL-2.0-only**, like the original (see `LICENSE`); the rest of Touchintosh is MIT.

## What changed from upstream

- Also matches Cannon Lake and Comet Lake hubs: `8086:9dfc`, `8086:a37c`, `8086:02fc`.
- Works without an interrupt line (the Comet Lake hub has no MSI and no routed INTx):
  the 10 ms timer drains the mailbox.
- The VirtualSMC light-sensor keys are gone. The light sensor is off unless the boot-arg
  `-ishals` is set; `SMCLightSensor` already covers it.
- Report fields wider than 32 bits (Dell's 192-bit custom values) are skipped, not rejected.
- The response status byte isn't checked, as in Linux: Comet Lake firmware answers
  `GET_FEATURE` with status `0xff` and a valid report.
- Messages nobody asked for are ignored and the last eight kept in IORegistry
  (`Unexpected-N`). A failed step degrades (skip the feature setup, then only listen)
  instead of stopping the driver.
- Report descriptors are always published (`ReportDescriptor-N`), and start-up problems
  show as `StartError` or `TransportError`, because kext log lines don't always reach
  the system log.
- A diagnostics channel for porting, off unless the personality in `Info.plist` has
  `DebugRequests = true` (see the comment above `setProperties` in `src/IntelISH.cpp`).

## Tested on

Dell Latitude 7410 2-in-1 (`8086:02fc`), macOS 26 Tahoe, OpenCore 1.0.8. Other laptops
are untested; if the driver can't use a hub it stays idle and changes nothing.

## Install

Keep a bootable USB with a working EFI first: this changes how the Mac boots.

```bash
sudo zsh Driver/IntelISH/install.sh
```

It backs up `config.plist`, copies `IntelISH.kext` to `EFI/OC/Kexts`, and adds one
`Kernel > Add` entry. Restart, then turn on **Rotate the screen automatically** in
Touchintosh's Touch tab. To switch the driver off again:

```bash
sudo zsh Driver/IntelISH/install.sh off
```

The release zip includes a built `IntelISH.kext`. From a git checkout, build it first:

```bash
zsh Driver/IntelISH/build.sh    # needs the Command Line Tools; clones MacKernelSDK
```

## Checking it

```bash
ioreg -r -c IntelISH -l -w0 | grep -E '"(TransportState|TransportError|StartError|AccelSample)"'
```

`AccelSample` holds `RawX`, `RawY` and `RawZ` in micro-g (as 64-bit two's complement).
The axes follow the Windows sensor convention: X to the screen's right, Y to its top, and
the axis that points up reads −1 g, so a laptop in normal use reads about y = −0.9.
