#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

OCAML_SAMPLES=11
RUST_SAMPLES=5
LOOKUPS=130000

# --- OCaml eta_router ---
nix develop -c dune build --profile release bench/router/ocaml/bench_router.exe
ocaml_wall_ns=$(
  cd "$PROJECT_ROOT/bench/router/ocaml" && \
  "$PROJECT_ROOT/_build/default/bench/router/ocaml/bench_router.exe" --samples "$OCAML_SAMPLES" \
    | grep '"metric":"wall_ns"' \
    | python3 -c 'import sys, json; print(json.loads(sys.stdin.read())["mean"])'
)
ocaml_ns_per_lookup=$(python3 -c "print($ocaml_wall_ns / $LOOKUPS)")

# --- Rust matchit ---
cd "$PROJECT_ROOT/bench/router/rust"
cargo build --release
rust_ns_per_lookup=0
for _ in $(seq 1 "$RUST_SAMPLES"); do
  sample=$(./target/release/bench-matchit | grep -oP '=> \K[0-9.]+(?= ns/lookup)')
  rust_ns_per_lookup=$(python3 -c "print($rust_ns_per_lookup + $sample)")
done
rust_ns_per_lookup=$(python3 -c "print($rust_ns_per_lookup / $RUST_SAMPLES)")

cd "$PROJECT_ROOT"
ratio=$(python3 -c "print($ocaml_ns_per_lookup / $rust_ns_per_lookup)")

echo "METRIC ocaml_ns_per_lookup=$ocaml_ns_per_lookup"
echo "METRIC rust_ns_per_lookup=$rust_ns_per_lookup"
echo "METRIC ratio=$ratio"
