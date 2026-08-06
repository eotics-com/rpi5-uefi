#!/bin/bash

#
# Default variables
#
MODEL=5
DEBUG=0
TFA_FLAGS=""
EDK2_FLAGS=""

print_usage() {
    echo
    echo "Build TF-A + EDK2 image for Raspberry Pi."
    echo
    echo "Usage: build.sh [options]"
    echo
    echo "Options: "
    echo "  --model MODEL               Board family. Supported: 4, 5. Default: ${MODEL}."
    echo "  --debug DEBUG               Build a debug version. Default: ${DEBUG}."
    echo "  --tfa-flags \"FLAGS\"         Flags appended to TF-A build process."
    echo "  --edk2-flags \"FLAGS\"        Flags appended to EDK2 build process."
    echo "  --help                      Show this help."
    echo
    exit "${1}"
}

#
# Get options
#
while [[ "${#}" -gt 0 ]]; do
    case "${1}" in
        --model|--debug|--tfa-flags|--edk2-flags)
            if [[ "${#}" -lt 2 ]]; then
                echo "Missing value for '${1}'"
                print_usage 1
            fi
            case "${1}" in
                --model) MODEL="${2}" ;;
                --debug) DEBUG="${2}" ;;
                --tfa-flags) TFA_FLAGS="${2}" ;;
                --edk2-flags) EDK2_FLAGS="${2}" ;;
            esac
            shift 2
            ;;
        --help)
            print_usage 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid argument '${1}'"
            print_usage 1
            ;;
    esac
done
if [[ "${#}" -gt 0 ]]; then
    echo "Invalid additional arguments '$*'"
    print_usage 1
fi

#
# Get machine architecture
#
MACHINE_TYPE=$(uname -m)
HOST_SYSTEM=$(uname -s)
RPI_BUILD_MAKE="${RPI_BUILD_MAKE:-make}"

if [[ "${HOST_SYSTEM}" == "Darwin" ]] && [[ "${RPI_BUILD_MAKE}" == "make" ]] && command -v gmake >/dev/null 2>&1; then
    RPI_BUILD_MAKE="gmake"
fi

if [[ "${HOST_SYSTEM}" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    GNU_SED_BIN_DIR="$(brew --prefix gnu-sed 2>/dev/null)/libexec/gnubin"
    if [[ -x "${GNU_SED_BIN_DIR}/sed" ]]; then
        export PATH="${GNU_SED_BIN_DIR}:${PATH}"
    fi
fi

# Fix-up possible differences in reported arch
if [[ "${MACHINE_TYPE}" == "arm64" ]]; then
    MACHINE_TYPE='aarch64'
elif [[ "${MACHINE_TYPE}" == "amd64" ]]; then
    MACHINE_TYPE='x86_64'
fi

if [[ "${HOST_SYSTEM}" == "Darwin" ]]; then
    export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-elf-}"
elif [[ "${MACHINE_TYPE}" != "aarch64" ]]; then
    export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi

#
# Build TF-A
#
pushd arm-trusted-firmware || exit

"${RPI_BUILD_MAKE}" \
    AR="${CROSS_COMPILE}gcc-ar" \
    PLAT="rpi${MODEL}" \
    PRELOADED_BL33_BASE=0x20000 \
    RPI3_PRELOADED_DTB_BASE=0x3E0000 \
    SUPPORT_VFP=1 \
    SMC_PCI_SUPPORT=1 \
    DEBUG="${DEBUG}" \
    all \
    ${TFA_FLAGS} \
    || exit

popd || exit

#
# Build EDK2 final image
#
GIT_COMMIT="$(git describe --tags --always)" || GIT_COMMIT="unknown"

if [[ "${DEBUG}" == "1" ]]; then
    RELEASE_TYPE="DEBUG"
    TFA_BUILD_TYPE="debug"
else
    RELEASE_TYPE="RELEASE"
    TFA_BUILD_TYPE="release"
fi

ATF_BUILD_DIR="${PWD}/arm-trusted-firmware/build/rpi${MODEL}/${TFA_BUILD_TYPE}"

export GCC_AARCH64_PREFIX="${CROSS_COMPILE}"
export WORKSPACE=${PWD}
export PACKAGES_PATH=${WORKSPACE}/edk2:${WORKSPACE}/edk2-platforms:${WORKSPACE}/edk2-non-osi

EDK2_SD_PATCH="${WORKSPACE}/temporary-patches/edk2/0001-MdeModulePkg-SdMmcPciHcDxe-Add-platform-signaling-vo.patch"
EDK2_SD_PATCH_APPLIED=0
EDK2_PLATFORMS_FAN_PATCH="${WORKSPACE}/temporary-patches/edk2-platforms/0001-RPi5-add-fail-safe-fan-control-and-ACPI-interface.patch"
EDK2_PLATFORMS_FAN_PATCH_APPLIED=0

restore_edk2_sd_patch() {
    if [[ "${EDK2_PLATFORMS_FAN_PATCH_APPLIED}" -eq 1 ]]; then
        git -C "${WORKSPACE}/edk2-platforms" apply --reverse "${EDK2_PLATFORMS_FAN_PATCH}"
        echo "Restored clean edk2-platforms worktree"
    fi
    if [[ "${EDK2_SD_PATCH_APPLIED}" -eq 1 ]]; then
        git -C "${WORKSPACE}/edk2" apply --reverse "${EDK2_SD_PATCH}"
        echo "Restored clean edk2 worktree"
    fi
}
trap restore_edk2_sd_patch EXIT

if [[ "${MODEL}" == "5" ]]; then
    if git -C "${WORKSPACE}/edk2" apply --check "${EDK2_SD_PATCH}" 2>/dev/null; then
        git -C "${WORKSPACE}/edk2" apply "${EDK2_SD_PATCH}"
        EDK2_SD_PATCH_APPLIED=1
        echo "Applied temporary RPi5 SD signaling patch"
    elif git -C "${WORKSPACE}/edk2" apply --reverse --check "${EDK2_SD_PATCH}" 2>/dev/null; then
        echo "Temporary RPi5 SD signaling patch is already applied"
    else
        echo "Temporary RPi5 SD signaling patch does not apply to this edk2 revision" >&2
        exit 1
    fi

    if git -C "${WORKSPACE}/edk2-platforms" apply --check "${EDK2_PLATFORMS_FAN_PATCH}" 2>/dev/null; then
        git -C "${WORKSPACE}/edk2-platforms" apply "${EDK2_PLATFORMS_FAN_PATCH}"
        EDK2_PLATFORMS_FAN_PATCH_APPLIED=1
        echo "Applied experimental RPi5 fail-safe fan patch"
    elif git -C "${WORKSPACE}/edk2-platforms" apply --reverse --check "${EDK2_PLATFORMS_FAN_PATCH}" 2>/dev/null; then
        echo "Experimental RPi5 fail-safe fan patch is already applied"
    else
        echo "Experimental RPi5 fan patch does not apply to this edk2-platforms revision" >&2
        exit 1
    fi
fi

"${RPI_BUILD_MAKE}" -C "${WORKSPACE}/edk2/BaseTools" || exit

source "${WORKSPACE}/edk2/edksetup.sh" || exit

build \
    -a AARCH64 \
    -t GCC \
    -b ${RELEASE_TYPE} \
    -p "edk2-platforms/Platform/RaspberryPi/RPi${MODEL}/RPi${MODEL}.dsc" \
    -D "TFA_BUILD_ARTIFACTS=${ATF_BUILD_DIR}" \
    --pcd gEfiMdeModulePkgTokenSpaceGuid.PcdFirmwareVersionString=L"${GIT_COMMIT}" \
    ${EDK2_FLAGS} \
    || exit

cp "${WORKSPACE}/Build/RPi${MODEL}/${RELEASE_TYPE}_GCC/FV/RPI_EFI.fd" "${PWD}"
