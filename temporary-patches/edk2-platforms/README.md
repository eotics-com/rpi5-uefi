# Temporary edk2-platforms patches

`0001-RPi5-add-fail-safe-fan-control-and-ACPI-interface.patch` keeps the
experimental Raspberry Pi 5 fan work separate from the upstream submodule.
`build.sh` applies it only for model 5 and restores a clean submodule after the
build. This makes future rebases and Windows driver development independent of
unrelated platform code.

The patch is experimental and must be physically tested before it becomes a
wizard default.
