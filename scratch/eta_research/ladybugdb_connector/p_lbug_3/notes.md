# P-Lbug-3 - Cypher Parameterization

Status: Partial
Verdict: Partial - named Cypher parameters work for the workload's primitive scalar types, null, list, and map values. Bytes are Untested because LadybugDB 0.17.0's C API exposes blob getters but no visible blob value constructor or blob bind function.

## Command

Captured log:

scratch/eta_research/ladybugdb_connector/p_lbug_3/p_lbug_3.log

Command used:

nix develop -c env LD_LIBRARY_PATH=/tmp/ladybug/build/src dune exec scratch/eta_research/ladybugdb_connector/p_lbug_3/p_lbug_3_probe.exe

The log was captured with stdout/stderr redirected to p_lbug_3.log.

## What Was Tested

- Prepared named Cypher parameters using $name syntax.
- Bound primitive scalar values through typed prepared-statement APIs:
  - string
  - int64
  - double
  - bool
- Bound edge-case strings:
  - empty string
  - 2048-byte string
- Bound an int64 boundary value: 9223372036854775806.
- Bound NULL through lbug_value_create_null plus lbug_prepared_statement_bind_value.
- Bound a list of int64 values through lbug_value_create_list plus bind_value.
- Bound a map of string keys to int64 values through lbug_value_create_map plus bind_value.
- Executed each prepared statement and checked returned counts or returned value success.

## Evidence

Relevant lines from p_lbug_3.log:

    primitive.prepare_state=LbugSuccess
    primitive.execute_state=LbugSuccess
    primitive.count=1
    primitive.assertion=pass
    empty_string.assertion=pass
    long_string.assertion=pass
    large_int64.assertion=pass
    null_optional.value=true
    null_optional.assertion=pass
    list_value.count=3
    list_value.assertion=pass
    map_value.execute_state=LbugSuccess
    map_value.result=$m
    {a=10, b=20}
    map_value.assertion=pass
    bytes_parameter.status=Untested
    bytes_parameter.blocker=no lbug_value_create_blob or prepared_statement_bind_blob symbol in c_api/lbug.h

## Surprise Findings

- Map parameters can be bound and returned, but direct field projection syntax tried first (RETURN $m.a + $m.b) failed with an unhelpful unknown execution error. The production API should not assume Cypher map field projection works on bound map parameters until separately tested.
- lbug_value_destroy owns heap values returned by lbug_value_create_*; manually freeing those pointers caused a double free in the first fixture attempt. The driver must treat lbug_value_destroy as the only destructor for those values.

## What Was Not Measured

- Bytes/blob parameter binding remains Untested.
- Float32 was not separately tested; double was tested.
- UUID was not tested.
- Nested lists/maps were not tested.
- Parameterized CREATE/UPDATE was not tested; this probe covers MATCH/RETURN/UNWIND query parameters.

## Stop/Continue Decision

P-Lbug-3 is Partial but does not trigger a stop condition. Continue to P-Lbug-4.
