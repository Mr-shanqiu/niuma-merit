#!/bin/sh
# 编译并运行 Windows 纯逻辑单测（F0/F2/F3/F4）。
# 这些测试只依赖标准 C++，可在 macOS/Linux 的 clang++ 上直接跑；
# Windows 侧 MSVC 也可用同样的编译参数手工编译。
#
# 用法：
#   windows/tests/run_tests.sh
#   CXX=clang++ NIUMA_TEST_SANITIZE=1 windows/tests/run_tests.sh
#   NIUMA_TEST_SYSROOT=/path/to/MacOSX.sdk windows/tests/run_tests.sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
include="$here/../src/client/core"
cxx=${CXX:-clang++}
work=${TMPDIR:-/tmp}/niuma-windows-core-tests.$$
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work"

# macOS 上 xcrun 选中的 SDK 偶尔会新于系统 ld（tapi 不认新架构），此时
# 自动回退到本机任一可链接的 MacOSX*.sdk。Linux/Windows 无需 sysroot。
sysroot=${NIUMA_TEST_SYSROOT:-}
if [ -z "$sysroot" ] && [ "$(uname -s)" = "Darwin" ]; then
  probe() {
    printf 'int main(){return 0;}\n' |
      "$cxx" -x c++ -isysroot "$1" - -o "$work/sdkprobe" >/dev/null 2>&1
  }
  if command -v xcrun >/dev/null 2>&1; then
    candidate=$(xcrun --show-sdk-path 2>/dev/null || true)
    if [ -n "$candidate" ] && probe "$candidate"; then
      sysroot=$candidate
    fi
  fi
  if [ -z "$sysroot" ]; then
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
      [ -d "$candidate" ] || continue
      if probe "$candidate"; then sysroot=$candidate; break; fi
    done
  fi
  if [ -z "$sysroot" ]; then
    printf 'warning: no linkable macOS SDK found; trying the compiler default\n' >&2
  fi
fi
[ -z "$sysroot" ] || printf 'sysroot: %s\n' "$sysroot"

cxxflags="-std=c++17 -Wall -Wextra -Werror"
[ -z "$sysroot" ] || cxxflags="$cxxflags -isysroot $sysroot"
if [ "${NIUMA_TEST_SANITIZE:-0}" = "1" ]; then
  cxxflags="$cxxflags -fsanitize=address,undefined -fno-omit-frame-pointer"
fi

status=0
for name in work_encourager merit_curve medals scroll_tick_counter; do
  printf '== %s ==\n' "$name"
  # shellcheck disable=SC2086
  if ! "$cxx" $cxxflags -I"$include" "$here/${name}_test.cpp" -o "$work/$name"; then
    status=1
    continue
  fi
  if ! "$work/$name"; then
    status=1
  fi
done

if [ "$status" -eq 0 ]; then
  printf '\nAll Windows pure-logic tests passed.\n'
else
  printf '\nWindows pure-logic tests FAILED.\n' >&2
fi
exit "$status"
