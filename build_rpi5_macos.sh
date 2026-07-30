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

EDK2_SD_PATCH="$WORKSPACE/temporary-patches/edk2/0001-MdeModulePkg-SdMmcPciHcDxe-Add-platform-signaling-vo.patch"
EDK2_SD_PATCH_APPLIED=0

restore_edk2_sd_patch() {
  if [[ "$EDK2_SD_PATCH_APPLIED" -eq 1 ]]; then
    git -C "$WORKSPACE/edk2" apply --reverse "$EDK2_SD_PATCH"
    echo "Restored clean edk2 worktree"
  fi
}
trap restore_edk2_sd_patch EXIT

if git -C "$WORKSPACE/edk2" apply --check "$EDK2_SD_PATCH" 2>/dev/null; then
  git -C "$WORKSPACE/edk2" apply "$EDK2_SD_PATCH"
  EDK2_SD_PATCH_APPLIED=1
  echo "Applied temporary RPi5 SD signaling patch"
elif git -C "$WORKSPACE/edk2" apply --reverse --check "$EDK2_SD_PATCH" 2>/dev/null; then
  echo "Temporary RPi5 SD signaling patch is already applied"
else
  echo "Temporary RPi5 SD signaling patch does not apply to this edk2 revision" >&2
  exit 1
fi

make -C edk2/BaseTools -j"$(sysctl -n hw.ncpu)"

source edk2/edksetup.sh BaseTools

build -a AARCH64 -t GCC -b "$BUILD_TYPE" \
  -p edk2-platforms/Platform/RaspberryPi/RPi5/RPi5.dsc \
  -n "$(sysctl -n hw.ncpu)" \
  "${@:2}"

echo "=== BUILD DONE: $BUILD_TYPE ==="
FD="Build/RPi5/${BUILD_TYPE}_GCC/FV/RPI_EFI.fd"
ls -la "$FD" 2>/dev/null && echo "FD PRODUCED: $FD" || echo "NO FD"
