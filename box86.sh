#!/bin/bash
# box86 launcher wrapper for arm64 hosts.
#
# steamcmd (a 32-bit x86 binary) is run through box86 instead of box64's
# integrated box32 mode: recent steamcmd clients fail their HTTPS
# connections under box32 on CPUs that lack the ARM crypto extensions
# (e.g. the Cortex-A72 of the Raspberry Pi 4) - see
# https://github.com/ptitSeb/box64/issues/4206. box86 handles this
# correctly. The 64-bit valheim_server binary keeps using box64
# (see box64.sh).
#
# Adapted from box64.sh, which was adapted from
# sonroyaalmerol/steamcmd-arm64 (MIT licensed)
# https://github.com/sonroyaalmerol/steamcmd-arm64

ARM64_DEVICE="${ARM64_DEVICE:-generic}"

case "$ARM64_DEVICE" in
    rpi3) SUFFIX="rpi3" ;;
    rpi4) SUFFIX="rpi4" ;;
    *) SUFFIX="generic" ;;
esac

BINARY_PATH="/usr/local/bin/box86-${SUFFIX}"
if [ ! -x "$BINARY_PATH" ]; then
    BINARY_PATH="/usr/local/bin/box86-generic"
fi

# steamcmd frequently exits with a segfault or abort after it has finished
# all of its work. Translate those exit codes so callers don't misinterpret
# a successful run as a failure. All other exit codes - notably steamcmd's
# magic self-restart exit code 42 - are passed through untouched.
BOX86_SHOWSEGV=1 "$BINARY_PATH" "$@"
status=$?
case "$status" in
    139|134) exit 0 ;;
    *) exit "$status" ;;
esac
