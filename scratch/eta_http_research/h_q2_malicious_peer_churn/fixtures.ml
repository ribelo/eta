let fail msg = failwith msg

let check label cond =
  if cond then Printf.printf "PASS %s\n%!" label else fail ("FAIL " ^ label)

let first_last samples =
  let ordered = List.rev samples in
  match ordered with
  | [] -> fail "no samples"
  | first :: _ -> (first, List.hd (List.rev ordered))

let print_state state =
  let first, last = first_last state.Churn.samples in
  let error_class =
    match state.error with
    | None -> "none"
    | Some err -> Error.error_class err
  in
  Printf.printf
    "ATTACK %s samples=%d first(live=%d rss=%d fd=%d fibers=%d) last(live=%d rss=%d fd=%d fibers=%d) error=%s\n%!"
    (Churn.attack_name state.attack) (List.length state.samples) first.live_words
    first.rss_kb first.fd_count first.fiber_count last.live_words last.rss_kb
    last.fd_count last.fiber_count error_class

let expected_error_class = function
  | Churn.Headers_rst -> "stream_admission_rejected"
  | Goaway_midflight -> "connection_closed"
  | Ping_flood -> "connection_closed"
  | Header_churn -> "response_header_timeout"
  | Stream_id_jumps -> "stream_admission_rejected"
  | Rst_rate -> "rst_rate_exceeded"

let check_state state =
  let name = Churn.attack_name state.Churn.attack in
  print_state state;
  check (name ^ " collected 30 samples") (List.length state.samples = 30);
  check (name ^ " circuit breaker triggered") state.circuit_breaker;
  check (name ^ " returned to baseline")
    (state.active_streams = 0 && state.active_fibers = 0);
  check (name ^ " plateaued") (Churn.verify_state state);
  check (name ^ " mapped to typed error")
    (match state.error with
    | Some err -> Error.error_class err = expected_error_class state.attack
    | None -> false)

let () =
  Printf.printf "sampling malicious peer churn every 1s for 30s\n%!";
  let states = Churn.run ~seconds:30 () in
  List.iter check_state states;
  Printf.printf "h_q2_malicious_peer_churn fixtures passed\n%!"
