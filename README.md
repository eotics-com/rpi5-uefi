# Raspberry Pi 5 UEFI

TF-A and EDK2 firmware for the Raspberry Pi 5 and Compute Module 5, including
boards based on the BCM2712 D0 revision.

![EDK2 setup screen](images/edk2_setup_screen.png)

## Project lineage

This repository is the second continuation of the original Raspberry Pi 5 UEFI
work:

- [Mario Bălănică](https://github.com/worproject) created the original port,
  including the early platform, ACPI, USB, SD, PCIe, RTC and display support.
- [Matt P](https://github.com/NumberOneGit) carried it forward for BCM2712 D0
  boards and CM5, fixed the changed pin control and UART/display setup, and kept
  it building with newer EDK2 revisions.
- This fork rebases that work on current upstream firmware projects and extends
  the ACPI hand-off for RP1 Ethernet and USB, SDIO Wi-Fi, microSD and
  VideoCore VII.

Thank you to Mario and Matt. This branch exists because of the work they did
first.

## What is new in this branch

- The four firmware dependencies are rebased on their current upstream
  `master` branches and published as matching `rpi5` branches.
- RP1 Ethernet and USB are initialized before the OS starts. ACPI describes the
  devices and the firmware supplies the board MAC address.
- ACPI now describes the Wi-Fi SDIO host, its power control, and VideoCore VII.
- The OS owns microSD slot power through an ACPI power resource. The EDK2 SD
  host also has the BCM2712 signaling-voltage override needed for UHS modes.
- FreeLoader is recognized during ACPI hand-off so ReactOS receives the
  Windows-compatible PCIe layout.
- `build.sh` works on Linux and macOS. CI builds both Debug and Release images
  and records the exact revisions and SHA-256 hashes used for each release.

## Current status

“Working after OS hand-off” means the firmware initializes and describes the
hardware, while the operating system still needs a suitable driver.

| Area | Status | Notes |
| --- | --- | --- |
| UEFI setup and boot | Working | Raspberry Pi 5 and CM5, including D0 boards. |
| HDMI framebuffer | Working | Display is provided by the VideoCore firmware. Use a current Raspberry Pi EEPROM on D0 boards. |
| RP1 USB | Working | Both xHCI controllers are initialized and exposed through ACPI. |
| PCIe and NVMe | Working | Gen 2 is the default; Gen 3 can be selected in setup. |
| microSD | Unknown | UEFI supports modes up to SDR104. ACPI power and voltage switching are included; the final speed depends on the OS driver. |
| RP1 Ethernet | **Working after OS hand-off** | The GEM/PHY is initialized, the MAC address is programmed, and ACPI exposes a Cadence GEM-compatible device. A matching OS driver is required; UEFI PXE is not provided. |
| SDIO Wi-Fi | Partial | The host and power resource are described in ACPI. The OS still needs the CYW43455 driver and firmware. |
| VideoCore VII | Partial | Mailbox, clock and memory resources are described in ACPI. 3D acceleration remains an OS-driver concern. |
| UART | Working | PL011 on the dedicated connector at `115200 8n1`. |
| RTC and RNG | Working | RTC time/alarm and the hardware random-number source are available. |
| CM5 eMMC | Unknown | Use NVMe or USB when dependable eMMC boot is required. |
| RP1 GPIO and PWM | Not exposed | There are no general-purpose ACPI devices for these blocks yet. |
| Persistent UEFI variables | Limited | EEPROM-backed NVRAM is not implemented. |

ACPI support depends on the drivers available in the operating system. Device
Tree mode remains the best choice for the Raspberry Pi downstream Linux kernel
when full native hardware support is more important than a generic ACPI boot.

## Install

You need:

- a FAT32-formatted SD card, USB drive or NVMe drive;
- a reliable power supply and cable (the official 27 W supply is recommended);
- cooling for sustained workloads;
- optionally, a 3.3 V UART adapter for serial output.

Download the latest archive from
[Releases](https://github.com/eotics-com/rpi5-uefi/releases), then extract it to
the root of the FAT32 boot partition. Keep the filenames and directory layout
unchanged.

On power-up, the Raspberry Pi boot screen is followed by the EDK2 logo. Press
<kbd>Esc</kbd> for setup or <kbd>F1</kbd> for the UEFI Shell.

## Configuration

### PCI Express

The external PCIe link defaults to Gen 2. Change it under
`Device Manager` → `Raspberry Pi Configuration` → `PCI Express` → `Link Speed`.

Raspberry Pi does not rate the board for PCIe Gen 3. Whether it is reliable
depends on the adapter, cabling, device and power supply.

### Linux

- If a distribution stops with a synchronous exception, disable
  `Device Manager` → `EFI Memory Attribute Protocol` → `Enable Protocol`.
- For faster SD modes, select `Full Bay Trail` under
  `Raspberry Pi Configuration` → `ACPI / Device Tree` → `Compatibility Mode`,
  then disable `Limit UHS-I Modes`. This can reduce compatibility with other
  operating systems.
- If PCIe is not detected, set `ECAM Compatibility Mode` to
  `AMAZON GRAVITON`.
- For the Raspberry Pi downstream kernel, set `System Table Mode` to
  `Device Tree`.

## Build

Clone the `rpi5` branch with all submodules:

```sh
git clone --branch rpi5 --recurse-submodules \
  https://github.com/eotics-com/rpi5-uefi.git
cd rpi5-uefi
```

On Ubuntu or Debian:

```sh
sudo apt install \
  acpica-tools binutils-aarch64-linux-gnu build-essential \
  device-tree-compiler gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
  python3 python3-pyelftools uuid-dev
```

On Arch Linux:

```sh
sudo pacman -S --needed \
  aarch64-linux-gnu-binutils aarch64-linux-gnu-gcc \
  aarch64-linux-gnu-glibc base-devel dtc git iasl python \
  python-pyelftools
```

On macOS, install an `aarch64-elf-` GCC toolchain plus GNU Make, GNU sed, IASL,
the device-tree compiler and Python with pyelftools. `build.sh` detects
Homebrew's `gmake` and GNU sed automatically.

Build a Release image:

```sh
./build.sh
```

Build a Debug image:

```sh
./build.sh --debug 1
```

The result is `RPI_EFI.fd`. Run `./build.sh --help` for the remaining options.

## Licenses

Most files use the EDK2
[BSD-2-Clause-Patent license](https://github.com/tianocore/edk2/blob/master/License.txt).
TF-A uses its
[upstream license](https://github.com/ARM-software/arm-trusted-firmware/blob/master/docs/license.rst).
