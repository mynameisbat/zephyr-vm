# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Zephyr is a lightweight Android emulator for Apple Silicon Macs. It runs LineageOS (Android 17, `virtio_arm64only` build from github.com/jqssun/android-lineage-qemu) under Apple's Virtualization.framework. There is no QEMU and no Android SDK. The user writes in Vietnamese, and UI strings are in Vietnamese.

## Build & run

```bash
scripts/build.sh                    # debug: builds .build/debug/zephyrctl and build/Zephyr.app, ad-hoc signed
CONFIG=release scripts/build.sh
open build/Zephyr.app               # or: build/Zephyr.app/Contents/MacOS/Zephyr --open <device name>
```

- **Use `scripts/build.sh`, not bare `swift build`.**
  - Every binary that touches Virtualization.framework must be codesigned with `Resources/Zephyr.entitlements` (`com.apple.security.virtualization`). Otherwise VM start fails.
  - This machine has only Command Line Tools, no Xcode. The macOS 27.x SDK makes SwiftUI's `@State` a macro whose plugin ships only with Xcode, so the script sets `SDKROOT` to `MacOSX26.5.sdk`. A manual build needs the same: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build`.
- **No test target, and no linter.** Verify changes by booting a VM, as described below.
- **Language mode is Swift 5** (`swiftLanguageModes: [.v5]`). Concurrency issues show up as warnings, not errors.

## Verifying changes end to end

The CLI and `adb` (installed at `/opt/homebrew/bin/adb`) let you check the guest without the GUI:

```bash
export ZEPHYR_HOME=$PWD/.cache/home      # optional: isolated data root instead of ~/Library/Application Support/ZephyrVM
.build/debug/zephyrctl import <UTM-VM-*.zip | *.utm | vda.qcow2>
.build/debug/zephyrctl create <name> [--display phone-hd|WxH@DPI] [--memory MiB] [--logcat]
.build/debug/zephyrctl run <name> --console          # run in background; kernel console on stdout
adb connect 127.0.0.1:5555 && adb -s 127.0.0.1:5555 exec-out screencap -p > shot.png
.build/debug/zephyrctl shell <cmd>                   # exercises Zephyr's own Swift ADB client
.build/debug/zephyrctl swipe x1 y1 x2 y2             # exercises InputInjector (normalised 0…1)
```

- **Boot completion:** `getprop sys.boot_completed` returns `1`, typically 6–14 s after start.
- **Clean shutdown:** `adb shell reboot -p` powers the guest off cleanly.
- **Screenshots of app windows:**
  - `screencapture -l <windowID>` fails here because this process lacks screen-recording permission.
  - Full-screen `screencapture -x` works. Bring the app forward first with `osascript -e 'tell application id "dev.zephyrvm.Zephyr" to activate'`.

## Architecture

There are three targets:
- `ZephyrCore`: the engine; it has no UI code.
- `ZephyrApp`: SwiftUI app; the executable is named `Zephyr`.
- `zephyrctl`: the CLI.

Both the app and the CLI drive the same core types.

### Boot path

The VM boots directly with `VZLinuxBootLoader`. It skips EFI and GRUB, even though the image contains them.

1. **Import (`ImageStore.importImage`):** unzips with `ditto`, converts `vda.qcow2` to a sparse raw `system.img` (`QCOW2Converter`), then runs `BootArtifacts.extract`.
2. **Extract (`BootArtifacts.extract`):** reads the GPT and parses `boot` (header v3/v4) and `vendor_boot` (v4) partitions.
   - Writes an uncompressed `kernel`.
   - Writes `initrd.img`, built from: generic ramdisk, then vendor platform and DLKM fragments, then a bootconfig trailer (`BootConfig.encode`).
   - This order mirrors the image's own GRUB config. Recovery fragments are excluded.
3. **Kernel command line (`VirtualMachineFactory.kernelCommandLine`):** the boot cmdline plus the vendor_boot cmdline, plus Zephyr's additions:
   - `console=hvc0`
   - `androidboot.lcd_density`
   - `androidboot.insecure_adb=1`
   - `androidboot.zram=1`
   - `androidboot.nobootanim=1`
   - Put per-VM `androidboot.*` values on the cmdline, not in bootconfig: duplicate bootconfig keys are an error, and cmdline values win.

### Guest device contract

The LineageOS image hard-codes several assumptions about devices, set in `VirtualMachineFactory`:
- **Storage order:**
  - `vda` must be the system disk. The image's init symlinks `vda1..11` to partition names.
  - `vdb` must be userdata (`androidboot.partition_map`).
  - `storageDevices` order therefore matters.
- **Shared folder:** virtio-fs tag `share` is mounted at `/mnt/vendor/shared`.
- **Serial ports:** `hvc0` is the kernel console (`console.log`); `hvc1` carries logcat when `serialLogcat` is set.
- **Graphics:** virtio-gpu has no 3D, so the guest auto-selects SwiftShader. In that mode red and blue arrive swapped. `ScreenContainerView` fixes this with a `CIColorMatrix` `contentFilters` on the `VZVirtualMachineView`.

### ADB and input

- **ADB transport:** adbd listens on vsock port 5555, with no authentication because of `insecure_adb`. The shell user is not root, and `adb root` is disabled.
- **ADB clients:**
  - `ADBClient` is Zephyr's own Swift implementation of the ADB wire protocol. It runs over any stream fd: a vsock connection (the app) or TCP (the CLI).
  - `VsockForwarder` exposes guest port 5555 on `127.0.0.1:5555` (or the next free odd port) for the standard `adb` CLI.
- **Touch input:**
  - VZ's USB pointer ("Apple Inc. Virtual USB Digitizer") is ignored by Android, and the macOS 27 `VZCustomVirtioDevice` API cannot implement virtio-input (its config space is driven by guest writes).
  - So `InputInjector` streams JSON to Android's built-in `uinput -` tool via `exec:` over ADB. It registers a multi-touch screen (id 1) and a button pad (id 2), and collapses consecutive move events.
  - Events sent in the first ~0.7 s, before Android registers the devices, are held back.
- **Keyboard:** typing goes through VZ's USB keyboard, which needs `VZVirtualMachineView` to be first responder. `TouchOverlayView` therefore must not accept first responder.

### Runtime layering

- **`MachineController`** (`@MainActor`) owns the `VZVirtualMachine` and the console pipes. VZ delegate callbacks can arrive off the main thread; hop with `Task { @MainActor in }`, not `MainActor.assumeIsolated`, which crashed.
- **`DeviceSession`** (app) adds the forwarder, the ADB client and the input injector on top. It tracks phases: kernel → android (adbd reachable) → ready (`sys.boot_completed`).
  - Shutdown sends `reboot -p` over ADB and falls back to a hard stop.
  - `AppDelegate` shuts every running VM down before the app quits.
- **Blocking ADB calls** run through `DeviceSession.background`.

### On-disk layout

Everything lives under `ZephyrPaths.root`: `$ZEPHYR_HOME`, or `~/Library/Application Support/ZephyrVM`.
- `Images/<id>/`: `manifest.json`, `system.img`, `kernel`, `initrd.img`.
- `Machines/<uuid>.zvm/`: `config.json` (`MachineSpec`), `system.img`, `userdata.img`, `machine-id.bin`, and logs.
  - `system.img` is an APFS clone of the image's disk, so it costs no space until written.
  - `userdata.img` is a sparse file; Android formats it on first boot.
- `Shared/`: the folder shared with the guest.

`.cache/` holds local downloads and dev data and is gitignored.
