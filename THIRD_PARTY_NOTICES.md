# Third-party notices

## Soulveig Raspberry Pi 5 UEFI fan work

Portions of the experimental Raspberry Pi 5 fan implementation were adapted
from Soulveig's `rpi5-uefi-soulveig-edition`, including the modular firmware
fan controller, the RP1 PWM fan interface, firmware configuration modes, and
the persistent state handoff at ExitBootServices.

Reference source:
<https://github.com/Soulveig/rpi5-uefi-soulveig-edition>

Reference commit and patch used during development:
`4798a1d56f6d579680912b3a0b8285690e62390f`,
`patches/0001-rpi5-esxi-acpi-waveshare-fan.patch`.

The candidate in this repository adds an official Active Cooler temperature
curve, fail-safe behavior, revised RP1 register programming cross-checked
against Raspberry Pi Linux, an ACPI device contract, and an experimental
Windows ARM64 KMDF driver.

Copyright (c) 2026, Soulveig and contributors. All rights reserved.

License: BSD-2-Clause-Patent. The complete license text is in
`LICENSES/Soulveig-BSD-2-Clause-Patent.txt`.
