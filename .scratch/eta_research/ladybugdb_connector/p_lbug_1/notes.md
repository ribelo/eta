# P-Lbug-1 - Arrow C-data to OCaml NODE Decoder

Status: Confirmed
Verdict: Confirmed - LadybugDB 0.17.0 returns RETURN p as Arrow C-data with a struct-shaped NODE column, and a minimal local binding can decode label, internal id, and typed primitive properties into an OCaml record.

## Command

Captured log:

scratch/eta_research/ladybugdb_connector/p_lbug_1/p_lbug_1.log

Command used:

LD_LIBRARY_PATH=/tmp/ladybug/build/src dune exec scratch/eta_research/ladybugdb_connector/p_lbug_1/p_lbug_1_probe.exe

The log was captured with stdout/stderr redirected to p_lbug_1.log.

## What Was Tested

- Created an in-memory LadybugDB database.
- Created Person(id INT64, name STRING, age INT64, active BOOL, PRIMARY KEY(id)).
- Inserted one node: {id: 7, name: 'Ada', age: 42, active: true}.
- Queried MATCH (p:Person {name: 'Ada'}) RETURN p.
- Pulled Arrow C-data through lbug_query_result_get_arrow_schema and lbug_query_result_get_next_arrow_chunk.
- Decoded the Arrow buffers for _LABEL, _ID.offset, _ID.table, id, name, age, and active.
- Returned the decoded values through a typed OCaml record and asserted the expected values.

## Evidence

Relevant lines from p_lbug_1.log:

    schema name=p format=+s flags=2 children=6
    schema name=_ID format=+s flags=2 children=2
    schema name=_LABEL format=u flags=2 children=0
    schema name=id format=l flags=2 children=0
    schema name=name format=u flags=2 children=0
    schema name=age format=l flags=2 children=0
    schema name=active format=b flags=2 children=0
    decoded.label=Person
    decoded.properties.id=7
    decoded.properties.name=Ada
    decoded.properties.age=42
    decoded.properties.active=true
    decoded.assertions=pass
    ocaml_node={label=Person; internal_offset=0; internal_table=0; id=7; name=Ada; age=42; active=true}
    ocaml_node.assertions=pass
    allocation.allocated_bytes=736.000000

## LOC And Allocation

- Binding/probe LOC: 319 total across p_lbug_1.ml, p_lbug_1_stubs.c, and p_lbug_1_probe.ml.
- OCaml allocation for the typed record decode path, measured by Gc.allocated_bytes: 736 bytes for this one-node decode fixture.
- Gc.quick_stat word counters stayed at zero for this small call; Gc.allocated_bytes is the recorded allocation signal for this run.

## What Was Not Measured

- No full Arrow type-system binding was built.
- No REL or PATH decoding was tested.
- No null property, list, map, UUID, bytes, or nested value decoding was tested.
- No multi-row or multi-chunk decode profile was measured.
- No zero-copy guarantee was measured beyond direct C-data buffer reads.

## Surprise Findings

- NODE results are not opaque in the Arrow result path. LadybugDB exposes the node as a normal Arrow struct containing _ID, _LABEL, and each declared property as children.
- This makes the default workload's primitive node properties much smaller to decode than a complete Arrow type-system reimplementation.

## Stop/Continue Decision

P-Lbug-1 does not trigger the hard stop. Continue to P-Lbug-2.
