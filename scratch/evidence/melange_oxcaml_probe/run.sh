#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
GEN="$ROOT/_generated"
rm -rf "$GEN"
mkdir -p "$GEN"

cat > "$GEN/zero_alloc_ok.ml" <<'EOF'
let[@zero_alloc] f x = x + 1
EOF

cat > "$GEN/zero_alloc_allocates.ml" <<'EOF'
let[@zero_alloc] pair x y = (x, y)
EOF

cat > "$GEN/portable_parameter.ml" <<'EOF'
let f (x @ portable) = x
EOF

cat > "$GEN/many_arrow.mli" <<'EOF'
val map : ('a -> 'b) @ many -> 'a -> 'b
EOF

cat > "$GEN/immutable_data_kind.ml" <<'EOF'
type t : immutable_data = A
EOF

cat > "$GEN/value_mod_portable_kind.ml" <<'EOF'
type ('a : value mod portable) t = Wrap of 'a
EOF

cat > "$GEN/global_record_field.ml" <<'EOF'
type t = { global_ trace_id : string }
EOF

cat > "$GEN/local_binding.ml" <<'EOF'
let f x =
  let y @ local = x + 1 in
  y
EOF

compile_ocaml() {
  local src="$1"
  local base
  base="$(basename "$src")"
  local out="$GEN/$base.ocaml.out"
  if [[ "$src" == *.mli ]]; then
    ocamlc -c "$src" >"$out" 2>&1
  else
    ocamlopt -c "$src" >"$out" 2>&1
  fi
  local status=$?
  printf 'ocaml %-32s %s\n' "$base" "$status"
  if [[ $status -ne 0 ]]; then
    sed 's/^/  /' "$out"
  fi
  rm -f "$GEN"/*.cmi "$GEN"/*.cmo "$GEN"/*.cmx "$GEN"/*.o
}

compile_melange() {
  local src="$1"
  local base
  base="$(basename "$src")"
  local out="$GEN/$base.melange.out"
  if [[ ${#MELC[@]} -eq 0 ]]; then
    printf 'melange %-30s skipped: melc not found\n' "$base"
    return 0
  fi
  "${MELC[@]}" -c "$src" >"$out" 2>&1
  local status=$?
  printf 'melange %-30s %s\n' "$base" "$status"
  if [[ $status -ne 0 ]]; then
    sed 's/^/  /' "$out"
  fi
}

echo "# toolchain"
printf 'ocamlc:  %s\n' "$(ocamlc -version 2>/dev/null || echo missing)"
printf 'ocamlopt: %s\n' "$(ocamlopt -version 2>/dev/null || echo missing)"
if command -v melc >/dev/null 2>&1; then
  MELC=(melc)
elif [[ -d "$ROOT/_opam" ]]; then
  MELC=(opam exec "--switch=$ROOT/_opam" -- melc)
else
  MELC=()
fi
if [[ ${#MELC[@]} -eq 0 ]]; then
  printf 'melc:    missing\n'
else
  printf 'melc:    %s\n' "$("${MELC[@]}" --version 2>&1)"
fi
echo

echo "# stock OCaml"
for src in "$GEN"/*.ml "$GEN"/*.mli; do
  compile_ocaml "$src"
done

echo
echo "# Melange"
for src in "$GEN"/*.ml "$GEN"/*.mli; do
  compile_melange "$src"
done
