#!/usr/bin/env bash
# ===========================================================================
#  build-fpc.sh - compile-check horse-provider-mormot with Free Pascal
#  (Linux x86_64). A COMPILE gate: it builds a program that pulls in every
#  provider unit, and reports. It does not run anything.
#
#  Usage:
#    tests/Lazarus/build-fpc.sh [program.lpr]
#      default program: tests/Lazarus/HorseMormotParamTestServer.lpr
#
#  Environment (all optional):
#    FPC           compiler           default /usr/bin/fpc
#    PROVIDER_DIR  provider checkout  default: the repo this script lives in
#                  (point it at an extracted older tag to build a CONTROL)
#    HORSE_DIR     Horse checkout     default <repos>/horse
#    MORMOT2_DIR   mORMot2 checkout   default <repos>/mORMot2
#    OUT           output directory   default a fresh mktemp dir
#    FPC_UNITS     the compiler's own unit tree (the dir holding rtl/), default
#                  derived from FPC's version and target - see WHY -n below
#
#  WHY THIS EXISTS. The Lazarus README says to hand-make a .lpi per machine, so
#  this provider's FPC build was never scripted and, as far as any record shows,
#  never run. A compile that cannot be repeated cannot gate a release.
#
#  WHY -B. A changed define or source does not reliably invalidate a cached .ppu,
#  and OUT is a fresh directory anyway, so every unit is compiled from source.
#
#  WHY -n. Without it fpc reads the shared /etc/fpc.cfg, which on Ubuntu points at
#  the distro 3.2.2 RTL. Trunk then loads 3.2.2's system.ppu and stops at line 1:
#  "PPU Invalid Version 207 expecting 208 / Can't find unit system" (2026-10-06).
#  So the config is skipped for EVERY compiler and the RTL comes from FPC_UNITS,
#  same as horse-provider-nghttp2's build-fpc.sh. "-Fu$FPC_UNITS/*" is fpc.cfg's
#  own wildcard form: fpc expands it to every package directory.
#
#  WHY -Fl. On Linux x86_64 mORMot2 links libdeflate statically
#  (mormot.defines.inc: LIBDEFLATESTATIC), from mORMot2/static/x86_64-linux/.
#  Without that library path the build fails at LINK time, after every unit
#  compiled - which reads like a provider failure and is not one.
#
#  The full compiler output is printed and kept in $OUT/build.log. Read it
#  whole - do not grep a failing build; the first error is the one that matters.
# ===========================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT_ROOT=$(cd "$HERE/../.." && pwd)
REPOS=$(dirname "$SCRIPT_ROOT")

PROVIDER_DIR=${PROVIDER_DIR:-$SCRIPT_ROOT}
HORSE_DIR=${HORSE_DIR:-$REPOS/horse}
MORMOT2_DIR=${MORMOT2_DIR:-$REPOS/mORMot2}
FPC=${FPC:-/usr/bin/fpc}
OUT=${OUT:-$(mktemp -d /tmp/mormot-fpc.XXXXXX)}
PROGRAM=${1:-$PROVIDER_DIR/tests/Lazarus/HorseMormotParamTestServer.lpr}
STATIC=$MORMOT2_DIR/static/x86_64-linux

fail() { echo "VOID - $1"; exit 2; }

[ -x "$FPC" ] || fail "no compiler at $FPC (set FPC=...)"
[ -d "$PROVIDER_DIR/src" ] || fail "no provider src at $PROVIDER_DIR/src"
[ -f "$HORSE_DIR/src/Horse.pas" ] || fail "no Horse at $HORSE_DIR"
[ -d "$MORMOT2_DIR/src/net" ] || fail "no mORMot2 at $MORMOT2_DIR"
[ -f "$STATIC/libdeflatepas.a" ] || fail "no $STATIC/libdeflatepas.a - mORMot2 static libs missing"
[ -f "$PROGRAM" ] || fail "no program $PROGRAM"

FPC_VER=$("$FPC" -iV)
FPC_TARGET="$("$FPC" -iTP)-$("$FPC" -iTO)"
if [ -z "${FPC_UNITS:-}" ]; then
  for c in "$(dirname "$(dirname "$FPC")")/lib/fpc/$FPC_VER/units/$FPC_TARGET" \
           "/usr/lib/x86_64-linux-gnu/fpc/$FPC_VER/units/$FPC_TARGET" \
           "/usr/lib/fpc/$FPC_VER/units/$FPC_TARGET"; do
    if [ -f "$c/rtl/system.ppu" ]; then FPC_UNITS=$c; break; fi
  done
fi
[ -n "${FPC_UNITS:-}" ] && [ -f "$FPC_UNITS/rtl/system.ppu" ] || \
  fail "no RTL for fpc $FPC_VER ($FPC_TARGET) - set FPC_UNITS to the directory holding rtl/; find it with: find / -name system.ppu -path '*$FPC_VER*' 2>/dev/null"

# Library paths fpc.cfg would have supplied: multiarch libc, and libgcc (the
# static mORMot2 objects are C code).
LIB_PATHS=("-Fl$STATIC")
for d in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do
  [ -d "$d" ] && LIB_PATHS+=("-Fl$d")
done
if command -v gcc >/dev/null 2>&1; then
  LIB_PATHS+=("-Fl$(dirname "$(gcc -print-libgcc-file-name)")")
fi
mkdir -p "$OUT" || fail "cannot create $OUT"

describe() { git -C "$1" describe --tags --always --dirty 2>/dev/null || echo "(not a git checkout)"; }

echo "=== horse-provider-mormot FPC compile check ==="
echo "fpc:      $FPC  $FPC_VER ($FPC_TARGET)"
echo "rtl:      $FPC_UNITS"
echo "provider: $PROVIDER_DIR  $(describe "$PROVIDER_DIR")"
echo "horse:    $HORSE_DIR  $(describe "$HORSE_DIR")"
echo "mORMot2:  $MORMOT2_DIR  $(describe "$MORMOT2_DIR")"
echo "program:  $PROGRAM"
echo "out:      $OUT"
echo

UNIT_PATHS=("-Fu$FPC_UNITS/*" "-Fu$HORSE_DIR/src" "-Fu$PROVIDER_DIR/src")
for d in "$MORMOT2_DIR"/src/*/; do
  UNIT_PATHS+=("-Fu${d%/}")
done

"$FPC" -n -B -Mdelphi -dHORSE_PROVIDER_MORMOT -vew \
  "${UNIT_PATHS[@]}" \
  "-Fi$MORMOT2_DIR/src" "-Fi$MORMOT2_DIR/src/core" \
  "${LIB_PATHS[@]}" \
  "-FU$OUT" "-FE$OUT" \
  "$PROGRAM" 2>&1 | tee "$OUT/build.log"
RC=${PIPESTATUS[0]}

echo
echo "==========================================================================="
if [ "$RC" -eq 0 ]; then
  echo " BUILD OK   (log: $OUT/build.log)"
else
  echo " BUILD FAILED, fpc exit $RC   (log: $OUT/build.log)"
  echo " Read the FIRST error above; later ones are often its cascade."
fi
echo "==========================================================================="
exit "$RC"
