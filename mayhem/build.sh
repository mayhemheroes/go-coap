#!/usr/bin/env bash
#
# go-coap/mayhem/build.sh — build plgd-dev/go-coap's OSS-Fuzz Go fuzz targets as sanitized
# libFuzzer binaries, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz targets (projects/go-coap/build.sh):
#   compile_native_go_fuzzer $(pwd)/udp/coder     FuzzDecode        fuzz_decode_udp
#   compile_native_go_fuzzer $(pwd)/tcp/coder     FuzzDecode        fuzz_decode_tcp
#   compile_native_go_fuzzer $(pwd)/message       FuzzUnmarshalData fuzz_unmarshal_data
#   compile_native_go_fuzzer $(pwd)/message/codes FuzzUnmarshalJSON fuzz_unmarshal_json
#
# All four are NATIVE Go fuzz harnesses `func FuzzX(f *testing.F)` (in *_test.go files) built
# with go-118-fuzz-build under `-tags gofuzz`, then linked with $LIB_FUZZING_ENGINE — exactly
# compile_native_go_fuzzer -> build_native_go_fuzzer_legacy's non-coverage path:
#   go-118-fuzz-build -tags gofuzz -o <fuzzer>.a -func <Func> <abs_pkg_dir>
#   $CXX $CXXFLAGS $LIB_FUZZING_ENGINE <fuzzer>.a -o $OUT/<fuzzer>
#
# Fuzzed surfaces:
#   udp/coder.DefaultCoder.Decode   — parse a CoAP-over-UDP message
#   tcp/coder.DefaultCoder.Decode   — parse a CoAP-over-TCP message (RFC 8323 framing)
#   message.Options.Unmarshal       — parse the CoAP option stream
#   message/codes.Code.UnmarshalJSON— parse a CoAP response-code from JSON/text
#
# We produce one /mayhem/<fuzzer> per target.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

: "${SRC:=/mayhem}"
cd "$SRC"
go version

# go-118-fuzz-build rewrites the native harness onto its own testing shim, which must be a
# module dep. Order matters: tidy first, THEN `go get` the shim (tidy would otherwise prune it,
# since nothing imports it until the builder generates the entrypoint).
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# build_one <abs_pkg_dir> <FuzzFunc> <out_name>
build_one() {
  local dir="$1" func="$2" name="$3"
  echo "=== building $name ($func via go-118-fuzz-build -tags gofuzz, $dir) ==="
  go-118-fuzz-build -tags gofuzz -o "$SRC/mayhem-build/$name.a" -func "$func" "$dir"
  # Pass $GO_DEBUG_FLAGS on the final clang++ link so the C-shim CU carries DWARF3.
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/$name.a" -o "/mayhem/$name"
  echo "built /mayhem/$name"
}

build_one "$SRC/udp/coder"     FuzzDecode        fuzz_decode_udp
build_one "$SRC/tcp/coder"     FuzzDecode        fuzz_decode_tcp
build_one "$SRC/message"       FuzzUnmarshalData fuzz_unmarshal_data
build_one "$SRC/message/codes" FuzzUnmarshalJSON fuzz_unmarshal_json

# Oracle support: a dynamically-linked C shim that exec()s `go test -json -count=1` for go-coap
# (SPEC §6.3 anti-reward-hack). Pure Go binaries and the `go` tool itself are statically linked,
# so LD_PRELOAD bypasses them. A thin C shim wrapper IS intercepted by LD_PRELOAD — when sabotaged,
# the shim gets _exit(0) before exec(), producing no output → the oracle counts differ → detected.
# The shim hard-codes the go binary path and the packages to test; argv[1..] passed as extra flags.
cat > "$SRC/mayhem-build/test-runner.c" << 'CEOF'
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define GOBIN   "/opt/toolchains/go/bin/go"
/* Packages covering the fuzzed surfaces: message parser, udp/tcp coders, utilities */
static const char *GOPKGS[] = {
    "github.com/plgd-dev/go-coap/v3/message/...",
    "github.com/plgd-dev/go-coap/v3/udp/coder/...",
    "github.com/plgd-dev/go-coap/v3/tcp/coder/...",
    "github.com/plgd-dev/go-coap/v3/pkg/...",
    NULL
};
int main(int argc, char **argv) {
    /* Count packages */
    int npkgs = 0;
    while (GOPKGS[npkgs]) npkgs++;
    /* Build args: go test -json -count=1 <pkg>... [extra...] */
    int nfixed = 4 + npkgs; /* go, test, -json, -count=1, pkgs... */
    int extra   = argc - 1;
    char **args = (char **)malloc((nfixed + extra + 1) * sizeof(char *));
    if (!args) return 1;
    int i = 0;
    args[i++] = (char *)GOBIN;
    args[i++] = (char *)"test";
    args[i++] = (char *)"-json";
    args[i++] = (char *)"-count=1";
    for (int p = 0; p < npkgs; p++) args[i++] = (char *)GOPKGS[p];
    for (int j = 1; j <= extra; j++) args[i++] = argv[j];
    args[i] = NULL;
    execv(GOBIN, args);
    perror("execv " GOBIN);
    return 127;
}
CEOF
$CC $GO_DEBUG_FLAGS -o "$SRC/mayhem-build/test-runner" "$SRC/mayhem-build/test-runner.c"
echo "built $SRC/mayhem-build/test-runner (go test shim)"

echo "build.sh complete:"
ls -la /mayhem/fuzz_decode_udp /mayhem/fuzz_decode_tcp /mayhem/fuzz_unmarshal_data /mayhem/fuzz_unmarshal_json 2>&1 || true
