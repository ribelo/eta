# Deferred Optimizations

## H2 Informational_filter zero-copy pass-through
- **Idea**: Eliminate the 3-4 copies per DATA frame in `Informational_filter` by processing frames in-place in `t.pending` instead of extracting via `String.sub`, copying to `Buffer.t`, then `Buffer.contents`, then `blit_from_string`.
- **Approach**: Change `t.pending` to `bytes`, track an offset instead of extracting substrings, and for pass-through frames (DATA), copy directly from `t.pending` to the reader buffer bypassing `t.output` entirely.
- **Expected impact**: ~1-2MB less copying per 1MB response body. Could save ~0.2-0.5ms on H2 GET 1M / POST 1M.
- **Status**: Partially tried (Bytes_buffer to eliminate `Buffer.contents` copy) but yielded no measurable improvement. The bigger win is eliminating `String.sub` + `Buffer.add_string` copies too.

## H2 read_buffer_size negotiation
- **Idea**: Increase the advertised HTTP/2 max frame size to reduce the number of frames (and thus callbacks/allocs) for large bodies.
- **Approach**: Set `H2.Config.read_buffer_size` to 64KB+ and increase the `client_reader` buffer size to `read_buffer_size + 9` to fit the largest possible frame.
- **Expected impact**: Fewer `on_read` callbacks (16 instead of 64 for 1MB), fewer mutex/condition ops, fewer allocations.
- **Status**: Tried but broke POST 1M. The `Informational_filter` or h2 internal buffering may have issues with larger frames. Need deeper investigation before retrying.

## H2 body_stream_async batching
- **Idea**: Accumulate multiple small h2 body chunks in a local batch buffer before pushing to the async queue, reducing mutex/condition operations.
- **Approach**: In `body_stream_async`, batch chunks up to 64KB and flush on batch-full or EOF.
- **Expected impact**: Reduces queue operations from 64 to ~16 per 1MB body.
- **Status**: Attempted but caused H2 GET 1M timeouts. The `scheduled` ref tracking got out of sync with the batched pushes. Needs careful redesign of the `schedule_read` / `on_read` / `on_eof` callback logic.

## Eio.Stream instead of mutex+queue+condition
- **Idea**: Replace the manual `Eio.Mutex` + `Queue` + `Eio.Condition` in `body_stream_async` with `Eio.Stream`, which is designed for producer-consumer communication.
- **Expected impact**: Simpler code, potentially more efficient synchronization.
- **Status**: Not tried.

## TLS cipher suite tuning
- **Idea**: `ocaml-tls` may be using slower cipher suites than Go's `crypto/tls`. Explicitly configuring faster ciphers (e.g. AES-128-GCM instead of AES-256-GCM, or ChaCha20-Poly1305 on non-AES-NI CPUs) might help.
- **Expected impact**: Unknown. Could be 10-50% improvement on TLS-heavy workloads.
- **Status**: Not tried. Requires understanding `Eta_http_tls.Config` and `ocaml-tls` configuration.

## Body stream API with bigstring chunks
- **Idea**: Change `Body.Stream.read_result` to support `Bigstringaf.t` chunks natively, eliminating the `Bigstringaf.blit_to_bytes` copy in `push_chunk` entirely.
- **Expected impact**: 1MB less copying per 1MB response body. ~0.5-1ms savings on H2 large body scenarios.
- **Status**: Not tried. Invasive API change affecting multiple modules.
