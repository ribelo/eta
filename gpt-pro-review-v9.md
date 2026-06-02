Here is the big-picture analysis of the Eta codebase, separated into three independent reviews.

### 1. Correctness Review

**P0: `Effect.race` leaks `Eio.Exn.Multiple` and crashes on simultaneous failures**
In `lib/eta/effect_concurrent.ml`, `race_eval` uses a control exception (`Race_won`) to escape a switch when a child succeeds:
```ocaml
let exception Race_won in
(try
   switch_run frame @@ fun race_sw ->
   ...
with Race_won -> ());
```
If one child succeeds (throwing `Race_won`) at the exact same time another child fails with an error, Eio wraps both in an `Eio.Exn.Multiple` exception. The `try ... with Race_won -> ()` block fails to catch `Multiple`, causing the control exception to leak out of the race. The outer runtime catches it and treats `Race_won` as a fatal `Cause.Die` defect, crashing the entire race instead of returning the successful winner.

**P0: Connection pool leak via concurrent lazy initialization**
In `lib/http/client/client.ml`, `make_h1` lazily initializes origin pools:
```ocaml
match Hashtbl.find_opt pools key with
| Some pool -> Eta.Effect.pure pool
| None ->
    H1_client.make_pool ... |> Eta.Effect.map (fun pool ->
           Hashtbl.replace pools key pool;
           pool)
```
Because `make_pool` yields to perform DNS resolution and connection handshakes, two concurrent requests to the same new origin will both see `None` and create separate pools. The second pool overwrites the first in the hashtable. The first pool is permanently orphaned, leaking all of its background connections and daemons. 

**P1: Exporter daemon hang on telemetry serialization error**
In `lib/otel/eta_otel.ml`, `export_program` uses a stream to process batches. If `encode_signal_body` throws an exception (e.g., a JSON serialization error), the `flat_map_par` stream fails and the background exporter daemon exits. However, `Drain_counter.decr t.in_flight` is never called for the items still in the mailbox. Subsequent calls to `Eta_otel.flush` or `Eta_otel.shutdown` will hang waiting for `in_flight` to reach zero. 

**P1: `error_renderer` exceptions crash the observability pipeline**
In `lib/eta/runtime_instrument.ml`, the tracer pipeline assumes user-provided error renderers are flawless:
```ocaml
let emit_exception_event cause =
  RObs.exception_event_attrs_tree ~error_renderer cause ...
```
If a user's `error_renderer` throws an exception while formatting a typed failure, `emit_exception_event` crashes. This bypasses the `finish` callback, leaving the OpenTelemetry span open indefinitely and discarding the original application failure.

**P1: `ocaml-h2` state machine corruption across domains**
In `lib/http/h2/multiplexer.ml` and `lib/http/h2/connection.ml`, `H2.Client_connection.t` is accessed from the background `reader_loop`, the `writer_loop`, and user request fibers. `ocaml-h2` is not thread-safe. While cooperative scheduling makes this safe on a single domain, if a user passes an `Auto` or `H2` `Client.t` to another domain, the concurrent accesses to the state machine will corrupt memory. `auto_state` in `client.ml` also uses non-atomic `ref`s (`opened`, `released`, `last_protocol`) that will race.

**P2: DuckDB materialization stalls the Eio event loop**
In `lib/duckdb/duckdb_stubs.c`, `materialize_arrow_rows` iterates over all results from the DuckDB C-API and synchronously allocates OCaml values. While this runs on a `Blocking_runtime` systhread to avoid blocking the Eio loop directly, OCaml 5 requires systhreads to acquire the domain lock to allocate OCaml memory. A large SQL query will seize the domain lock for the entire materialization loop, causing severe latency spikes for all Eio fibers and network I/O on that domain.

---

### 2. Code Quality Review

**P2: Hardcoded polling loop for pool shutdown**
In `lib/eta/pool.ml`, `wait_until_drained` uses a hardcoded 1ms polling loop to wait for active connections to finish:
```ocaml
Effect.delay (Duration.ms 1) Effect.unit |> Effect.bind (fun () -> wait_until_drained t)
```
This wastes CPU during graceful application shutdowns. The pool already has a `mutex`; it should use an `Eio.Condition.t` to wake the shutdown fiber instantly when `t.active` reaches zero.

**P2: Tangled SQL DSL module**
`lib/sql_dsl/eta_sql_dsl_query.ml` is a 568-line file that tangles the SQL AST, string rendering, and row decoding into a single backend functor. It should be split. `Expr` and `Projection` AST definitions should live in an `ast.ml`, while `to_sql` string concatenation should be moved to a `render.ml` module to separate query declaration from backend execution logic.

**P3: TLS policy restricts to TLS 1.2 only**
In `lib/http/tls/tls_openssl_stubs.c`, the OpenSSL context is rigidly pinned to `TLS1_2_VERSION` for both minimum and maximum bounds. While enforcing a minimum of TLS 1.2 is a good practice, explicitly disabling TLS 1.3 is an unusual and overly restrictive choice for a modern HTTP client, preventing users from benefiting from 1.3's faster handshakes and improved cipher suites.

**P3: Opaque ALPN client stats**
In `lib/http/client/client.ml`, `make_h1_direct` returns a hardcoded, zeroed statistics record `(active = 0; idle = 0; ...)` from `stats_impl`. This is a leaky abstraction. It should either return a clear "Not Supported" typed error, or the `stats` type should wrap fields in `option` to reflect that one-shot clients do not track connection telemetry.

---

### 3. AI Slop Review

**P2: Hardcoded AI capabilities limit compliant providers**
In `lib/ai/openai_compat/eta_ai_openai_compat.ml`, the `capabilities` record is hardcoded:
```ocaml
image_input = false;
speech = false;
```
This is a classic AI hallucination of rigid constraints. Compliant OpenAI-style APIs (such as Groq or OpenRouter) frequently support vision and speech endpoints. Forcing them to `false` at the adapter level artificially limits what the user can do with the library.

**P3: Duplicated content evaluation logic**
The functions `content_is_text` and `contents_are_text` are identically duplicated in both `lib/ai/anthropic/eta_ai_anthropic.ml` and `lib/ai/openai_codec/content.ml`. This boilerplate should be hoisted into a shared `Eta_ai.Message` helper.

**P3: Redundant defensive casting**
In `lib/eta/effect_observability.ml`, `named_kind` checks the `error_renderer`:
```ocaml
match error_renderer with
| None -> frame
| Some render -> { frame with error_renderer = (fun err -> render (Obj.obj err)) }
```
The `(fun err -> render (Obj.obj err))` wrapper adds zero value over the function that was already passed in, generating unnecessary closures on the hot path.

**P3: Unnecessary variable bindings**
AI code often creates redundant let-bindings for immediate consumption. In `lib/http/body/transducer.ml`:
```ocaml
let feed_bytes d chunk =
  let bs = bigstring_of_bytes chunk in
  feed_bigstring d bs 0 (Bytes.length chunk)
```
This should just be inlined as `feed_bigstring d (bigstring_of_bytes chunk) 0 (Bytes.length chunk)`.

**P3: "Documentation" stating the obvious**
In `lib/eta/capabilities.mli` and `lib/eta/random.mli`, the docstrings restate the type signatures in English prose rather than explaining behavior (a hallmark of unreviewed AI generation):
```ocaml
val bool : Capabilities.random -> bool
(** [bool random] draws [true] or [false]. *)
```
It should document *how* it draws the boolean (e.g., uniform distribution) or be omitted entirely.
