#!/bin/bash
# Build RPi5 (BCM2712 D0) UEFI firmware on macOS, mirroring build_rpi4.sh.
# Uses the checked-in TF-A bl31.bin from edk2-non-osi (no local TF-A build).
# Usage: ./build_rpi5_macos.sh [RELEASE|DEBUG]
set -e
BUILD_TYPE="${1:-RELEASE}"
export WORKSPACE="$PWD"
export PACKAGES_PATH="$WORKSPACE/edk2:$WORKSPACE/edk2-platforms:$WORKSPACE/edk2-non-osi"
export GCC_AARCH64_PREFIX="aarch64-elf-"
export GCC5_AARCH64_PREFIX="aarch64-elf-"
export PYTHON_COMMAND="$(which python3)"
export EDK_TOOLS_PATH="$WORKSPACE/edk2/BaseTools"

make -C edk2/BaseTools -j"$(sysctl -n hw.ncpu)"

source edk2/edksetup.sh BaseTools

build -a AARCH64 -t GCC -b "$BUILD_TYPE" \
  -p edk2-platforms/Platform/RaspberryPi/RPi5/RPi5.dsc \
  -n "$(sysctl -n hw.ncpu)" \
  "${@:2}"

echo "=== BUILD DONE: $BUILD_TYPE ==="
FD="Build/RPi5/${BUILD_TYPE}_GCC/FV/RPI_EFI.fd"
if [[ ! -f "$FD" ]]; then
  echo "NO FD: $FD" >&2
  exit 1
fi
ls -la "$FD"
echo "FD PRODUCED: $FD"
