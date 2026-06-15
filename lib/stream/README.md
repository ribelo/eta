# eta_stream

`eta_stream` adds pull-shaped streams and fold-shaped sinks on top of
Eta's `('a, 'err) Effect.t`.

## Package boundary

- `eta_stream` depends on `eta`, `eio`, and `cstruct`.
- It is not part of `eta`; add it only when you need streams, mailboxes, or
  bounded queues.
- The examples below use `Eta_eio.Runtime.create`; they need `eta_eio` in
  addition to `eta_stream`.

Streams keep Eta's two channels:

- `'a` is the emitted element type.
- `'err` is the typed error row.

## Quick Start

```ocaml
open Eta
open Eta_stream

let program =
  Eta_stream.from_iterable [ 1; 2; 3; 4; 5; 6 ]
  |> Eta_stream.map (( * ) 2)
  |> Eta_stream.take 5
  |> fun stream -> run stream (Sink.fold ( + ) 0)
```

Run the returned effect with an Eta runtime:

```ocaml
Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let rt =
  Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
in
Runtime.run rt program
```

## Concurrency

`Eta_stream.merge left right` runs both producers concurrently and interleaves
values through a bounded internal queue. If downstream stops early, both
producer fibers are cancelled.

`Eta_stream.flat_map_par ~max_concurrency f stream` starts inner streams in bounded
parallel. A semaphore enforces the concurrency limit; downstream early
completion cancels remaining inner producers.

## Resources

`Eta_stream.from_file ?chunk_size path` opens the file when the stream is run and
emits bounded `bytes` chunks. The default chunk size is 64 KiB. Downstream
early completion, for example `take 1`, cancels the file reader instead of
reading the rest of the file, and the descriptor is closed on normal
completion, failure, or cancellation.

File I/O exceptions fail the stream through the typed error channel:

```ocaml
Eta_stream.from_file path
(* (bytes, [> `File_error of Eta_stream.file_error ]) Eta_stream.t *)
```

Use `Eta_stream.from_file_map_error` to map file errors into an application error
row at the boundary:

```ocaml
Eta_stream.from_file_map_error
  ~on_error:(fun error -> `Storage_unavailable error)
  path
```

Cancellation remains `Cause.Interrupt`; downstream failures are not wrapped.

`Eta_stream.from_eio_stream queue` consumes an existing `Eio.Stream.t`. The caller
owns the queue and its producers. Because Eio streams do not carry an
end-of-stream marker, consumers should bound reads with `take` unless another
fiber is guaranteed to keep producing.

## Mailboxes

`Mailbox.create ?capacity ()` creates a bounded producer-side stream mailbox.
`Mailbox.offer` never blocks: it returns `Enqueued`, `Dropped`, or `Closed`.
Use `Mailbox.dropped` for cumulative drops and `Mailbox.length` for current
queued depth before consuming the mailbox with `to_stream` or
`to_batch_stream`.

## Development

Run the stream package tests:

```sh
nix develop -c dune runtest test/stream --force
```

`lib/stream` is the library; runnable tests live in `test/stream`.

Run the full gate:

```sh
nix develop -c dune runtest --force
```

Without Nix, after `opam install . --deps-only --with-test`, use `dune runtest test/stream --force`.
