#!/usr/bin/env bash
#
# Build Node.js v24.20.0 for arm64-darwin like the official recipe
# (./configure --ninja && ninja, Release) with two deliberate changes:
#   * ISA baseline ARMv8.0 so NO ARMv8.1 LSE atomics (and no v8.2+ FP16/DotProd,
#     v8.4 JSCVT) are emitted -- required to run on an Apple A10 (iPad 6).
#
# WHY A COMPILER FLAG IS NOT ENOUGH: V8's macOS-arm64 path hardcodes
# deps/v8/src/base/cpu.cc "has_lse_/has_fp16_/has_dot_prod_/has_jscvt_ = true",
# so mksnapshot's OWN code generator bakes those opcodes into the builtins. The
# -mcpu / -target-feature flags only steer the C++ compiler, not V8's macro
# assembler -- so we must also downgrade that source assumption (see the patch).
#
# Runs natively on arm64 (GitHub macos-15) OR as a cross build from x86_64
# (arm64 flags are injected only for "-arch arm64" compiles, never for the
# x86_64 host tools like mksnapshot/torque).

set -euo pipefail

VERSION="v24.20.0"
TARBALL="node-${VERSION}.tar.xz"
EXPECT_SHA="2732fc3f588dd335cd6779c06864f7cd424bb1b5ff9a1743059a66c54f9ca4a1"
CPU="apple-a10"                       # ARMv8.0 -> zero LSE (proved via probe)
INTL="${INTL:-full-icu}"             # none | small-icu | full-icu | system-icu

BUILD_DIR="${BUILD_DIR:-$(pwd)/_nodebuild}"
DIST_DIR="${DIST_DIR:-$(pwd)/dist}"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

HOST_ARCH="$(uname -m)"               # arm64 native, or x86_64 cross

# ---------------------------------------------------------------------------
# Download + verify + extract the official source tarball.
# ---------------------------------------------------------------------------
cd "$BUILD_DIR"
[ -f "$TARBALL" ] || curl -fL -o "$TARBALL" "https://nodejs.org/dist/${VERSION}/${TARBALL}"
echo "${EXPECT_SHA}  ${TARBALL}" | shasum -a 256 -c -
[ -d "node-${VERSION}" ] || tar -xf "$TARBALL"
SRC="$(pwd)/node-${VERSION}"

# ---------------------------------------------------------------------------
# PATCH V8: stop it assuming ARMv8.1+ on macOS arm64, so mksnapshot generates
# ARMv8.0-only builtins. These "= true;" lines exist ONLY in the macOS-arm64
# branch (the iOS branch uses sysctl/feat_*), so the substitution is surgical.
# PMULL (v8.0 crypto) is left true: A10 has the crypto extension.
# ---------------------------------------------------------------------------
CPU_CC="$SRC/deps/v8/src/base/cpu.cc"
/usr/bin/sed -i '' \
  -e 's/^\(  has_jscvt_ = \)true;/\1false;/' \
  -e 's/^\(  has_dot_prod_ = \)true;/\1false;/' \
  -e 's/^\(  has_lse_ = \)true;/\1false;/' \
  -e 's/^\(  has_fp16_ = \)true;/\1false;/' \
  "$CPU_CC"
# Fail loudly if the patch found nothing (upstream changed the wording).
if /usr/bin/grep -qE '^\s+has_lse_ = true;' "$CPU_CC"; then
  echo "ERROR: cpu.cc LSE patch did not apply (upstream changed?); refusing." >&2
  exit 1
fi
echo "patched deps/v8/src/base/cpu.cc -> V8 will emit ARMv8.0 builtins" >&2

# ---------------------------------------------------------------------------
# PATCH #2 (the one that was MISSING): mksnapshot/cross-compile does NOT read
# base/cpu.cc -- it calls CpuFeatures::ProbeImpl(cross_compile=true) which pulls
# JSCVT/DOTPROD/LSE/PMULL from assembler-arm64.cc CpuFeaturesFromTargetOS()'s
# macOS #if block. That is what baked fjcvtzs + the LSE Atomics into builtins
# even with the cpu.cc patch. Neuter that block so the snapshot is ARMv8.0 too.
# The guard string is unique (the compiler-feature #if differs), so this is safe.
# ---------------------------------------------------------------------------
ASM_CC="$SRC/deps/v8/src/codegen/arm64/assembler-arm64.cc"
/usr/bin/sed -i '' \
  's|#if defined(V8_TARGET_OS_MACOS) && !defined(V8_TARGET_OS_IOS)|#if 0 /* A10/ARMv8.0: do not force JSCVT/DOTPROD/LSE for macOS target */|' \
  "$ASM_CC"
if ! /usr/bin/grep -q 'A10/ARMv8.0: do not force' "$ASM_CC"; then
  echo "ERROR: assembler-arm64.cc CpuFeaturesFromTargetOS patch did not apply." >&2
  exit 1
fi
echo "patched deps/v8/src/codegen/arm64/assembler-arm64.cc (CpuFeaturesFromTargetOS)" >&2

# ---------------------------------------------------------------------------
# Compiler wrapper (xcrun-based). Injects ISA flags ONLY for real arm64
# compiles (-c AND -arch arm64); x86_64 host tools are left untouched so
# "-mcpu=apple-a10" never hits an x86_64 translation unit. Flags appended after
# "$@" (clang: last -std/-mcpu/-arch-feature wins).
# ---------------------------------------------------------------------------
WRAP="$BUILD_DIR/.ccwrap"
mkdir -p "$WRAP"
# HOST_ARM64 bakes the host arch so an arm64 compile with no explicit "-arch"
# still gets the flags on a native arm64 build. A per-compile "-arch x86_64"
# (cross host tools) or "-arch arm64" (target) overrides it.
if [ "$HOST_ARCH" = "arm64" ]; then HOST_ARM64=1; else HOST_ARM64=0; fi
cat > "$WRAP/cc" <<SH
#!/bin/sh
arm64=${HOST_ARM64}
for a in "\$@"; do case "\$a" in x86_64*) arm64=0;; arm64*) arm64=1;; esac; done
for a in "\$@"; do
  if [ "\$a" = "-c" ]; then
    if [ "\$arm64" = "1" ]; then
      exec xcrun clang "\$@" -mcpu=${CPU} -Xclang -target-feature -Xclang -lse
    fi
    exec xcrun clang "\$@"
  fi
done
exec xcrun clang "\$@"
SH
cat > "$WRAP/cxx" <<SH
#!/bin/sh
arm64=${HOST_ARM64}
for a in "\$@"; do case "\$a" in x86_64*) arm64=0;; arm64*) arm64=1;; esac; done
for a in "\$@"; do
  if [ "\$a" = "-c" ]; then
    if [ "\$arm64" = "1" ]; then
      exec xcrun clang++ "\$@" -mcpu=${CPU} -Xclang -target-feature -Xclang -lse
    fi
    exec xcrun clang++ "\$@"
  fi
done
exec xcrun clang++ "\$@"
SH
chmod +x "$WRAP/cc" "$WRAP/cxx"

# ---------------------------------------------------------------------------
# Build (official recipe). Cross if the host isn't arm64.
# ---------------------------------------------------------------------------
cd "$SRC"
export CC="$WRAP/cc"
export CXX="$WRAP/cxx"
command -v ninja >/dev/null 2>&1 || brew install ninja
CONFIGURE_ARGS=(--ninja --dest-cpu=arm64 --with-intl="${INTL}")
[ "$HOST_ARCH" = "arm64" ] || CONFIGURE_ARGS+=(--cross-compiling)
./configure "${CONFIGURE_ARGS[@]}"
ninja -C out/Release node

NODE="$SRC/out/Release/node"
cp -f "$NODE" "$DIST_DIR/node"
NODE="$DIST_DIR/node"

# ---------------------------------------------------------------------------
# VERIFY against an ARMv8.0 baseline. A10 lacks: LSE(v8.1), FP16/DotProd(v8.2+),
# JSCVT(v8.4). Hard-fail on any of these; PAC is also fatal (would mean arm64e).
# otool -tv dumps the text segments; anchor to "addr <TAB> mnemonic" so string
# comments ("literal pool for: ...") can't create false positives.
# ---------------------------------------------------------------------------
echo "==================== verification ===================="
file "$NODE"
otool -hv "$NODE" | grep -iE 'cputype|ARM64' || true
vtool -show-build "$NODE" 2>/dev/null | grep -iE 'platform|minos|sdk' || true

DIS="$BUILD_DIR/node.dis.txt"
otool -tv "$NODE" > "$DIS" 2>/dev/null || true
I='^[[:space:]]*[0-9a-fx]{4,16}[[:space:]]+'
# ARMv8.0 baseline violations ONLY. Be precise: fcvtzs/fcvtzu/fmaxnm/fadda are
# legitimate ARMv8.0 scalar FP and MUST NOT be flagged (doing so produced 2314
# false positives). LSE = v8.1; sdot/udot = DotProd v8.4; fjcvtz = JSCVT v8.4.
LSE_RE="${I}(ldadd|ldclr|ldeor|ldset|ldsmax|ldsmin|ldumax|ldumin|swp|cas|casp)[a-z]+([[:space:]]|,|\$)"
V82_RE="${I}(sdot|udot|fjcvtz[a-z]*|frint32[a-z]*|frint64[a-z]*|fmla[[:space:]]|fadd[[:space:]].*\\.8h|bfcvt|fcmlex|xsread|cpuspc)([[:space:]]|,|\$)"  # JSCVT/FRINT32-64/DotProd/FP16-class
PAC_RE="${I}(pacia|pacib|pacda|pacga|autia|autib|autda|braa|blraa|blrab|retaa|retab)([[:space:]]|,|\$)"
LSE="$(grep -cE "$LSE_RE" "$DIS" || true)"
V82="$(grep -cE "$V82_RE" "$DIS" || true)"
PAC="$(grep -cE "$PAC_RE" "$DIS" || true)"
echo "--- LSE (v8.1 atomics): ${LSE}   must be 0 ---"
echo "--- DotProd/JSCVT/FP16 (v8.2+): ${V82}   must be 0 ---"
echo "--- PAC (v8.3 / arm64e): ${PAC}   must be 0 ---"
if [ "$LSE" != "0" ] || [ "$V82" != "0" ] || [ "$PAC" != "0" ]; then
  grep -E "$LSE_RE|$V82_RE|$PAC_RE" "$DIS" > "$DIST_DIR/lse_sites.txt" 2>/dev/null || true
  echo "=== offending sites (first 60) ==="; head -60 "$DIST_DIR/lse_sites.txt" || true
fi

otool -L "$NODE" > "$DIST_DIR/deps.txt" 2>&1 || true   # static deps; only system libs dynamic
[ "$HOST_ARCH" = "arm64" ] && "$NODE" -v || echo "(smoke test skipped: host $HOST_ARCH cannot exec arm64)"

if [ "$LSE" != "0" ] || [ "$V82" != "0" ] || [ "$PAC" != "0" ]; then
  echo "NOT A10-SAFE: LSE=${LSE} v8.2+=${V82} PAC=${PAC}" >&2
  exit 1
fi
echo "OK: $NODE  plain arm64 / ARMv8.0 baseline, 0 LSE, 0 FP16/DotProd/JSCVT, 0 PAC."
