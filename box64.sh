#!/bin/bash
# box64 launcher wrapper for arm64 hosts.
#
# Selects the box64 dynarec build matching ARM64_DEVICE, falling back to the
# generic build if the requested variant isn't installed or the variable is
# unset. It also works around steamcmd's habit of dying with SIGSEGV/SIGABRT
# after all of its work has already been completed successfully, which would
# otherwise make valheim-updater treat a finished update as a failure.
#
# Adapted from sonroyaalmerol/steamcmd-arm64 (MIT licensed)
# https://github.com/sonroyaalmerol/steamcmd-arm64

ARM64_DEVICE="${ARM64_DEVICE:-generic}"

case "$ARM64_DEVICE" in
    rpi3) SUFFIX="rpi3" ;;
    rpi4) SUFFIX="rpi4" ;;
    rpi5) SUFFIX="rpi5" ;;
    *) SUFFIX="generic" ;;
esac

BINARY_PATH="/usr/local/bin/box64-${SUFFIX}"
if [ ! -x "$BINARY_PATH" ]; then
    BINARY_PATH="/usr/local/bin/box64-generic"
fi
BASH_PATH="${BINARY_PATH/box64-/box64-bash-}"
if [ -x "$BASH_PATH" ]; then
    export BOX64_BASH="$BASH_PATH"
fi

# steamcmd (a 32-bit x86 binary, run through box64's integrated box32 mode)
# frequently exits with a segfault or abort after it has finished all of its
# work. Translate those exit codes so callers don't misinterpret a successful
# run as a failure. All other exit codes - notably steamcmd's magic
# self-restart exit code 42 - are passed through untouched.
is_steamcmd=false
for arg in "$@"; do
    case "$arg" in
        *steamcmd*)
            is_steamcmd=true
            break
            ;;
    esac
done

if [ "$is_steamcmd" = true ]; then
    BOX64_SHOWSEGV=1 BOX64_DLSYM_ERROR=1 "$BINARY_PATH" "$@"
    status=$?
    case "$status" in
        139|134) exit 0 ;;
        *) exit "$status" ;;
    esac
else
    exec "$BINARY_PATH" "$@"
fi
