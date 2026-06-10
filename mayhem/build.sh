#!/usr/bin/env bash
#
# draco/mayhem/build.sh — build google/draco's in-tree decoder fuzz harnesses (the ones OSS-Fuzz
# builds: pc + mesh decoders, with and without dequantization) as sanitized libFuzzer targets plus
# standalone (non-fuzzer) reproducers, AND draco's own GoogleTest suite for mayhem/test.sh.
#
# The fuzzed surface is the DECODER on attacker bytes: each harness calls
# Decoder::DecodeMeshFromBuffer / DecodePointCloudFromBuffer on the fuzz input.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile the draco library ITSELF with $SANITIZER_FLAGS so the decoder
# code (not just the harness) is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"

# Ensure the draco library itself is coverage-instrumented (sancov edges visible to libFuzzer).
# LIB_FUZZING_ENGINE adds -fsanitize=fuzzer at *link* time for the final target binary, but the
# library objects need -fsanitize=fuzzer-no-link so coverage counters are embedded in libdraco.a.
# Without this, the library compiles clean but has 0 sancov trace_pc_guard sites → 0 edges → Mayhem
# reports 0-edge runs even though ASan+UBSan are present.
# Guard: only inject when LIB_FUZZING_ENGINE mentions 'fuzzer' (libFuzzer mode); skip for afl++.
if [[ "$LIB_FUZZING_ENGINE" == *fuzzer* ]] && [[ "$SANITIZER_FLAGS" != *fuzzer-no-link* ]]; then
  SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
fi

export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

FUZZ_DIR="$SRC/src/draco/tools/fuzz"

# ── Include roots ────────────────────────────────────────────────────────────
# draco's internal headers use   #include "draco/..."        -> root is $SRC/src
# the fuzz harnesses use         #include "draco/src/draco/..."  -> root is the PARENT of a
# dir literally named "draco" that contains src/ . The repo root ($SRC) is that dir, but it is
# named "/mayhem", so we expose it under the name "draco" via a symlink and -I that parent.
INCROOT="$(mktemp -d)"
ln -sfn "$SRC" "$INCROOT/draco"
HARNESS_INCLUDES=(-I "$INCROOT" -I "$SRC/src")

# ── 1) Build the draco static library WITH sanitizers (the fuzzed code is instrumented) ──────────
# BUILD_SHARED_LIBS=OFF -> static libdraco.a. DRACO_TESTS=OFF for the fuzz build.
cmake -S "$SRC" -B "$SRC/build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DDRACO_TESTS=OFF \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake --build "$SRC/build" -j"$MAYHEM_JOBS" --target draco_static

DRACO_LIB="$SRC/build/libdraco.a"
[ -f "$DRACO_LIB" ] || { echo "ERROR: $DRACO_LIB not produced by the cmake build" >&2; \
  find "$SRC/build" -name 'libdraco*.a' -print >&2; exit 1; }

# generated header (draco_features.h) lands in the build tree
GEN_INCLUDES=(-I "$SRC/build")

# Standalone driver compiled as a C object so its extern "C" LLVMFuzzerTestOneInput ref isn't
# mangled by clang++ at link.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

# ── 2) Build each in-tree decoder fuzz harness twice: libFuzzer + standalone ─────────────────────
for harness in "$FUZZ_DIR"/*.cc; do
  name="$(basename -s .cc "$harness")"

  # libFuzzer target -> /mayhem/<name>
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 \
      "${HARNESS_INCLUDES[@]}" "${GEN_INCLUDES[@]}" \
      "$harness" $LIB_FUZZING_ENGINE "$DRACO_LIB" \
      -o "/mayhem/$name"

  # standalone reproducer (no libFuzzer runtime) -> /mayhem/<name>-standalone
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++17 \
      "${HARNESS_INCLUDES[@]}" "${GEN_INCLUDES[@]}" \
      "$harness" /tmp/standalone_main.o "$DRACO_LIB" \
      -o "/mayhem/$name-standalone"

  echo "built $name (+ standalone)"
done

# ── 3) Build draco's OWN GoogleTest suite with NORMAL flags (clean, separate tree) so test.sh
#       only RUNS it. googletest is a submodule; populate it if the working tree copy is empty. ──
cd "$SRC"
if [ -z "$(ls -A third_party/googletest 2>/dev/null)" ]; then
  git submodule update --init third_party/googletest
fi

# Normal (non-sanitized) flags here: keeps test.sh an honest PATCH oracle and avoids benign-UB noise.
env -u CFLAGS -u CXXFLAGS \
cmake -S "$SRC" -B "$SRC/build-tests" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DDRACO_TESTS=ON \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" --target draco_tests draco_factory_tests

echo "build.sh complete:"
ls -la /mayhem/draco_*fuzzer* "$SRC"/build-tests/draco_tests "$SRC"/build-tests/draco_factory_tests 2>&1 || true
