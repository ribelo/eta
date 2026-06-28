#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p scratch/r_dx_research/results
measure() { out="$1"; cmd="$2"; start=$(date +%s%3N); bash -c "$cmd"; end=$(date +%s%3N); printf 'elapsed_ms=%s\n' "$((end - start))" > "$out"; }
rm -rf _build/default/scratch/r_dx_research
measure scratch/r_dx_research/results/build_clean_all.txt 'dune build scratch/r_dx_research'
measure scratch/r_dx_research/results/build_incremental_noop.txt 'dune build scratch/r_dx_research'
rm -rf _build/default/scratch/r_dx_research/.r_dx_env_row.objs
measure scratch/r_dx_research/results/build_clean_env_row.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_env_row.objs/byte/env_top.cmi'
rm -rf _build/default/scratch/r_dx_research/.r_dx_args.objs
measure scratch/r_dx_research/results/build_clean_args.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_args.objs/byte/args_top.cmi'
rm -rf _build/default/scratch/r_dx_research/.r_dx_bag.objs
measure scratch/r_dx_research/results/build_clean_bag.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_bag.objs/byte/bag_top.cmi'
touch scratch/r_dx_research/env_m10.ml
measure scratch/r_dx_research/results/rebuild_env_touch.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_env_row.objs/byte/env_top.cmi'
touch scratch/r_dx_research/args_m10.ml
measure scratch/r_dx_research/results/rebuild_args_touch.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_args.objs/byte/args_top.cmi'
touch scratch/r_dx_research/bag_m10.ml
measure scratch/r_dx_research/results/rebuild_bag_touch.txt 'dune build _build/default/scratch/r_dx_research/.r_dx_bag.objs/byte/bag_top.cmi'
ocamlc -i -I _build/default/packages/effet/.effet.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_common.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_env_row.objs/byte scratch/r_dx_research/env_top.ml > scratch/r_dx_research/results/env_top.i 2>&1 || true
ocamlc -i -I _build/default/packages/effet/.effet.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_common.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_args.objs/byte scratch/r_dx_research/args_top.ml > scratch/r_dx_research/results/args_top.i 2>&1 || true
ocamlc -i -I _build/default/packages/effet/.effet.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_common.objs/byte -I _build/default/scratch/r_dx_research/.r_dx_bag.objs/byte scratch/r_dx_research/bag_top.ml > scratch/r_dx_research/results/bag_top.i 2>&1 || true
