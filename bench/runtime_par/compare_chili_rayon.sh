#!/usr/bin/env bash
# Run chili's overhead bench (which also reports baseline + rayon
# numbers — all three sit in .reference/chili/benches/overhead.rs)
# and our par bench_tree_sum at matching layer counts, then
# print a single side-by-side table.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

LAYERS_LIST="${LAYERS:-10,24}"
WORKERS="${WORKERS:-4}"
ITERS="${ITERS:-5}"

# --- 1. Build everything ---------------------------------------------------
echo "[1/3] Building par bench (release)..."
nix develop -c dune build --profile=release bench/runtime_par/bench_tree_sum.exe >/dev/null

PAR_BIN="$(pwd)/_build/default/bench/runtime_par/bench_tree_sum.exe"
CHILI_DIR="${CHILI_DIR:-.reference/chili}"

# --- 2. Run chili's bench --------------------------------------------------
echo "[2/3] Running chili overhead bench (release)..."
if [ ! -d "$CHILI_DIR" ]; then
  echo "missing chili checkout: set CHILI_DIR to a checkout with benches/overhead.rs" >&2
  exit 2
fi
CHILI_OUT="$(mktemp)"
trap 'rm -f "$CHILI_OUT"' EXIT
( cd "$CHILI_DIR" && cargo bench --bench overhead 2>&1 ) > "$CHILI_OUT" || true

# --- 3. Run par tree_sum bench ----------------------------------------
echo "[3/3] Running par tree_sum bench..."
PAR_OUT="$(mktemp)"
trap 'rm -f "$CHILI_OUT" "$PAR_OUT"' EXIT
nix develop -c "$PAR_BIN" --layers "$LAYERS_LIST" --workers "$WORKERS" --iters "$ITERS" \
  > "$PAR_OUT" 2>&1

# --- 4. Parse + assemble combined table -----------------------------------
echo
echo "tree_sum overhead — chili / rayon / par on the same machine"
echo "machine: $(awk -F: '/model name/ {gsub(/^ /, "", $2); print $2; exit}' /proc/cpuinfo)"
echo "cores:   $(getconf _NPROCESSORS_ONLN)    par workers: $WORKERS"
echo

# chili divan output uses tuples like (10, 1023) and (24, 16777215).
# Extract median for each (layers, n_nodes) of each backend.

extract_chili() {
  # $1 = backend name in divan output (chili_overhead | rayon_overhead | no_overhead)
  # $2 = layer arg, e.g. "(10, 1023)"
  # Prints the median column.
  awk -v back="$1" -v args="$2" '
    /^├─|^╰─|^├ |^╰ / { in_back = ($0 ~ back) }
    in_back && $0 ~ args {
      # Median is the third "value+unit" pair.  Divan rows look like:
      #   "│  ├─ (10, 1023)      1.883 µs      │ 10.72 µs      │ 1.963 µs    │ ..."
      # Split on │ and pick the 4th cell (after the row label).
      n = split($0, parts, "│")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[4])
      print parts[4]
      exit
    }' "$CHILI_OUT"
}

extract_par() {
  # $1 = layer integer
  awk -v lay="$1" '
    $0 ~ ("^METRIC TREE_LAYERS_" lay "_PAR_NS=") {
      sub(/.*=/, "")
      print $0
      exit
    }' "$PAR_OUT"
}

extract_par_baseline() {
  awk -v lay="$1" '
    $0 ~ ("^METRIC TREE_LAYERS_" lay "_BASELINE_NS=") {
      sub(/.*=/, "")
      print $0
      exit
    }' "$PAR_OUT"
}

fmt_ns() {
  # Take ns, print human-friendly
  python3 -c "
ns = float('$1')
if ns >= 1e9: print(f'{ns/1e9:.2f} s')
elif ns >= 1e6: print(f'{ns/1e6:.2f} ms')
elif ns >= 1e3: print(f'{ns/1e3:.2f} \u00b5s')
else: print(f'{ns:.0f} ns')
"
}

printf "%-8s %-12s %-14s %-14s %-14s %-14s %-12s %-12s\n" \
  "layers" "n_nodes" "rust_baseline" "ocaml_baseline" "rayon" "chili" "par" "par/chili"
printf '%s\n' "$(printf '=%.0s' {1..104})"

IFS=',' read -ra LAYERS_ARR <<< "$LAYERS_LIST"
for L in "${LAYERS_ARR[@]}"; do
  N=$(( (1 << L) - 1 ))
  TUPLE="($L, $N)"
  RUST_BASE_RAW=$(extract_chili "no_overhead" "$TUPLE")
  RAYON_RAW=$(extract_chili "rayon_overhead" "$TUPLE")
  CHILI_RAW=$(extract_chili "chili_overhead" "$TUPLE")
  PAR_NS=$(extract_par "$L")
  OCAML_BASE_NS=$(extract_par_baseline "$L")
  PAR_FMT=$(fmt_ns "$PAR_NS")
  OCAML_BASE=$(fmt_ns "$OCAML_BASE_NS")

  # Compute par/chili ratio (both in ns).  Convert chili's "13.8 ms"
  # / "1.96 µs" to ns via python.
  RATIO=$(python3 -c "
import re
def to_ns(s):
    s = s.strip()
    m = re.match(r'([0-9]+\.[0-9]+)\s*([a-zµ]+)', s)
    if not m: return float('nan')
    val = float(m.group(1)); u = m.group(2)
    if u == 's': return val * 1e9
    if u == 'ms': return val * 1e6
    if u in ('us', '\u00b5s'): return val * 1e3
    if u == 'ns': return val
    return float('nan')
chili_ns = to_ns('$CHILI_RAW')
par_ns = float('$PAR_NS')
print(f'{par_ns/chili_ns:.2f}x' if chili_ns == chili_ns else 'n/a')
")

  printf "%-8s %-12s %-14s %-14s %-14s %-14s %-12s %-12s\n" \
    "$L" "$N" "${RUST_BASE_RAW:-?}" "$OCAML_BASE" "${RAYON_RAW:-?}" "${CHILI_RAW:-?}" "$PAR_FMT" "$RATIO"
done

echo
echo "Notes:"
echo " - rust_baseline:  pure recursion, no scheduler (chili divan 'no_overhead')"
echo " - ocaml_baseline: pure recursion, no scheduler (par 'baseline')"
echo " - rayon:          rayon::join at every node (chili divan 'rayon_overhead')"
echo " - chili:          chili::join at every node (chili divan 'chili_overhead')"
echo " - par:        Par.join at every node (par bench_tree_sum)"
echo " - par/chili:      par median \u00f7 chili median"
