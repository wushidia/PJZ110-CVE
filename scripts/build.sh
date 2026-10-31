#!/bin/bash
# Build bin/timer for OnePlus 13 (PJZ110), kernel 6.6.118-android15-8-g9bc34d5b0c79.
#
# Static, non-PIE: the payload re-execs itself through /proc/self/exe after the
# cred write. Flags match the upstream build.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
ndk="${ANDROID_NDK_HOME:?set ANDROID_NDK_HOME to a Android NDK, e.g. ndk/28.2.13676358}"
prebuilt=linux-x86_64
api=35
cc="$ndk/toolchains/llvm/prebuilt/$prebuilt/bin/aarch64-linux-android$api-clang"

"$cc" -O2 -std=gnu11 -static \
  -fno-stack-protector -fno-pic -I"$root/src" \
  -ffunction-sections -fdata-sections \
  "$root/src/timer.c" -o "$root/bin/timer" \
  -Wl,--gc-sections -Wl,-s -Wl,--build-id=none \
  -Wl,-z,norelro -pthread

sha256sum "$root/bin/timer"