(* Red probe: HTTP/1 request smuggling generators.
   These probes intentionally exercise ambiguous or malicious H1 framing and
   report whether Eta handles it safely. Exit code is always 0: this is a bug
   finder, not a green gate. *)

open Eta_http_testsuite

(* ---------------------------------------------------------------------------
   Low-level H1 driver: start an Eta H1 server, speak raw bytes over a socket,
   and return the raw bytes received before the deadline.
   --------------------------------------------------------------------------- *)

let tcp_port = Adversarial.tcp_port

let h1_config = Adversarial.h1_adversarial_config

let h1_pipeline_config () =
  let base = Adversarial.h1_adversarial_config () in
  let server =
    { base.server with
      unread_body_policy = Eta_http.Server.Config.Drain_up_to (128 * 1024 * 1024)
    }
  in
  { base with server }

let response_count response =
  let prefix = "HTTP/1." in
  let prefix_len = String.length prefix in
  let rec loop count i =
    if i + prefix_len > String.length response then count
    else if String.starts_with ~prefix (String.sub response i prefix_len) then
      loop (count + 1) (i + 1)
    else loop count (i + 1)
  in
  loop 0 0

let read_responses_until ?expected_count ~clock flow deadline_sec =
  let buffer = Buffer.create 512 in
  let scratch = Cstruct.create 4096 in
  let end_time = Unix.gettimeofday () +. deadline_sec in
  let has_expected_count data =
    match expected_count with
    | None -> false
    | Some expected -> response_count data >= expected
  in
  let rec loop () =
    let remaining = end_time -. Unix.gettimeofday () in
    if remaining <= 0.0 then Buffer.contents buffer
    else
      match
        Eio.Time.with_timeout_exn clock remaining (fun () ->
            Eio.Flow.single_read flow scratch)
      with
      | 0 -> Buffer.contents buffer
      | n ->
          Buffer.add_string buffer (Cstruct.to_string (Cstruct.sub scratch 0 n));
          let data = Buffer.contents buffer in
          if has_expected_count data then data else loop ()
      | exception End_of_file -> Buffer.contents buffer
      | exception Eio.Time.Timeout -> Buffer.contents buffer
      | exception Eio.Cancel.Cancelled _ -> Buffer.contents buffer
  in
  loop ()

let status_codes response =
  let prefix = "HTTP/1." in
  let prefix_len = String.length prefix in
  let rec loop acc i =
    if i + prefix_len + 5 > String.length response then List.rev acc
    else if String.starts_with ~prefix (String.sub response i prefix_len) then
      let code_start = i + prefix_len + 2 in
      let code_str = String.sub response code_start 3 in
      let code =
        try Some (int_of_string code_str) with Failure _ -> None
      in
      loop (code :: acc) (i + 1)
    else loop acc (i + 1)
  in
  loop [] 0

let response_summary response =
  let codes = status_codes response in
  let codes_str =
    List.map (function Some c -> string_of_int c | None -> "???") codes
    |> String.concat ","
  in
  Printf.sprintf "responses=%d statuses=[%s] bytes=%d" (List.length codes)
    codes_str (String.length response)

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

let run_raw_h1 ~env ~name ?config ?expected_count ~deadline_sec ~input
    ~interpret () =
  try
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let socket =
      Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port = tcp_port (Eio.Net.listening_addr socket) in
    let config = Option.value config ~default:(h1_config ()) in
    let server =
      Eta_http_eio.Server.start_h1_on_socket ~sw ~clock ~config ~socket
        Adversarial.h1_body_draining_handler
    in
    let flow =
      Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    Fun.protect
      ~finally:(fun () ->
        (try Eio.Flow.shutdown flow `All with _ -> ());
        Eta_http_eio.Server.shutdown server Immediate)
      (fun () ->
        try
          Eio.Flow.copy_string input flow;
          let raw =
            read_responses_until ?expected_count ~clock flow deadline_sec
          in
          interpret raw
        with
        | Eio.Time.Timeout -> Hang
        | exn -> Crash (Printexc.to_string exn))
  with exn -> Crash (Printexc.to_string exn)

let run_single_h1 ~env ~name ?config ~deadline_sec ~input ~expected_status () =
  run_raw_h1 ~env ~name ?config ~expected_count:1 ~deadline_sec ~input
    ~interpret:(fun raw ->
      match status_codes raw with
      | [ Some status ] ->
          if status = expected_status then Pass (response_summary raw)
          else Fail (response_summary raw)
      | codes ->
          let got = List.length codes in
          if got = 0 then Fail "no response"
          else Fail (Printf.sprintf "expected one response, got %d" got))
    ()

let run_pipelined_h1 ~env ~name ?config ~deadline_sec ~input ~expected_count
    ~allowed_statuses () =
  run_raw_h1 ~env ~name ?config ~expected_count ~deadline_sec ~input
    ~interpret:(fun raw ->
      let codes = status_codes raw in
      let got = List.length codes in
      if got <> expected_count then
        Fail
          (Printf.sprintf "expected %d responses, got %d (%s)" expected_count
             got (response_summary raw))
      else
        let unexpected =
          List.filter
            (function
              | Some c -> not (List.mem c allowed_statuses)
              | None -> true)
            codes
        in
        if unexpected = [] then Pass (response_summary raw)
        else Fail (response_summary raw))
    ()

(* ---------------------------------------------------------------------------
   Probe builders
   --------------------------------------------------------------------------- *)

let smuggled_get = "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n"

(* 0. Sanity: two pipelined GET requests without bodies should produce two
      responses. *)
let probe_pipeline_get_get ~env =
  let input =
    "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n"
    ^ "GET / HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  run_pipelined_h1 ~env ~name:"pipeline_get_get" ~deadline_sec:2.0 ~input
    ~expected_count:2 ~allowed_statuses:[ 200 ] ()

(* 1. Classic CL/TE: front-end uses CL, back-end uses TE. Eta must reject the
      combination outright. *)
let probe_cl_te_reject ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Content-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n"
    ^ "0\r\n\r\n" ^ smuggled_get
  in
  run_single_h1 ~env ~name:"cl_te_reject" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 2. TE/CL: Transfer-Encoding listed first, then Content-Length. Still must be
      rejected because both framing headers are present. *)
let probe_te_cl_reject ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n"
    ^ "5\r\nhello\r\n0\r\n\r\n" ^ smuggled_get
  in
  run_single_h1 ~env ~name:"te_cl_reject" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 3. Duplicate Content-Length headers with differing values. *)
let probe_duplicate_cl_different ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Content-Length: 5\r\nContent-Length: 6\r\n\r\nhello" ^ smuggled_get
  in
  run_single_h1 ~env ~name:"duplicate_cl_different" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 4. Duplicate Content-Length headers with identical values. RFC 7230 allows
      recipients to treat this as an error; Eta currently rejects all duplicates.
      This probe documents that policy choice. *)
let probe_duplicate_cl_same ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Content-Length: 5\r\nContent-Length: 5\r\n\r\nhello" ^ smuggled_get
  in
  run_single_h1 ~env ~name:"duplicate_cl_same" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 5. CL-only smuggling: a correctly framed CL request whose body happens to
      contain a second request. The server should interpret this as normal
      pipelining and produce two responses. *)
let probe_cl_only_pipeline ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Content-Length: 5\r\n\r\nhello" ^ smuggled_get
  in
  run_pipelined_h1 ~env ~name:"cl_only_pipeline"
    ~config:(h1_pipeline_config ()) ~deadline_sec:2.0 ~input
    ~expected_count:2 ~allowed_statuses:[ 200 ] ()

(* 6. CL too short: the declared body is longer than the bytes sent before the
      next request appears. The server must not treat the trailing bytes as a
      valid second request; consuming the declared bytes and then rejecting the
      malformed remainder is also safe. *)
let probe_cl_too_short ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Content-Length: 10\r\n\r\nhello" ^ smuggled_get
  in
  run_raw_h1 ~env ~name:"cl_too_short" ~config:(h1_pipeline_config ())
    ~deadline_sec:2.0 ~input
    ~interpret:(fun raw ->
      let codes = status_codes raw in
      match codes with
      | [ Some 200 ] | [ Some 200; Some 400 ] -> Pass (response_summary raw)
      | [] ->
          (* No response within deadline: likely waiting for body bytes. *)
          Hang
      | _ -> Fail (Printf.sprintf "boundary confusion: %s" (response_summary raw)))
    ()

(* 7. CL too long: the declared body is shorter than the bytes sent. The server
      should consume exactly the declared length and then try to parse the
      remainder as the next request. With the pipeline policy the leftover bytes
      "loGET / HTTP/1.1..." form a syntactically valid request with method
      "loGET", so we expect a 200 echo followed by a 404. *)
let probe_cl_too_long ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Content-Length: 3\r\n\r\nhello" ^ smuggled_get
  in
  run_pipelined_h1 ~env ~name:"cl_too_long" ~config:(h1_pipeline_config ())
    ~deadline_sec:2.0 ~input ~expected_count:2 ~allowed_statuses:[ 200; 404 ] ()

(* 8. Chunked smuggling: a correctly framed chunked request followed by a second
      request. The terminator should close the first body and the second request
      should be processed normally. *)
let probe_chunked_pipeline ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Transfer-Encoding: chunked\r\n\r\n"
    ^ "5\r\nhello\r\n0\r\n\r\n" ^ smuggled_get
  in
  run_pipelined_h1 ~env ~name:"chunked_pipeline"
    ~config:(h1_pipeline_config ()) ~deadline_sec:2.0 ~input
    ~expected_count:2 ~allowed_statuses:[ 200 ] ()

(* 9. TE list with chunked not alone. Per RFC 7230 chunked must be the last
      coding; "identity, chunked" is malformed and must be rejected. *)
let probe_te_chunked_not_last ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Transfer-Encoding: identity, chunked\r\n\r\n"
    ^ "0\r\n\r\n"
  in
  run_single_h1 ~env ~name:"te_chunked_not_last" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 10. obs-fold: header continuation with a leading space. Deprecated by
       RFC 7230; accepting it would be a smuggling vector. *)
let probe_obs_fold ~env =
  let input =
    "GET / HTTP/1.1\r\nHost: example.test\r\n"
    ^ "X-Folded: value\r\n continued\r\n\r\n"
  in
  run_single_h1 ~env ~name:"obs_fold" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 11. Bare CR inside a header value. *)
let probe_bare_cr_header ~env =
  let input =
    "GET / HTTP/1.1\r\nHost: example.test\r\n"
    ^ "X-Cr: bad\rvalue\r\n\r\n"
  in
  run_single_h1 ~env ~name:"bare_cr_header" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 12. NUL inside a header value. *)
let probe_nul_header_value ~env =
  let input =
    "GET / HTTP/1.1\r\nHost: example.test\r\n"
    ^ "X-Nul: bad\x00value\r\n\r\n"
  in
  run_single_h1 ~env ~name:"nul_header_value" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 13. Tab inside a header name. *)
let probe_tab_in_header_name ~env =
  let input =
    "GET / HTTP/1.1\r\nHost: example.test\r\n"
    ^ "X-Bad\tName: value\r\n\r\n"
  in
  run_single_h1 ~env ~name:"tab_in_header_name" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 14. Whitespace inside a header name. *)
let probe_whitespace_in_header_name ~env =
  let input =
    "GET / HTTP/1.1\r\nHost: example.test\r\n"
    ^ "X Bad: value\r\n\r\n"
  in
  run_single_h1 ~env ~name:"whitespace_in_header_name" ~deadline_sec:2.0
    ~input ~expected_status:400 ()

(* 15. NUL in request target. *)
let probe_nul_in_target ~env =
  let input =
    "GET /foo\x00bar HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  run_single_h1 ~env ~name:"nul_in_target" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 16. Tab in request target. *)
let probe_tab_in_target ~env =
  let input =
    "GET /foo\tbar HTTP/1.1\r\nHost: example.test\r\n\r\n"
  in
  run_single_h1 ~env ~name:"tab_in_target" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 17. Absolute-form request target with a Host header that conflicts. *)
let probe_absolute_form_host_conflict ~env =
  let input =
    "GET http://example.test/conflict HTTP/1.1\r\n"
    ^ "Host: shadow.test\r\n\r\n"
  in
  run_single_h1 ~env ~name:"absolute_form_host_conflict" ~deadline_sec:2.0
    ~input ~expected_status:400 ()

(* 18. Missing Host on HTTP/1.1. *)
let probe_missing_host ~env =
  let input = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n" in
  run_single_h1 ~env ~name:"missing_host" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 18a. Multiple Host headers — some front-ends split or rewrite Host. *)
let probe_multiple_host ~env =
  let input =
    "GET / HTTP/1.1\r\nHost: example.test\r\nHost: shadow.test\r\n\r\n"
  in
  run_single_h1 ~env ~name:"multiple_host" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 18b. Content-Length with leading/trailing whitespace. Whitespace must be
        ignored; the request should be processed normally. *)
let probe_cl_whitespace_value ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Content-Length:   5   \r\n\r\nhello"
  in
  run_single_h1 ~env ~name:"cl_whitespace_value" ~deadline_sec:2.0 ~input
    ~expected_status:200 ()

(* 18c. Content-Length with a plus sign. Must be rejected. *)
let probe_cl_plus_sign ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Content-Length: +5\r\n\r\nhello"
  in
  run_single_h1 ~env ~name:"cl_plus_sign" ~deadline_sec:2.0 ~input
    ~expected_status:400 ()

(* 18d. Transfer-Encoding with surrounding whitespace. " chunked " must be
        treated as chunked and the request processed. *)
let probe_te_chunked_whitespace ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Transfer-Encoding:  chunked \r\n\r\n"
    ^ "5\r\nhello\r\n0\r\n\r\n"
  in
  run_single_h1 ~env ~name:"te_chunked_whitespace" ~deadline_sec:2.0 ~input
    ~expected_status:200 ()

(* 19. Bare CR request line: line terminator is CR only, no LF. The parser
       should not advance past it as a valid request. *)
let probe_bare_cr_request_line ~env =
  let input = "GET / HTTP/1.1\r" in
  run_raw_h1 ~env ~name:"bare_cr_request_line" ~deadline_sec:2.0 ~input
    ~interpret:(fun raw ->
      let codes = status_codes raw in
      if List.length codes > 0 then Pass (response_summary raw)
      else Hang)
    ()

(* 20. Connection: close with a Content-Length body that contains a second
       request. Because the connection must close after the response, the
       smuggled bytes should not be interpreted as a new request. *)
let probe_connection_close_smuggled ~env =
  let input =
    "POST /echo HTTP/1.1\r\nHost: example.test\r\n"
    ^ "Connection: close\r\nContent-Length: 5\r\n\r\nhello" ^ smuggled_get
  in
  run_raw_h1 ~env ~name:"connection_close_smuggled" ~deadline_sec:2.0 ~input
    ~expected_count:1
    ~interpret:(fun raw ->
      let codes = status_codes raw in
      let got = List.length codes in
      if got > 1 then
        Fail
          (Printf.sprintf "connection-close ignored: %s" (response_summary raw))
      else if got = 1 then Pass (response_summary raw)
      else Fail "no response")
    ()

(* ---------------------------------------------------------------------------
   Orchestration
   --------------------------------------------------------------------------- *)

let probes ~env =
  [
    ("pipeline_get_get", probe_pipeline_get_get ~env);
    ("cl_te_reject", probe_cl_te_reject ~env);
    ("te_cl_reject", probe_te_cl_reject ~env);
    ("duplicate_cl_different", probe_duplicate_cl_different ~env);
    ("duplicate_cl_same", probe_duplicate_cl_same ~env);
    ("cl_only_pipeline", probe_cl_only_pipeline ~env);
    ("cl_too_short", probe_cl_too_short ~env);
    ("cl_too_long", probe_cl_too_long ~env);
    ("chunked_pipeline", probe_chunked_pipeline ~env);
    ("te_chunked_not_last", probe_te_chunked_not_last ~env);
    ("obs_fold", probe_obs_fold ~env);
    ("bare_cr_header", probe_bare_cr_header ~env);
    ("nul_header_value", probe_nul_header_value ~env);
    ("tab_in_header_name", probe_tab_in_header_name ~env);
    ("whitespace_in_header_name", probe_whitespace_in_header_name ~env);
    ("nul_in_target", probe_nul_in_target ~env);
    ("tab_in_target", probe_tab_in_target ~env);
    ("absolute_form_host_conflict", probe_absolute_form_host_conflict ~env);
    ("missing_host", probe_missing_host ~env);
    ("multiple_host", probe_multiple_host ~env);
    ("cl_whitespace_value", probe_cl_whitespace_value ~env);
    ("cl_plus_sign", probe_cl_plus_sign ~env);
    ("te_chunked_whitespace", probe_te_chunked_whitespace ~env);
    ("bare_cr_request_line", probe_bare_cr_request_line ~env);
    ("connection_close_smuggled", probe_connection_close_smuggled ~env);
  ]

let () =
  let results = Eio_main.run (fun env -> probes ~env) in
  List.iter
    (fun (name, outcome) ->
      let status, detail = string_of_outcome outcome in
      if String.equal detail "" then Printf.printf "probe %s %s\n%!" name status
      else Printf.printf "probe %s %s %s\n%!" name status detail)
    results;
  Printf.printf "h1_smuggle done probes=%d\n%!" (List.length results)
