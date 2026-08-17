# Experimental Raspberry Pi 5 Active Cooler driver

This ARM64 KMDF driver binds to `ACPI\\RPI000F`, which is published by the
companion UEFI fan patch. It directly controls the official Raspberry Pi 5
Active Cooler through RP1 PWM1 channel 3 and reads the SoC temperature through
the BCM2712 property mailbox.

Current experimental driver version: **0.1.1.0**.

The default curve is:

| Temperature | Fan request |
|---|---:|
| Below 50 C | 30% |
| 50 C | 40% |
| 60 C | 50% |
| 67.5 C | 70% |
| 75 C | 100% |

Downward transitions use 5 C hysteresis. Startup, power-down, mailbox failure,
invalid temperature data, and driver removal all request 100% fan.

## One-shot Windows installer

The experimental GitHub release includes `Install_RPi5Fan_OneShot.cmd`. It is a
self-contained ARM64 installer with the driver package embedded inside it. Run
it on Windows 11 on the Raspberry Pi 5; it requests Administrator privileges,
checks for `ACPI\\RPI000F`, verifies test-signing, installs the included test
certificate, installs/updates the driver, rescans/restarts the device, and checks
the final PnP state.

The installer writes a persistent diagnostic transcript to
`Desktop\\RPi5Fan-install.log`. If the final device state is not healthy, it also
adds matching SetupAPI diagnostics to the same log.

Version 0.1.1 replaces the invalid periodic passive-level KMDF timer with a
re-armed one-shot passive timer and tracks timer lifecycle state across D0 power
transitions. This addresses the observed Code 31 / `STATUS_NOT_SUPPORTED`
failure during device creation.

## Important safety status

This code is experimental and has not been physically tested on a Raspberry Pi
5. It must not replace the wizard's default UEFI or be injected into deployment
media automatically. Keep UEFI in **Persistent manual / 100%** mode until both
the UEFI build and this driver have been tested on the target board.

The test build is not Microsoft-signed. Windows test-signing mode and a trusted
test certificate are required. The one-shot installer handles certificate
installation but cannot avoid the required reboot if it has to enable Windows
test-signing mode. Production distribution requires proper signing.

Building locally requires Visual Studio 2022 17.11 or newer (or Visual Studio
2026 with the v143 compatibility toolset) and the C++ ARM64 build tools. The
project restores pinned Microsoft WDK/SDK NuGet packages for both the x64 build
host tools and ARM64 target libraries.

No user-mode service or fan-control application is required. A later tool may
use a versioned IOCTL interface, but this safety-focused driver deliberately
does not expose one.
