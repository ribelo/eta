
Findings are from the uploaded Repomix package.

### P1 — Pool permit leaks when closing expired idle entries fails

**File:** `lib/eta/pool.ml`, lines 91–267
**What's wrong:** `acquire_entry` first acquires a semaphore permit, then `reserve` can remove expired idle entries and transition to `Close_expired_entries`. That path closes expired entries with `close_entries ~release_permit:false`; if `release_conn` fails, `close_entries_with` fails and the state machine aborts without returning the already-acquired permit. The pool’s counters can say `total = 0`, but the semaphore has one fewer permit forever, so later acquires can block or time out even though no resource is active or idle. The relevant pieces are: `reserve` removes expired idle entries after admission, `mark_closed` skips permit release when `release_permit=false`, `close_entries_with` propagates close failures, and `next_state` uses `close_entries ~release_permit:false` before looping back.

**RED TEST:**

```ocaml
let test_pool_expired_close_failure_does_not_leak_permit () =
  let module E = Eta.Effect in
  let release_calls = ref 0 in
  let acquire = E.pure 0 in
  let release _ =
    incr release_calls;
    E.fail (`Release_failed !release_calls)
  in
  let program =
    E.bind
      (Eta.Pool.create
         ~max_size:1
         ~max_idle:1
         ~idle_lifetime:(Eta.Duration.ms 1)
         ~idle_check_interval:(Eta.Duration.hours 1)
         ~acquire
         ~release
         ())
      (fun pool ->
        E.bind
          (Eta.Pool.with_resource pool (fun _ -> E.unit))
          (fun () ->
            E.bind
              (E.delay (Eta.Duration.ms 5) E.unit)
              (fun () ->
                (* This acquire discovers the expired idle resource.
                   Its close fails. That failure should not consume pool capacity. *)
                E.bind
                  (E.catch
                     (fun _ -> E.unit)
                     (Eta.Pool.with_resource pool (fun _ -> E.unit)))
                  (fun () ->
                    (* This should be able to open a fresh resource. In the buggy
                       implementation it times out because the prior admission
                       permit was leaked. *)
                    E.timeout_as
                      (Eta.Duration.ms 20)
                      ~on_timeout:`Timed_out
                      (Eta.Pool.with_resource pool (fun _ -> E.unit))))))
  in
  match Eta_utop.run program with
  | Eta.Exit.Ok () -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf
        "pool permit leaked after expired idle close failure: %a"
        (Eta.Cause.pp (fun ppf _ -> Format.pp_print_string ppf "<err>"))
        cause
```

### P1 — DuckDB exposes `list` types but never materializes result lists

**File:** `lib/duckdb/duckdb_stubs.c`, lines 330–386; `lib/duckdb/types.ml`, lines 250–263
**What's wrong:** The public DuckDB type layer exposes `val list : 'a typ -> 'a list typ`, and its decoder only accepts `Value.List`. But the C result materializer never constructs `Value.List` or `Value.Struct`; non-scalar DuckDB values fall through to `api.value_varchar` and become string-ish variants. In particular, the stub’s default branch maps known logical type tags to string-like constructors and has no recursive list/struct materialization, while the OCaml decoder rejects anything except `Value.List`. That makes a public advertised type fail at runtime for ordinary DuckDB list results.

**RED TEST:**

```ocaml
let test_duckdb_list_result_is_materialized_as_value_list () =
  match Eta_duckdb.available () with
  | Error _ -> ()  (* requires libduckdb in CI *)
  | Ok () ->
      let db = Result.get_ok (Eta_duckdb.Database.open_memory ()) in
      let conn = Result.get_ok (Eta_duckdb.Connection.connect db) in
      match Eta_duckdb.Connection.query conn "SELECT [1, 2, 3] AS xs" [] with
      | Ok [[ ("xs", Eta_duckdb.Value.List
                     [ Eta_duckdb.Value.Int 1
                     ; Eta_duckdb.Value.Int 2
                     ; Eta_duckdb.Value.Int 3 ]) ]] ->
          ()
      | Ok rows ->
          Alcotest.failf
            "expected DuckDB list result to decode as Value.List, got: %s"
            (String.concat "; "
               (List.map
                  (fun row ->
                    String.concat ", "
                      (List.map
                         (fun (name, value) ->
                           name ^ "=" ^ Eta_duckdb.Value.to_string value)
                         row))
                  rows))
      | Error err ->
          Alcotest.failf "query failed: %s" (Eta_duckdb.show_error err)
```

### P1 — OpenAI Responses streaming drops function-call name metadata

**File:** `lib/ai/openai_codec/stream.ml`, lines 51–90
**What's wrong:** Non-streaming Responses decoding extracts function-call `name`, `call_id`/`id`, and `arguments` from `output` items, but the streaming decoder only handles `response.function_call_arguments.delta`. It ignores `response.output_item.added`, the event that carries the function-call item metadata. As a result, stream consumers receive argument deltas with `name = None`, and often only `item_id`, making it impossible to reconstruct a valid `tool_call` equivalent from the stream without out-of-band state.

**RED TEST:**

```ocaml
let test_openai_responses_stream_preserves_function_call_name () =
  let added : Eta_ai.sse_event =
    {
      event = Some "response.output_item.added";
      data =
        {|
        {
          "type": "response.output_item.added",
          "output_index": 0,
          "item": {
            "type": "function_call",
            "id": "fc_1",
            "call_id": "call_1",
            "name": "lookup",
            "arguments": ""
          }
        }
        |};
    }
  in
  match Eta_ai_openai_codec.decode_stream_event ~provider:"openai" added with
  | Ok
      [
        Eta_ai.Stream_tool_call_delta
          {
            index = Some 0;
            id = Some "call_1";
            name = Some "lookup";
            arguments_json_delta = "";
          };
      ] ->
      ()
  | Ok events ->
      Alcotest.failf
        "function-call metadata event was dropped or incomplete; got %d events"
        (List.length events)
  | Error _ ->
      Alcotest.fail "decoder rejected a valid Responses function-call metadata event"
```

### P2 — Drain counter silently clamps underflow to zero

**File:** `lib/stream/drain_counter_internal.ml`, lines 14–22
**What's wrong:** `decr_by` clamps `counter.count - n` with `max 0` instead of rejecting underflow. A double-decrement or mismatched producer/consumer accounting bug is therefore silently hidden, and `await_zero` can unblock as if all outstanding work drained correctly. The public `Drain_counter` API documents negative arguments as invalid but does not document underflow as a permitted operation; silently masking it violates the drain invariant.

**RED TEST:**

```ocaml
let test_drain_counter_underflow_is_not_silent () =
  let counter = Eta_stream.Drain_counter.create () in
  match Eta_stream.Drain_counter.decr counter with
  | exception Invalid_argument _ -> ()
  | () ->
      Alcotest.fail
        "Drain_counter.decr below zero was silently clamped instead of reporting an invariant violation"
```
