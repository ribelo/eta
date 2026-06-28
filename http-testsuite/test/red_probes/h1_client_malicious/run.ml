(* Red probe: HTTP/1 client-side malicious response handling.
   These probes feed adversarial responses to eta_http_eio's H1 client and
   report whether it detects errors, respects deadlines, and avoids pooling
   poisoned connections. Exit code is always 0: this is a bug finder, not a
   green gate. *)

open Eta_http_testsuite

type outcome =
  | Pass of string
  | Fail of string
  | Hang
  | Crash of string
  | Policy_gap of string

let string_of_outcome = function
  | Pass d -> "PASS", d
  | Fail d -> "FAIL", d
  | Hang -> "HANG", ""
  | Crash d -> "CRASH", d
  | Policy_gap d -> "POLICY_GAP", d

let loopback = Eio.Net.Ipaddr.V4.loopback
let tcp_port = Adversarial.tcp_port
let timeout_ms deadline_sec = max 1 (int_of_float (deadline_sec *. 1000.0))

let timeout_error url deadline_sec =
  let timeout_ms = timeout_ms deadline_sec in
  Eta_http.Error.make ~method_:"GET" ~uri:url
    (Eta_http.Error.Total_request_timeout { timeout_ms = Some timeout_ms })

let has_sub s sub =
  let sub_len = String.length sub in
  let rec aux i =
    if i + sub_len > String.length s then false
    else if String.sub s i sub_len = sub then true
    else aux (i + 1)
  in
  aux 0

(* ---------------------------------------------------------------------------
   Minimal raw-server helpers
   --------------------------------------------------------------------------- *)

let drain_request flow =
  let buf = Cstruct.create 4096 in
  let rec drain () =
    match Eio.Flow.single_read flow buf with
    | 0 -> false
    | n ->
        let s = Cstruct.to_string (Cstruct.sub buf 0 n) in
        if has_sub s "\r\n\r\n" then true
        else if n < 4096 then drain ()
        else drain ()
    | exception End_of_file -> false
    | exception _ -> false
  in
  drain ()

let consume_body max_bytes (response : Eta_http.Response.t) =
  Eta_http.Body.Stream.read_all ~max_bytes response.Eta_http.Response.body
  |> Eta.Effect.map (fun b -> `Body (Bytes.to_string b))

let run_client_request ~env ~server_fn ?(max_response_body_bytes = 128 * 1024 * 1024)
    ?(consume = consume_body max_response_body_bytes) ~deadline_sec () =
  try
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let socket =
      Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net (`Tcp (loopback, 0))
    in
    let port = tcp_port (Eio.Net.listening_addr socket) in
    let _server_done, resolve_server = Eio.Promise.create () in
    Eio.Fiber.fork_daemon ~sw (fun () ->
        Eio.Switch.run @@ fun conn_sw ->
        let flow, _ = Eio.Net.accept ~sw:conn_sw socket in
        Fun.protect
          ~finally:(fun () ->
            (try Eio.Flow.shutdown flow `All with _ -> ());
            ignore (Eio.Promise.try_resolve resolve_server ()))
          (fun () ->
            try server_fn flow with exn -> ignore (Printexc.to_string exn));
        `Stop_daemon);
    let url = Printf.sprintf "http://127.0.0.1:%d/" port in
    let client = Eta_http_eio.Client.make ~sw ~net ~clock () in
    let rt = Eta_eio.Runtime.create ~sw ~clock () in
    let request = Eta_http.Request.make "GET" url in
    let eff =
      Eta_http.Client.request client request
      |> Eta.Effect.bind consume
      |> Eta.Effect.timeout_as
           (Eta.Duration.ms (timeout_ms deadline_sec))
           ~on_timeout:(timeout_error url deadline_sec)
    in
    let result =
      match Eta.Runtime.run rt eff with
      | Eta.Exit.Ok x -> `Ok x
      | Eta.Exit.Error cause ->
          `Error (Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause)
    in
    ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client));
    ignore (Eio.Promise.try_resolve resolve_server ());
    result
  with exn -> `Crash (Printexc.to_string exn)

(* ---------------------------------------------------------------------------
   Pooled client helper: a queue-driven malicious server plus make_h1 pool.
   The server accepts multiple connections concurrently and pops responses from
   a shared queue, so the test works whether the pool reuses the connection or
   opens a new one.
   --------------------------------------------------------------------------- *)

let run_pool_with_responses ~env ~responses ~consume ~deadline_sec () =
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:4 net (`Tcp (loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let queue = ref responses in
  let queue_mutex = Eio.Mutex.create () in
  let pop_response () =
    Eio.Mutex.lock queue_mutex;
    Fun.protect
      ~finally:(fun () -> Eio.Mutex.unlock queue_mutex)
      (fun () ->
        match !queue with
        | [] -> None
        | r :: rest ->
            queue := rest;
            Some r)
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec accept_loop () =
        Eio.Switch.run @@ fun conn_sw ->
        let flow, _ = Eio.Net.accept ~sw:conn_sw socket in
        Eio.Fiber.fork ~sw:conn_sw (fun () ->
            Fun.protect
              ~finally:(fun () ->
                try Eio.Flow.shutdown flow `All with _ -> ())
              (fun () ->
                let rec serve () =
                  if not (drain_request flow) then ()
                  else
                    match pop_response () with
                    | None -> ()
                    | Some response ->
                        Eio.Flow.copy_string response flow;
                        let close_now =
                          has_sub (String.lowercase_ascii response)
                            "connection: close"
                          || has_sub (String.lowercase_ascii response)
                               "x-probe-close: yes"
                        in
                        if close_now then () else serve ()
                in
                serve ()));
        accept_loop ()
      in
      accept_loop ());
  let url = Printf.sprintf "http://127.0.0.1:%d/" port in
  let client = Eta_http_eio.Client.make_h1 ~sw ~net () in
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  let request = Eta_http.Request.make "GET" url in
  let run_one () =
    let eff =
      Eta_http.Client.request client request
      |> Eta.Effect.bind consume
      |> Eta.Effect.timeout_as
           (Eta.Duration.ms (timeout_ms deadline_sec))
           ~on_timeout:(timeout_error url deadline_sec)
    in
    try
      match Eta.Runtime.run rt eff with
      | Eta.Exit.Ok x -> `Ok x
      | Eta.Exit.Error cause ->
          `Error (Format.asprintf "%a" (Eta.Cause.pp Eta_http.Error.pp) cause)
    with exn -> `Crash (Printexc.to_string exn)
  in
  let r1 = run_one () in
  let r2 = run_one () in
  let stats_result =
    let zero_stats =
      {
        Eta_http.Client.protocol = Eta_http.Client.H1;
        active = 0;
        idle = 0;
        capacity = 0;
        opened = 0;
        released = 0;
      }
    in
    try
      match Eta.Runtime.run rt (Eta_http.Client.stats client) with
      | Eta.Exit.Ok (Some s) -> s
      | Eta.Exit.Ok None | Eta.Exit.Error _ -> zero_stats
    with _ -> zero_stats
  in
  ignore (Eta.Runtime.run rt (Eta_http.Client.shutdown client));
  (r1, r2, stats_result)

(* ---------------------------------------------------------------------------
   Probe builders
   --------------------------------------------------------------------------- *)

let expect_ok ?body _name = function
  | `Ok (`Body actual) -> (
      match body with
      | Some expected when String.equal actual expected ->
          Pass (Printf.sprintf "body=%d bytes" (String.length actual))
      | Some expected ->
          Fail
            (Printf.sprintf "body mismatch: expected %d bytes, got %d bytes"
               (String.length expected) (String.length actual))
      | None -> Pass (Printf.sprintf "body=%d bytes" (String.length actual)))
  | `Ok _ -> Pass "completed"
  | `Error e -> Fail (Printf.sprintf "unexpected error: %s" e)
  | `Crash e -> Crash e

let expect_error ?substr _name = function
  | `Ok (`Body actual) ->
      Fail (Printf.sprintf "expected error but got body (%d bytes)" (String.length actual))
  | `Ok _ -> Fail "expected error but completed"
  | `Error e -> (
      match substr with
      | Some sub when has_sub e sub -> Pass (Printf.sprintf "got expected error: %s" e)
      | Some sub -> Fail (Printf.sprintf "error did not contain %S: %s" sub e)
      | None -> Pass (Printf.sprintf "got error: %s" e))
  | `Crash e -> Crash e

(* 1. Response smuggling vector: both Content-Length and Transfer-Encoding.
   RFC says ignore CL when TE: chunked is present. *)
let probe_cl_te_response ~env =
  let response =
    "HTTP/1.1 200 OK\r\n"
    ^ "Content-Length: 0\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n"
    ^ "5\r\nhello\r\n0\r\n\r\n"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ~consume:(consume_body (128 * 1024 * 1024))
    ()
  |> expect_ok ~body:"hello" "cl_te_response"

(* 2. Conflicting Content-Length headers in the response. *)
let probe_conflicting_content_length ~env =
  let response =
    "HTTP/1.1 200 OK\r\n"
    ^ "Content-Length: 5\r\n"
    ^ "Content-Length: 6\r\n\r\nhello"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ()
  |> expect_error "conflicting_content_length"

(* 3. Duplicate identical Content-Length headers (currently accepted). *)
let probe_duplicate_same_content_length ~env =
  let response =
    "HTTP/1.1 200 OK\r\n"
    ^ "Content-Length: 5\r\n"
    ^ "Content-Length: 5\r\n\r\nhello"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ()
  |> expect_ok ~body:"hello" "duplicate_same_content_length"

(* 4. Oversized response header section (>32 KiB). *)
let probe_oversized_response_headers ~env =
  let big_header = String.make (40 * 1024) 'x' in
  let response =
    "HTTP/1.1 200 OK\r\nX-Flood: " ^ big_header ^ "\r\n\r\n"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ()
  |> expect_error "oversized_response_headers"

(* 5. Invalid chunk size (non-hex). *)
let probe_invalid_chunk_size_hex ~env =
  let response =
    "HTTP/1.1 200 OK\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n"
    ^ "z\r\nboom\r\n"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ()
  |> expect_error "invalid_chunk_size_hex"

(* 6. Overflow chunk size. *)
let probe_invalid_chunk_size_overflow ~env =
  let response =
    "HTTP/1.1 200 OK\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n"
    ^ String.make 64 'f' ^ "\r\n"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ()
  |> expect_error "invalid_chunk_size_overflow"

(* 7. Chunk size line with no CRLF (server stops mid-line). *)
let probe_chunk_size_line_no_crlf ~env =
  let response =
    "HTTP/1.1 200 OK\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n5"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ()
  |> expect_error "chunk_size_line_no_crlf"

(* 8. Infinite/slow chunked response: chunks keep coming. With a large body cap
   the deadline should fire before the cap. *)
let probe_infinite_chunked_response ~env =
  run_client_request ~env ~deadline_sec:2.0
    ~max_response_body_bytes:(100 * 1024 * 1024)
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        flow;
      try
        while true do
          Eio.Flow.copy_string "1\r\nx\r\n" flow;
          Eio.Time.sleep (Eio.Stdenv.clock env) 0.05
        done
      with _ -> ())
    ~consume:(consume_body (100 * 1024 * 1024))
    ()
  |> expect_error ~substr:"timeout" "infinite_chunked_response"

(* 9. Slow response headers: server waits before sending any response bytes. *)
let probe_slow_response_headers ~env =
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Time.sleep (Eio.Stdenv.clock env) 5.0;
      Eio.Flow.copy_string "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" flow)
    ()
  |> expect_error ~substr:"timeout" "slow_response_headers"

(* 10. HTTP/1.0 keep-alive with no Content-Length and server closes after body.
    The client must read until EOF and complete. *)
let probe_h10_keepalive_close_after_body ~env =
  let response =
    "HTTP/1.0 200 OK\r\nConnection: keep-alive\r\n\r\nhello"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow;
      Eio.Flow.shutdown flow `All)
    ~consume:(consume_body (128 * 1024 * 1024))
    ()
  |> expect_ok ~body:"hello" "h10_keepalive_close_after_body"

(* 11. HTTP/1.0 keep-alive with no Content-Length and server keeps connection
    open. The client has no framing and will hang until the deadline. *)
let probe_h10_keepalive_stays_open ~env =
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string
        "HTTP/1.0 200 OK\r\nConnection: keep-alive\r\n\r\nhello"
        flow;
      Eio.Time.sleep (Eio.Stdenv.clock env) 60.0)
    ~consume:(consume_body (128 * 1024 * 1024))
    ()
  |> expect_error ~substr:"timeout" "h10_keepalive_stays_open"

(* 12. Oversized status line. *)
let probe_oversized_status_line ~env =
  let reason = String.make (40 * 1024) 'x' in
  let response = "HTTP/1.1 200 " ^ reason ^ "\r\n\r\n" in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ()
  |> expect_error "oversized_status_line"

(* 13. Bare CR inside a response header value. *)
let probe_bare_cr_header ~env =
  let response =
    "HTTP/1.1 200 OK\r\nX-Bad: bad\rvalue\r\n\r\n"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ()
  |> expect_error "bare_cr_header"

(* 14. Duplicate Transfer-Encoding: chunked headers are rejected as non-final. *)
let probe_duplicate_transfer_encoding_chunked ~env =
  let response =
    "HTTP/1.1 200 OK\r\n"
    ^ "Transfer-Encoding: chunked\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n"
    ^ "5\r\nhello\r\n0\r\n\r\n"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ~consume:(consume_body (128 * 1024 * 1024))
    ()
  |> expect_error "duplicate_transfer_encoding_chunked"

(* 15. Forbidden trailer field (Content-Length) in a chunked response. *)
let probe_forbidden_trailer_content_length ~env =
  let response =
    "HTTP/1.1 200 OK\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n"
    ^ "0\r\nContent-Length: 5\r\n\r\n"
  in
  run_client_request ~env ~deadline_sec:2.0
    ~server_fn:(fun flow ->
      ignore (drain_request flow);
      Eio.Flow.copy_string response flow)
    ()
  |> expect_error "forbidden_trailer_content_length"

(* ---------------------------------------------------------------------------
   Pool-focused probes
   --------------------------------------------------------------------------- *)

let pool_outcome _name expected_opened (r1, r2, stats) =
  let opened = stats.Eta_http.Client.opened in
  let reused = opened = 1 in
  let detail =
    Printf.sprintf "opened=%d released=%d active=%d idle=%d" opened
      stats.Eta_http.Client.released stats.Eta_http.Client.active
      stats.Eta_http.Client.idle
  in
  match (r1, r2) with
  | `Ok (`Body _b1), `Ok (`Body _b2) ->
      if opened = expected_opened then Pass detail
      else if expected_opened = 1 && not reused then
        Policy_gap (Printf.sprintf "%s; connection was not reused" detail)
      else Fail (Printf.sprintf "%s; expected opened=%d" detail expected_opened)
  | `Error e1, `Ok (`Body _) ->
      if expected_opened >= 1 then Pass (Printf.sprintf "first errored, second ok; %s" detail)
      else Fail (Printf.sprintf "unexpected error on first: %s; %s" e1 detail)
  | `Ok (`Body _), `Error e2 ->
      Fail (Printf.sprintf "second errored: %s; %s" e2 detail)
  | `Error e1, `Error e2 ->
      Fail (Printf.sprintf "both errored: %s / %s; %s" e1 e2 detail)
  | `Crash e, _ | _, `Crash e -> Crash e
  | _ -> Fail (Printf.sprintf "unexpected result shapes; %s" detail)

(* 16. Clean pool reuse: two fixed-length responses on one connection. *)
let probe_pool_clean_reuse ~env =
  let responses =
    [
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none";
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo";
    ]
  in
  run_pool_with_responses ~env ~responses
    ~consume:(consume_body (128 * 1024 * 1024))
    ~deadline_sec:2.0 ()
  |> pool_outcome "pool_clean_reuse" 1

(* 17. Server closes a keep-alive connection immediately after a clean response.
   The pool may hand out the dead connection within the 5-second health-check
   window, causing the next request to fail. *)
let probe_pool_dead_keepalive_connection ~env =
  let responses =
    [
      "HTTP/1.1 200 OK\r\nConnection: keep-alive\r\nX-Probe-Close: yes\r\nContent-Length: 5\r\n\r\nhello";
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nnew";
    ]
  in
  run_pool_with_responses ~env ~responses
    ~consume:(consume_body (128 * 1024 * 1024))
    ~deadline_sec:2.0 ()
  |> pool_outcome "pool_dead_keepalive_connection" 2

(* 18. Leftover bytes after a fixed-length body force a new connection. *)
let probe_pool_leftover_after_fixed_body ~env =
  let responses =
    [
      "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
      ^ "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\npoi";
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nnew";
    ]
  in
  run_pool_with_responses ~env ~responses
    ~consume:(consume_body (128 * 1024 * 1024))
    ~deadline_sec:2.0 ()
  |> pool_outcome "pool_leftover_after_fixed_body" 2

(* 19. Leftover bytes after a chunked body force a new connection. *)
let probe_pool_leftover_after_chunked_body ~env =
  let responses =
    [
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
      ^ "5\r\nhello\r\n0\r\n\r\n"
      ^ "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\npoi";
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nnew";
    ]
  in
  run_pool_with_responses ~env ~responses
    ~consume:(consume_body (128 * 1024 * 1024))
    ~deadline_sec:2.0 ()
  |> pool_outcome "pool_leftover_after_chunked_body" 2

(* 20. Connection reuse after a parse error: the first response is malformed,
   the second must succeed on a fresh connection. *)
let probe_pool_recovery_after_parse_error ~env =
  let responses =
    [
      "GARBAGE HTTP/1.1\r\n\r\n";
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nnew";
    ]
  in
  run_pool_with_responses ~env ~responses
    ~consume:(consume_body (128 * 1024 * 1024))
    ~deadline_sec:2.0 ()
  |> pool_outcome "pool_recovery_after_parse_error" 2

(* 21. Connection reuse after a chunked decode error. *)
let probe_pool_recovery_after_chunked_error ~env =
  let responses =
    [
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nz\r\nboom\r\n";
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nnew";
    ]
  in
  run_pool_with_responses ~env ~responses
    ~consume:(consume_body (128 * 1024 * 1024))
    ~deadline_sec:2.0 ()
  |> pool_outcome "pool_recovery_after_chunked_error" 2

(* 22. HTTP/1.0 keep-alive with explicit Content-Length should reuse the same
   connection for two requests. *)
let probe_pool_h10_keepalive_reuse ~env =
  let responses =
    [
      "HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 3\r\n\r\none";
      "HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 3\r\n\r\ntwo";
    ]
  in
  run_pool_with_responses ~env ~responses
    ~consume:(consume_body (128 * 1024 * 1024))
    ~deadline_sec:2.0 ()
  |> pool_outcome "pool_h10_keepalive_reuse" 1

(* ---------------------------------------------------------------------------
   Orchestration
   --------------------------------------------------------------------------- *)

let probes () =
  [
    ("cl_te_response", probe_cl_te_response);
    ("conflicting_content_length", probe_conflicting_content_length);
    ("duplicate_same_content_length", probe_duplicate_same_content_length);
    ("oversized_response_headers", probe_oversized_response_headers);
    ("invalid_chunk_size_hex", probe_invalid_chunk_size_hex);
    ("invalid_chunk_size_overflow", probe_invalid_chunk_size_overflow);
    ("chunk_size_line_no_crlf", probe_chunk_size_line_no_crlf);
    ("infinite_chunked_response", probe_infinite_chunked_response);
    ("slow_response_headers", probe_slow_response_headers);
    ("h10_keepalive_close_after_body", probe_h10_keepalive_close_after_body);
    ("h10_keepalive_stays_open", probe_h10_keepalive_stays_open);
    ("oversized_status_line", probe_oversized_status_line);
    ("bare_cr_header", probe_bare_cr_header);
    ("duplicate_transfer_encoding_chunked", probe_duplicate_transfer_encoding_chunked);
    ("forbidden_trailer_content_length", probe_forbidden_trailer_content_length);
    ("pool_clean_reuse", probe_pool_clean_reuse);
    ("pool_dead_keepalive_connection", probe_pool_dead_keepalive_connection);
    ("pool_leftover_after_fixed_body", probe_pool_leftover_after_fixed_body);
    ("pool_leftover_after_chunked_body", probe_pool_leftover_after_chunked_body);
    ("pool_recovery_after_parse_error", probe_pool_recovery_after_parse_error);
    ("pool_recovery_after_chunked_error", probe_pool_recovery_after_chunked_error);
    ("pool_h10_keepalive_reuse", probe_pool_h10_keepalive_reuse);
  ]

let run_probe env (name, probe) =
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Time.with_timeout_exn clock 30.0 (fun () -> (name, probe ~env))
  with
  | Eio.Time.Timeout -> (name, Hang)
  | exn -> (name, Crash (Printexc.to_string exn))

let () =
  let results = Eio_main.run (fun env -> List.map (run_probe env) (probes ())) in
  List.iter
    (fun (name, outcome) ->
      let status, detail = string_of_outcome outcome in
      if String.equal detail "" then Printf.printf "probe %s %s\n%!" name status
      else Printf.printf "probe %s %s %s\n%!" name status detail)
    results;
  Printf.printf "h1_client_malicious done probes=%d\n%!" (List.length results)
