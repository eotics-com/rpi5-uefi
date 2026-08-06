# Experimental Raspberry Pi 5 Active Cooler driver

This ARM64 KMDF driver binds to `ACPI\\RPI0FAN`, which is published by the
companion UEFI fan patch. It directly controls the official Raspberry Pi 5
Active Cooler through RP1 PWM1 channel 3 and reads the SoC temperature through
the BCM2712 property mailbox.

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

## Important safety status

This code is experimental and has not been physically tested on a Raspberry Pi
5. It must not replace the wizard's default UEFI or be injected into deployment
media automatically. Keep UEFI in **Persistent manual / 100%** mode until both
the UEFI build and this driver have been tested on the target board.

The test build is not Microsoft-signed. Windows test-signing mode and a trusted
test certificate are required. Production distribution requires proper signing.

Building locally requires Visual Studio 2022 17.11 or newer (or Visual Studio
2026 with the v143 compatibility toolset) and the C++ ARM64 build tools. The
project restores pinned Microsoft WDK/SDK NuGet packages for both the x64 build
host tools and ARM64 target libraries.

No user-mode service or fan-control application is required. A later tool may
use a versioned IOCTL interface, but this first safety-focused driver deliberately
does not expose one.
