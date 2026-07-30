# RPi5 edk2 compatibility patch

The RPi5 Broadcom SDHCI driver requires the signaling-voltage override in the
adjacent patch. The `edk2` submodule carries the same change as a logical
commit; the patch also lets the build scripts support a clean upstream checkout.
They apply it only when needed and reverse it on exit.

The patch preserves the CRLF bytes used by the affected edk2 sources, so Git
treats it as a binary artifact.
