# from_file research lab

This lab reopens the `Stream.from_file` error-channel decision.

Candidates:

- `f_a_typed_default.ml` - `from_file` fails with a public `` `File_error of file_error`` row.
- `f_b_mapper_only.ml` - callers map `file_error` into their own error type at construction.
- `f_c_unsafe_exn.ml` - file I/O exceptions remain defects.
- `f_d_preopened_flow.ml` - stream reads from an already-open flow; caller owns open/close and open errors.

Run:

~~~sh
nix develop -c dune exec .scratch/research/evidence/from_file_research/runtime_smoke.exe
~~~

Result captured in `journal.md`: typed default plus explicit mapper is the winning public shape.
