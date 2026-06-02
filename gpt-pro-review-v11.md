
Here are the three independent reviews of the Eta codebase.

### 1. Correctness Review

**P1: Tracer Data Race**
- **Path:** `lib/eta/tracer.ml` (Lines 114-142)
- **Detail:** `Eta.Tracer.in_memory` mutates shared mutable state (`t.spans` and `t.next_id`) without a mutex lock. Because Eio allows fibers to run concurrently, multiple fibers settling effects at the same time will race when prepending to the `t.spans` linked list or grabbing the next span ID. This will corrupt the list, drop traces, and duplicate span IDs when used by `eta_otel` for exporter self-telemetry.

**P1: HTTP/1.1 Keep-Alive Stream Corruption**
- **Path:** `lib/http/h1/h1_client_response_reader.ml` (Lines 66-68, 142)
- **Detail:** When reading HTTP/1.1 response headers, the reader pulls from the flow into a buffer. Any extra bytes beyond the headers (the start of the response body, or even the start of the *next* pipelined response) are stored in `head.initial`. The body `Source` stream consumes exactly `content_length` bytes from `initial`. However, if the server eagerly sends the next Keep-Alive response, those extra bytes sit in the leftover `initial` buffer. When the body stream finishes, `initial` is discarded. The subsequent request on the pooled connection will read directly from the TCP socket, completely missing the discarded start of its response. 

**P1: Missing ALPN Dispatch State Machine**
- **Path:** `lib/http/client/client.ml` (Lines 185-188)
- **Detail:** The `Auto` client is designed to negotiate ALPN (H1 vs H2). The `Alpn` module correctly tracks first-arrival collapse rules so concurrent requests wait for a single leader to negotiate the connection. However, the `Auto` client implementation completely ignores `Alpn.begin_request`. Concurrent requests to the same host will independently open parallel TCP connections, negotiate TLS, and overwrite the `state.h2_connections` hash table, causing severe connection storms.

**P3: Unstopped Fixed Body Writer Loop**
- **Path:** `lib/http/client/h2_client_request_writer.ml` (Lines 57-65)
- **Detail:** In `write_fixed_body_sync`, if `flush_body_writer` returns `` `Closed `` (indicating the socket or stream is dead), the inner chunk-writing loop breaks. However, the outer `List.iter write_chunk chunks` does not stop. It will continue spinning through every remaining chunk and performing pointless writes against a closed H2 writer.

---

### 2. Code Quality Review

**P2: H1 Client Pool Entanglement**
- **Path:** `lib/http/h1/h1_client.ml` (Lines 123-167)
- **Detail:** The HTTP/1.1 client inextricably links the HTTP protocol transaction logic into the connection pool checkout lifecycle (`request_owner`). It coordinates request completion, flow release, and cancellation across three ad-hoc single-capacity channels (`response_ch`, `release_ch`, `cancel_ch`). A cleaner and more maintainable abstraction would isolate the H1 state machine, allowing the pool to blindly lease a connected flow without knowing about HTTP semantics.

**P3: Repetitive C Stub Boilerplate**
- **Path:** `lib/duckdb/duckdb_stubs.c`, `lib/sql/sqlite_stubs.c`, `lib/turso/turso_stubs.c`
- **Detail:** Across the different C integrations, identical structural boilerplate is duplicated. Features like custom block allocation, `caml_failwith` string formatting blocks, and `caml_enter_blocking_section` safety wrappers should be abstracted into a shared C header.

**P3: Missing `.mli` for Core Internals**
- **Path:** `lib/eta/runtime_core.ml`, `lib/eta/effect_core.ml`
- **Detail:** These files define the most delicate boundary in the entire library, utilizing `Obj.repr` downcasting and dynamic exception keys for typed errors. Despite this high risk, they lack `.mli` signatures, leaking unsafe implementation details into the broader `eta` package namespace.

---

### 3. AI Slop Review

**P3: Inefficient Percent Encoding**
- **Path:** `lib/ai/openai/realtime.ml` (Lines 185-188)
- **Detail:** The `percent_encode` function loops over characters and evaluates `Printf.sprintf "%%%02X"` for every single escaped byte. Firing up the full OCaml `Printf` engine inside a loop for a single hex byte is extremely heavy and a classic hallmark of unreviewed AI code. It should format the byte directly against a static hex-character lookup string.

**P3: Duplicated Zero-Alloc Formatting**
- **Path:** `lib/http/core/url.ml` (Lines 184-206) and `lib/http/h1/write.ml` (Lines 52-73)
- **Detail:** A highly specific, low-level block of zero-allocation string manipulation functions (`decimal_digits_loop`, `decimal_digits`, `blit_int_loop`, `blit_int`) is copy-pasted verbatim between two files. This defensive optimization code should be unified in a shared helper module.

**P3: Redundant Library Re-Implementations**
- **Path:** `lib/eta/cause.ml` (Lines 8-15)
- **Detail:** The file manually implements `equal_option` using pattern matching. This adds unnecessary boilerplate as `Option.equal` has existed in the OCaml standard library since 4.08.

**P3: Gratuitous Type Aliases**
- **Path:** `lib/sql/sqlite.ml` (Lines 88-89)
- **Detail:** The file defines `let rc_code rc = rc` and `let rc_equal = Int.equal`. These wrapper bindings add absolutely zero value over using the underlying values/functions directly, cluttering the code with useless indirection.
