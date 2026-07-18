#!/usr/bin/env bash
# E5 archaeology capture: compile probes against the MAIN workspace build and
# record ACTUAL compiler output; build and run the cross-domain runtime probe
# under `timeout`. Run from the repository root inside `nix develop`:
#   bash .scratch/research/dx/e5/archaeology/capture.sh
set -uo pipefail
cd "$(dirname "$0")"
ROOT=$(git rev-parse --show-toplevel)
dune build --root "$ROOT" lib/eta/eta.cmxa lib/par/eta_par.cmxa lib/eio/eta_eio.cmxa lib/ppx/ @install 2>/dev/null
B="$ROOT/_build/default"
ETA_CMI="$B/lib/eta/.eta.objs/byte"
PPX="$ROOT/_build/install/default/lib/ppx_eta/ppx.exe"

compile_probe() { # name
  local name="$1"
  echo "### $name"
  ocamlfind ocamlc -I "$ETA_CMI" -c "$name.ml" > "$name.stdout" 2> "$name.stderr"
  echo "exit=$?"
  cat "$name.stderr"
  rm -f "$name.cmo" "$name.cmi" "$name.stdout"
}

ppx_probe() { # name
  local name="$1"
  echo "### $name"
  ocamlfind ocamlc -ppx "$PPX --as-ppx" -c "$name.ml" > "$name.stdout" 2> "$name.stderr"
  echo "exit=$?"
  cat "$name.stderr"
  rm -f "$name.cmo" "$name.cmi" "$name.stdout"
}

for p in a_supervisor_return b_supervisor_ref_leak c_supervisor_escape_type_s \
         d_resource_escape e_pool_escape; do
  compile_probe "$p"
done

for p in g_ppx_sync_nonstring h_sql_nonrecord i_sql_badfield j_sql_attr_payload \
         k_sql_unknown_attr l_sql_nine_fields m_sql_empty_record n_sql_bad_shape; do
  ppx_probe "$p"
done

echo "### f_cross_domain_channel (build)"
mkdir -p _run
ocamlfind ocamlopt -thread -package eio_main,eio.unix,unix,threads.posix -linkpkg \
  -I "$ETA_CMI" -I "$B/lib/eta/.eta.objs/native" \
  -I "$B/lib/blocking/.eta_blocking.objs/byte" -I "$B/lib/blocking/.eta_blocking.objs/native" \
  -I "$B/lib/eio/.eta_eio.objs/byte" -I "$B/lib/eio/.eta_eio.objs/native" \
  -I "$B/lib/par/.eta_par.objs/byte" -I "$B/lib/par/.eta_par.objs/native" \
  "$B/lib/eta/eta.cmxa" "$B/lib/blocking/eta_blocking.cmxa" \
  "$B/lib/eio/eta_eio.cmxa" "$B/lib/par/eta_par.cmxa" \
  f_cross_domain_channel.ml -o _run/f_probe 2>&1
echo "exit=$?"
rm -f f_cross_domain_channel.cmi f_cross_domain_channel.cmx f_cross_domain_channel.o

export EIO_BACKEND=posix
for scenario in try-send blocking-pair queue-contrast; do
  echo "### f_cross_domain_channel run: $scenario (timeout 15s)"
  EIO_BACKEND=posix timeout 15 ./_run/f_probe "$scenario" 2>&1
  echo "exit=$?"
done
