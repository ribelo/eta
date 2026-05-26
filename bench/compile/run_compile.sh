#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

quick=false
filter=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick) quick=true; shift ;;
    --filter) filter="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

samples=3
if [ "$quick" = true ]; then samples=1; fi

want() {
  if [ -z "$filter" ]; then return 0; fi
  printf '%s\n' "$1" | grep -E "$filter" >/dev/null 2>&1
}

emit() {
  local name="$1"
  local metric="$2"
  local unit="$3"
  local values="$4"
  awk -v name="$name" -v metric="$metric" -v unit="$unit" -v values="$values" '
    BEGIN {
      n = split(values, xs, ",");
      sum = 0; min = xs[1] + 0; max = xs[1] + 0;
      for (i = 1; i <= n; i++) {
        v = xs[i] + 0; vals[i] = v; sum += v;
        if (v < min) min = v;
        if (v > max) max = v;
      }
      mean = sum / n;
      ss = 0;
      for (i = 1; i <= n; i++) { d = vals[i] - mean; ss += d * d; }
      stddev = n > 1 ? sqrt(ss / (n - 1)) : 0;
      printf("{\"name\":\"%s\",\"metric\":\"%s\",\"unit\":\"%s\",\"samples\":[", name, metric, unit);
      for (i = 1; i <= n; i++) { if (i > 1) printf(","); printf("%.6f", vals[i]); }
      printf("],\"mean\":%.6f,\"stddev\":%.6f,\"min\":%.6f,\"max\":%.6f}\n", mean, stddev, min, max);
    }'
}

measure_cmd() {
  local name="$1"
  local cmd="$2"
  if ! want "$name"; then return 0; fi
  local values=""
  local i=0
  while [ "$i" -lt "$samples" ]; do
    start="$(date +%s%3N)"
    sh -c "$cmd" >/dev/null
    end="$(date +%s%3N)"
    local value="$((end - start))"
    if [ -z "$values" ]; then values="$value"; else values="$values,$value"; fi
    i="$((i + 1))"
  done
  emit "$name" "wall_ms" "ms" "$values"
}

measure_ocamlc_i() {
  local name="$1"
  local file="$2"
  local includes="$3"
  if ! want "$name"; then return 0; fi
  dune build packages/eta packages/schema packages/ppx >/dev/null
  local out="$(mktemp)"
  ocamlc -i $includes "$file" > "$out" 2>/dev/null || true
  local bytes="$(wc -c < "$out" | tr -d ' ')"
  local lines="$(wc -l < "$out" | tr -d ' ')"
  rm -f "$out"
  emit "$name.bytes" "bytes" "bytes" "$bytes"
  emit "$name.lines" "lines" "lines" "$lines"
}

packages="ai ai_anthropic ai_openai ai_openai_codec ai_openai_compat ai_openrouter eta http otel par ppx redacted schema schema_test sql stream test"
for pkg in $packages; do
  path="packages/$pkg"
  safe="$(printf '%s' "$pkg" | tr '-' '_')"
  if [ "$pkg" = "ppx" ]; then safe="ppx_eta"; fi
  main_ml="$(find "$path" -maxdepth 1 -name '*.ml' | sort | head -n 1)"
  test_ml="$(find "$path/test" -maxdepth 1 -name '*.ml' 2>/dev/null | sort | head -n 1 || true)"
  measure_cmd "compile.$safe.clean" "rm -rf _build/default/$path && dune build $path"
  if [ -n "$main_ml" ]; then
    measure_cmd "compile.$safe.touch_top" "dune build $path && touch $main_ml && dune build $path"
    measure_cmd "compile.$safe.touch_internal" "dune build $path && touch $main_ml && dune build $path"
  fi
  if [ -n "$test_ml" ]; then
    measure_cmd "compile.$safe.touch_test" "dune build $path/test && touch $test_ml && dune build $path/test"
  else
    measure_cmd "compile.$safe.touch_test" "dune build $path"
  fi
done

measure_cmd "compile.fixture.deep_bind.clean" "rm -rf _build/default/bench/fixtures/typecheck/deep_bind && dune build bench/fixtures/typecheck/deep_bind"
measure_cmd "compile.fixture.deep_bind.touch_top" "dune build bench/fixtures/typecheck/deep_bind && touch bench/fixtures/typecheck/deep_bind/tp_top.ml && dune build bench/fixtures/typecheck/deep_bind"
measure_cmd "compile.fixture.deep_bind.touch_internal" "dune build bench/fixtures/typecheck/deep_bind && touch bench/fixtures/typecheck/deep_bind/tp_m25.ml && dune build bench/fixtures/typecheck/deep_bind"
measure_ocamlc_i "compile.fixture.deep_bind.ocamlc_i" "bench/fixtures/typecheck/deep_bind/tp_top.ml" "-I _build/default/packages/eta/.eta.objs/byte -I _build/default/bench/fixtures/typecheck/deep_bind/.bench_typecheck_deep_bind.objs/byte"

measure_cmd "compile.fixture.explicit_deps.clean" "rm -rf _build/default/bench/fixtures/typecheck/explicit_deps && dune build bench/fixtures/typecheck/explicit_deps"
measure_cmd "compile.fixture.explicit_deps.touch_top" "dune build bench/fixtures/typecheck/explicit_deps && touch bench/fixtures/typecheck/explicit_deps/deps_top.ml && dune build bench/fixtures/typecheck/explicit_deps"
measure_cmd "compile.fixture.explicit_deps.touch_internal" "dune build bench/fixtures/typecheck/explicit_deps && touch bench/fixtures/typecheck/explicit_deps/deps_m10.ml && dune build bench/fixtures/typecheck/explicit_deps"
measure_ocamlc_i "compile.fixture.explicit_deps.ocamlc_i" "bench/fixtures/typecheck/explicit_deps/deps_top.ml" "-I _build/default/packages/eta/.eta.objs/byte -I _build/default/bench/fixtures/typecheck/explicit_deps/.bench_typecheck_explicit_deps.objs/byte"

measure_cmd "compile.fixture.schema_heavy.clean" "rm -rf _build/default/bench/fixtures/typecheck/schema_heavy && dune build bench/fixtures/typecheck/schema_heavy"
measure_cmd "compile.fixture.schema_heavy.touch_top" "dune build bench/fixtures/typecheck/schema_heavy && touch bench/fixtures/typecheck/schema_heavy/schema_top.ml && dune build bench/fixtures/typecheck/schema_heavy"
measure_cmd "compile.fixture.schema_heavy.touch_internal" "dune build bench/fixtures/typecheck/schema_heavy && touch bench/fixtures/typecheck/schema_heavy/schema_m05.ml && dune build bench/fixtures/typecheck/schema_heavy"
measure_ocamlc_i "compile.fixture.schema_heavy.ocamlc_i" "bench/fixtures/typecheck/schema_heavy/schema_top.ml" "-I _build/default/packages/schema/.schema.objs/byte -I _build/default/bench/fixtures/typecheck/schema_heavy/.bench_typecheck_schema_heavy.objs/byte"

measure_cmd "compile.fixture.ppx_heavy.clean" "rm -rf _build/default/bench/fixtures/typecheck/ppx_heavy && dune build bench/fixtures/typecheck/ppx_heavy"
measure_cmd "compile.fixture.ppx_heavy.touch_top" "dune build bench/fixtures/typecheck/ppx_heavy && touch bench/fixtures/typecheck/ppx_heavy/ppx_top.ml && dune build bench/fixtures/typecheck/ppx_heavy"
measure_cmd "compile.fixture.ppx_heavy.touch_internal" "dune build bench/fixtures/typecheck/ppx_heavy && touch bench/fixtures/typecheck/ppx_heavy/ppx_m03.ml && dune build bench/fixtures/typecheck/ppx_heavy"
measure_ocamlc_i "compile.fixture.ppx_heavy.ocamlc_i" "bench/fixtures/typecheck/ppx_heavy/ppx_top.ml" "-I _build/default/packages/eta/.eta.objs/byte -I _build/default/bench/fixtures/typecheck/ppx_heavy/.bench_typecheck_ppx_heavy.objs/byte"
