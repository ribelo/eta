
P0: Memory Corruption and Type Confusion in DuckDB Arrow Decoder
Path: lib/duckdb/duckdb_stubs.c (arrow_value function)
The C stubs for DuckDB decode Arrow arrays into OCaml Eta_duckdb.Value.t values, but use entirely incorrect tags that mismatch the OCaml variant declaration.
For example, it uses caml_alloc(1, 1) (Tag 1) to return an int64 via caml_copy_int64. In Eta_duckdb.Value.t, Tag 1 is Int which expects an unboxed OCaml int. It uses Tag 2 for Float (expecting unboxed float but getting a boxed double) and Tag 3 for String (expecting string but getting Float). Passing these mismatched tags into OCaml will immediately segfault the runtime when the payload is accessed.
P1: Memory Leak in OTLP Exporter Tracing
Path: lib/otel/eta_otel.ml (export_signal) and lib/eta/tracer.ml (in_memory)
The background OTLP exporter daemon wraps its own HTTP/JSON export steps in tracing spans (eta_otel.export.encode, etc.) using its internal self_tracer (an Eta.Tracer.in_memory instance). The in_memory tracer appends all finished spans to t.spans but never clears them. Since the daemon runs continuously, self_tracer will leak memory infinitely over the lifetime of the application.
P1: Silent Transaction Corruption on Commit Failure
Path: lib/turso/connection.ml (transaction) and lib/ladybug/eta_ladybug.ml (transaction)
The transaction helpers trap exceptions and roll back, but fail to roll back if the commit operation itself returns a typed error.
If commit db fails (e.g., due to a constraint violation or lock contention), the error is propagated to the caller, but the database connection is left in an aborted or dirty transaction state. When the connection is returned to the pool, the next caller will inherit this broken state. (Note: lib/sql/pool.ml implements a separate, safe release guard, but these direct Connection.transaction helpers are fundamentally unsafe).
P2: Busy-Wait Spin Loop in Domain-Isolated Blocking
Path: lib/eta/blocking_runtime.ml (run_domain)
When an offload pool is configured as Domain_isolated, the caller fiber spawns an OCaml domain and waits for it to finish using while not (Atomic.get finished) do Eio_unix.sleep 0.001 done;. This creates a severe busy-wait loop. If an application utilizes many isolated blocking calls, it will thrash the Eio event loop with thousands of 1-millisecond sleep wakeups. It must be replaced with an Eio.Promise or a cross-domain Condition.
P2: Unbounded Cancellation Waiter Leaks in Semaphore
Path: lib/eta/semaphore.ml (acquire and take_ready_waiter)
When an acquire attempt is cancelled, the cleanup handler sets the waiter state to Cancelled but leaves it in the t.waiters queue. The queue is only purged of cancelled entries when a successful release traverses it. If a system is under heavy load and tasks frequently timeout/cancel while waiting for a depleted semaphore, the queue will grow indefinitely and leak memory.
2. Code Quality Review
P2: O(N²) Buffering in HTTP/2 Informational Filter
Path: lib/http/h2/informational_filter.ml (append_pending)
The filter manually buffers network data using Bytes.blit_string to create a new, larger string on every chunk received if parsing cannot progress. For large headers or highly fragmented HTTP/2 payloads, this degrades into O(N²) reallocation and copying.
P2: Extravagant String Allocation in WebSocket Handshake
Path: lib/http/ws/ws_client.ml (read_response_head)
The WebSocket upgrade reader appends chunks to a Buffer.t and searches for the \r\n\r\n boundary by calling Buffer.contents buffer inside the read loop. This allocates a fresh string of the entire accumulated HTTP header payload on every single chunk read, generating massive garbage.
P3: Hand-Rolled URI Parser
Path: lib/http/core/url.ml
The codebase re-implements RFC 3986 URL parsing from scratch rather than relying on the battle-tested uri package. The implementation lacks proper percent-decoding for components and will quietly pass malformed URIs to the transport layer.
P3: Monolithic Core Module
Path: lib/eta/effect_core.ml
This module is >300 lines of deeply tangled concerns. It mixes Eio frame/switch management, the core ('a, 'err) t type, standard monadic combinators (bind, map), and complex retry/delay scheduling into a single file, making the foundation harder to review and maintain.
P3: Structural Duplication across SQL Backends
Path: lib/duckdb/connection.ml and lib/turso/compiled_ops.ml
Both files contain structurally identical implementations of select and returning execution logic. They apply identical mappings to Compiled.select_decode and wrap failures in the exact same Decode_error record.
