#!/usr/bin/env bash
# build-clang-pgo.sh - build hmp3 with clang + LTO + PGO (instrumented profile).
#
# Works in MSYS2 CLANG64 (Windows, static .exe) and on Linux with clang/lld.
#
# Environment variables (all optional):
#   MARCH        -march value; "" = do not pass -march      (default: x86-64)
#   MTUNE        -mtune value; "" = do not pass -mtune      (default: empty)
#   FAST_MATH    1 = add -ffast-math                        (default: 0)
#   LTO          full | thin | off                          (default: full)
#   EXTRA_CFLAGS extra compiler flags appended at the end
#   TRAIN_WAV    extra real-music training data: WAV file(s) and/or folders of
#                WAVs, separated by ';'  (strongly recommended)
#   TRAIN_SECS   length of each synthetic training file in s (default: 90)
#   BENCH        1 = also build a non-PGO binary and compare speed (default: 0)
#   BUILD_DIR    work directory                  (default: builds/clang-pgo)
#   OUT_NAME     name of the final binary, without extension (default: hmp3)
#   CC / CXX / LLVM_PROFDATA   override tool names
#
# Example:
#   MARCH=x86-64-v3 FAST_MATH=1 ./scripts/build-clang-pgo.sh
#
# MIT License.
set -euo pipefail

# native path for tools that are not MSYS-aware (C:/... style on Windows, no-op elsewhere)
npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

ROOT=$(npath "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")
SRC="$ROOT/hmp3/src"

MARCH=${MARCH-x86-64}
MTUNE=${MTUNE-}
FAST_MATH=${FAST_MATH:-0}
LTO=${LTO:-full}
EXTRA_CFLAGS=${EXTRA_CFLAGS:-}
TRAIN_WAV=${TRAIN_WAV:-}
TRAIN_SECS=${TRAIN_SECS:-90}
BENCH=${BENCH:-0}
BUILD=${BUILD_DIR:-$ROOT/builds/clang-pgo}
OUT_NAME=${OUT_NAME:-hmp3}
CC=${CC:-clang}
CXX=${CXX:-clang++}

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- platform
EXE=""
PLATFORM_LDFLAGS=()
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    EXE=".exe"
    # fully static: no libc++/libunwind/winpthread DLLs needed next to the exe
    PLATFORM_LDFLAGS=(-static)
    ;;
esac

# ---------------------------------------------------------------- tools
command -v "$CC"  >/dev/null || die "$CC not found"
command -v "$CXX" >/dev/null || die "$CXX not found"
if [[ -z "${LLVM_PROFDATA:-}" ]]; then
  for c in llvm-profdata llvm-profdata-{22,21,20,19,18,17}; do
    if command -v "$c" >/dev/null; then LLVM_PROFDATA=$c; break; fi
  done
fi
[[ -n "${LLVM_PROFDATA:-}" ]] || die "llvm-profdata not found"

if command -v nproc >/dev/null; then JOBS=$(nproc); else JOBS=4; fi

# ---------------------------------------------------------------- flags
CFLAGS=(-O3 -I"$SRC/pub" -DIEEE_FLOAT -D_FILE_OFFSET_BITS=64 -w)
[[ -n "$MARCH" ]] && CFLAGS+=("-march=$MARCH")
[[ -n "$MTUNE" ]] && CFLAGS+=("-mtune=$MTUNE")
[[ "$FAST_MATH" == 1 ]] && CFLAGS+=(-ffast-math)
LDFLAGS=(-fuse-ld=lld "${PLATFORM_LDFLAGS[@]}")
case "$LTO" in
  full) CFLAGS+=(-flto);      LDFLAGS+=(-flto) ;;
  thin) CFLAGS+=(-flto=thin); LDFLAGS+=(-flto=thin) ;;
  off)  ;;
  *) die "LTO must be full, thin or off" ;;
esac
# shellcheck disable=SC2206
[[ -n "$EXTRA_CFLAGS" ]] && CFLAGS+=($EXTRA_CFLAGS)

SRC_C=(amodini2.c cnts.c detect.c emap.c l3init.c l3pack.c mhead.c pcmhpm.c setup.c
       spdsmr.c xhead.c cnt.c emdct.c filter2.c hwin.c l3math.c pow34.c sbt.c xhwin.c xsbt.c)
SRC_CPP=(bitallo.cpp bitallo1.cpp bitallo3.cpp bitalloc.cpp bitallos.cpp bitallosc.cpp
         mp3enc.cpp srcc.cpp srccf.cpp test/tomp3.cpp)

# build_stage <name> <extra flags...>  -> $BUILD/<name>/hmp3$EXE
build_stage() {
  local name=$1; shift
  local dir="$BUILD/$name" pids=() objs=() f o
  rm -rf "$dir"; mkdir -p "$dir/obj"
  for f in "${SRC_C[@]}" "${SRC_CPP[@]}"; do
    o="$dir/obj/$(basename "${f%.*}").o"
    objs+=("$o")
    if [[ $f == *.c ]]; then
      "$CC"  -std=gnu11   "${CFLAGS[@]}" "$@" -c "$SRC/$f" -o "$o" &
    else
      "$CXX" -std=gnu++14 "${CFLAGS[@]}" "$@" -c "$SRC/$f" -o "$o" &
    fi
    pids+=($!)
    if (( ${#pids[@]} >= JOBS )); then wait "${pids[0]}" || die "compile failed"; pids=("${pids[@]:1}"); fi
  done
  for p in "${pids[@]}"; do wait "$p" || die "compile failed"; done
  "$CXX" "${CFLAGS[@]}" "$@" "${objs[@]}" "${LDFLAGS[@]}" -o "$dir/hmp3$EXE"
}

# ---------------------------------------------------------------- training data
TRAIN_DIR="$BUILD/train"
gen_training() {
  log "Generating synthetic training audio (${TRAIN_SECS}s per file)"
  mkdir -p "$TRAIN_DIR"
  "$CC" -O2 "$ROOT/scripts/gen_train_wav.c" -lm -o "$TRAIN_DIR/gen$EXE" 2>/dev/null \
    || "$CC" -O2 "$ROOT/scripts/gen_train_wav.c" -o "$TRAIN_DIR/gen$EXE"
  local g="$TRAIN_DIR/gen$EXE" half
  half=$(( TRAIN_SECS / 2 > 10 ? TRAIN_SECS / 2 : 10 ))
  "$g" "$TRAIN_DIR/s48_16.wav"  48000 2 16  "$TRAIN_SECS" 1
  "$g" "$TRAIN_DIR/s44_16.wav"  44100 2 16  "$TRAIN_SECS" 2
  "$g" "$TRAIN_DIR/s44_24.wav"  44100 2 24  "$half"       3
  "$g" "$TRAIN_DIR/s48_32f.wav" 48000 2 32f "$half"       4
  "$g" "$TRAIN_DIR/m32_16.wav"  32000 1 16  "$half"       5
  "$g" "$TRAIN_DIR/s22_16.wav"  22050 2 16  "$half"       6
}

# run_training <hmp3 binary>
run_training() {
  local bin=$1 o="$BUILD/train/out"
  mkdir -p "$o"
  run() { "$bin" "$@" -D >/dev/null 2>&1 || die "training run failed: $*"; }
  # most common settings get the most weight
  run "$TRAIN_DIR/s44_16.wav"  "$o/a.mp3"
  run "$TRAIN_DIR/s44_16.wav"  "$o/b.mp3" -V100 -HF2 -F19000
  run "$TRAIN_DIR/s44_16.wav"  "$o/c.mp3" -V150 -HF2
  run "$TRAIN_DIR/s48_16.wav"  "$o/d.mp3"
  run "$TRAIN_DIR/s48_16.wav"  "$o/e.mp3" -V100 -HF2
  run "$TRAIN_DIR/s48_16.wav"  "$o/f.mp3" -B64
  run "$TRAIN_DIR/s48_16.wav"  "$o/g.mp3" -B160 -HF2
  run "$TRAIN_DIR/s44_16.wav"  "$o/h.mp3" -V60
  run "$TRAIN_DIR/s44_24.wav"  "$o/i.mp3" -V100 -HF2
  run "$TRAIN_DIR/s48_32f.wav" "$o/j.mp3"
  run "$TRAIN_DIR/m32_16.wav"  "$o/k.mp3"
  run "$TRAIN_DIR/m32_16.wav"  "$o/l.mp3" -B48
  run "$TRAIN_DIR/s22_16.wav"  "$o/m.mp3"
  run "$TRAIN_DIR/s48_16.wav"  "$o/n.mp3" -A44100       # resampler path
  local w e i=0 files=()
  IFS=';' read -r -a extra <<< "$TRAIN_WAV"
  for e in "${extra[@]}"; do
    [[ -z "$e" ]] && continue
    if [[ -d "$e" ]]; then
      shopt -s nullglob nocaseglob; files+=("$e"/*.wav); shopt -u nullglob nocaseglob
    elif [[ -f "$e" ]]; then files+=("$e")
    else die "TRAIN_WAV entry not found: $e"; fi
  done
  (( ${#files[@]} )) && echo "  + ${#files[@]} user-supplied WAV file(s)"
  for w in "${files[@]}"; do
    i=$((i+1))
    run "$w" "$o/x${i}a.mp3"
    run "$w" "$o/x${i}b.mp3" -V100 -HF2 -F19000
    run "$w" "$o/x${i}c.mp3" -V150 -HF2
  done
}

md5() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ---------------------------------------------------------------- main
log "hmp3 clang PGO build"
"$CC" --version | head -n1
echo "  march=${MARCH:-<none>} mtune=${MTUNE:-<none>} fast-math=$FAST_MATH lto=$LTO"
echo "  profdata tool: $LLVM_PROFDATA, jobs: $JOBS"

mkdir -p "$BUILD"
gen_training

PROF_RAW="$BUILD/profraw"
PROF_DATA="$BUILD/hmp3.profdata"
rm -rf "$PROF_RAW" "$PROF_DATA"; mkdir -p "$PROF_RAW"

log "Stage 1/3: instrumented build"
build_stage gen -fprofile-generate

log "Stage 2/3: training runs"
export LLVM_PROFILE_FILE
LLVM_PROFILE_FILE="$(npath "$PROF_RAW")/hmp3-%p-%m.profraw"
run_training "$BUILD/gen/hmp3$EXE"
unset LLVM_PROFILE_FILE
shopt -s nullglob
raws=("$PROF_RAW"/*.profraw)
(( ${#raws[@]} > 0 )) || die "no .profraw files were produced"
"$LLVM_PROFDATA" merge -o "$PROF_DATA" "${raws[@]}"
echo "  merged ${#raws[@]} raw profiles -> $(basename "$PROF_DATA")"

log "Stage 3/3: optimized build with profile"
build_stage use "-fprofile-use=$(npath "$PROF_DATA")" -Wno-backend-plugin

OUT_DIR="$BUILD/out"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$OUT_NAME$EXE"
cp "$BUILD/use/hmp3$EXE" "$OUT"
command -v llvm-strip >/dev/null && llvm-strip "$OUT" || strip "$OUT" 2>/dev/null || true

log "Sanity check"
ref="$BUILD/check_gen.mp3"; got="$BUILD/check_pgo.mp3"
LLVM_PROFILE_FILE="$(npath "$BUILD")/discard.profraw" \
  "$BUILD/gen/hmp3$EXE" "$TRAIN_DIR/s44_16.wav" "$ref" -D >/dev/null 2>&1
"$OUT" "$TRAIN_DIR/s44_16.wav" "$got" -D >/dev/null 2>&1 || die "final binary failed to encode"
[[ -s "$got" ]] || die "final binary produced an empty file"
if [[ "$(md5 "$ref")" == "$(md5 "$got")" ]]; then
  echo "  OK: PGO binary output is bit-identical to the instrumented build"
else
  echo "  NOTE: output differs from instrumented build (expected with -ffast-math; check with ears/ABX if not)"
fi
rm -f "$BUILD"/discard*.profraw "$BUILD"/gen/*.profraw 2>/dev/null || true

if [[ "$BENCH" == 1 ]]; then
  log "Benchmark: plain clang vs clang+PGO"
  build_stage plain
  bw="$BUILD/bench.wav"
  "$TRAIN_DIR/gen$EXE" "$bw" 44100 2 16 600 7
  bench() {
    local best=999999 s e d k
    for k in 1 2 3; do
      s=$(date +%s.%N); "$1" "$bw" "$BUILD/bench.mp3" -D >/dev/null 2>&1; e=$(date +%s.%N)
      d=$(awk -v a="$s" -v b="$e" 'BEGIN{printf "%.3f", b-a}')
      best=$(awk -v a="$best" -v b="$d" 'BEGIN{print (b<a)?b:a}')
    done
    awk -v t="$best" 'BEGIN{printf "%7.3fs  %7.1fx realtime\n", t, 600/t}'
  }
  printf '  plain: '; bench "$BUILD/plain/hmp3$EXE"
  printf '  pgo  : '; bench "$OUT"
fi

log "Done: $OUT"
"$OUT" 2>&1 | grep -m1 -i 'hmp3' || true
