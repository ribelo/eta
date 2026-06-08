# P-Lbug-1 Arrow Survey

Status: Confirmed for the P-Lbug-1 workload slice.

Evidence:

- LadybugDB 0.17.0 exposes Arrow C data structs directly in /tmp/ladybug/src/include/c_api/lbug.h.
- Query result Arrow access is through lbug_query_result_get_arrow_schema and lbug_query_result_get_next_arrow_chunk.
- opam list --installed --short returned no installed OCaml Arrow package in this shell, so the fair probe used a minimal local C-data binding around LadybugDB's exported ArrowSchema and ArrowArray structs.
- p_lbug_1.log shows that MATCH (p:Person {name: 'Ada'}) RETURN p returns an Arrow root struct with one p child. The p child is a struct with _ID, _LABEL, id, name, age, and active children.
- The fixture decodes those buffers into an OCaml record and records ocaml_node.assertions=pass.

Unmeasured:

- No broad OCaml Arrow package compatibility matrix.
- No full Arrow type-system binding.
- No multi-row or multi-chunk result decoding.
