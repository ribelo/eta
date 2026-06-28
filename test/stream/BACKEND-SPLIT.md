# Stream Test Backend Split

`test/stream_common` owns Eta stream behavior that is independent of a
concrete runtime backend and is instantiated by `test/stream_eio`.

Current shared coverage:

- Pure stream construction and combinators: iterable sources, map, take,
  grouped, take-until-effect, range, fused mapped range, merge,
  flat_map_par, and drain-counter await-zero behavior.
- `Eta_stream.Stream.from_queue`, including clean close and error close after
  draining already queued values.
- `Eta_stream.Mailbox` close/drop behavior and partial batch stream draining.
- `Eta_stream.Drain_counter` underflow validation.

`test/stream` remains the Eio-specific stream suite. Its remaining tests depend
on one or more of:

- `Eta_stream.Stream.from_file`, which accepts `Eio.Path.t` and uses Eio file
  APIs.
- Test setup that uses `Eio_main`, `Eta_eio.Runtime`, and `Eio.Path` to
  construct native file fixtures.

If Eta introduces a backend-neutral file/path abstraction, the remaining
`from_file` scenarios should move into `test/stream_common`.
