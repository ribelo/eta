# eta-stream

`eta-stream` adds pull-shaped streams and fold-shaped sinks on top of
Eta's `('a, 'err) Effect.t`.

Streams keep Eta's two channels:

- `'a` is the emitted element type.
- `'err` is the typed error row.

## Quick Start

```ocaml
open Eta
open Eta_stream

let program =
  Stream.from_iterable [ 1; 2; 3; 4; 5; 6 ]
  |> Stream.map (( * ) 2)
  |> Stream.take 5
  |> fun stream -> run stream (Sink.fold ( + ) 0)
```

Run the returned effect with an Eta runtime:

```ocaml
Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let rt =
  Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ()
in
Runtime.run rt program
```

## Concurrency

`Stream.merge left right` runs both producers concurrently and interleaves
values through a bounded internal queue. If downstream stops early, both
producer fibers are cancelled.

`Stream.flat_map_par ~max_concurrency f stream` starts inner streams in bounded
parallel. A semaphore enforces the concurrency limit; downstream early
completion cancels remaining inner producers.

## Resources

`Stream.from_file ?chunk_size path` opens the file when the stream is run and
emits bounded `bytes` chunks. The default chunk size is 64 KiB. Downstream
early completion, for example `take 1`, cancels the file reader instead of
reading the rest of the file, and the descriptor is closed on normal
completion, failure, or cancellation.

File I/O exceptions fail the stream through the typed error channel:

```ocaml
Stream.from_file path
(* (bytes, [> `File_error of Stream.file_error ]) Stream.t *)
```

Use `Stream.from_file_map_error` to map file errors into an application error
row at the boundary:

```ocaml
Stream.from_file_map_error
  ~on_error:(fun error -> `Storage_unavailable error)
  path
```

Cancellation remains `Cause.Interrupt`; downstream failures are not wrapped.

`Stream.from_eio_stream queue` consumes an existing `Eio.Stream.t`. The caller
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
nix develop -c dune runtest packages/eta-stream --force
```

Run the full gate:

```sh
nix develop -c dune runtest --force
```
