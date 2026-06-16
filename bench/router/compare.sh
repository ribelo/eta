#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== eta_router (OCaml) ==="
nix develop -c dune build bench/router/ocaml/bench_router.exe
cd "$PROJECT_ROOT/bench/router/ocaml"
"$PROJECT_ROOT/_build/default/bench/router/ocaml/bench_router.exe" --samples 5 | grep 'metric":"wall_ns' | tail -1

echo ""
echo "=== matchit (Rust) ==="
cd "$PROJECT_ROOT/bench/router/rust"
cargo build --release
for i in 1 2 3 4 5; do
  ./target/release/bench-matchit
done

echo ""
echo "Done. Compare OCaml 'wall_ns' / 130000 with Rust 'ns/lookup'."
