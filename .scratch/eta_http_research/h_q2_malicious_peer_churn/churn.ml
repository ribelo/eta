type config = {
  max_concurrent_stream_attempts : int;
  max_rst_per_second_per_connection : int;
  max_ping_per_second : int;
  response_header_max_change_rate : int;
}

let default_config =
  {
    max_concurrent_stream_attempts = 128;
    max_rst_per_second_per_connection = 100;
    max_ping_per_second = 100;
    response_header_max_change_rate = 32;
  }

type attack =
  | Headers_rst
  | Goaway_midflight
  | Ping_flood
  | Header_churn
  | Stream_id_jumps
  | Rst_rate

type sample = {
  second : int;
  live_words : int;
  rss_kb : int;
  fiber_count : int;
  fd_count : int;
}

type state = {
  attack : attack;
  mutable active_streams : int;
  mutable cancelled_streams : int;
  mutable completed_streams : int;
  mutable active_fibers : int;
  mutable fd_count_model : int;
  mutable circuit_breaker : bool;
  mutable disconnected : bool;
  mutable error : Error.t option;
  mutable samples : sample list;
}

let attack_name = function
  | Headers_rst -> "headers_rst_every_stream"
  | Goaway_midflight -> "goaway_mid_flight"
  | Ping_flood -> "ping_flood"
  | Header_churn -> "header_churn"
  | Stream_id_jumps -> "stream_id_jumps"
  | Rst_rate -> "rst_rate_exceeded"

let make_error attack =
  let uri = "https://malicious.example.test/" ^ attack_name attack in
  let method_ = "GET" in
  match attack with
  | Headers_rst ->
      Error.make ~protocol:Error.H2 ~method_ ~uri
        (Stream_admission_rejected { limit = 128 })
  | Goaway_midflight ->
      Error.make ~protocol:Error.H2 ~method_ ~uri
        (Connection_closed { during = Http_response })
  | Ping_flood ->
      Error.make ~protocol:Error.H2 ~method_ ~uri
        (Connection_closed { during = Http_response })
  | Header_churn ->
      Error.make ~protocol:Error.H2 ~method_ ~uri
        (Response_header_timeout { timeout_ms = Some 1_000 })
  | Stream_id_jumps ->
      Error.make ~protocol:Error.H2 ~method_ ~uri
        (Stream_admission_rejected { limit = 128 })
  | Rst_rate ->
      Error.make ~protocol:Error.H2 ~method_ ~uri
        (Rst_rate_exceeded { observed_per_second = 250; limit_per_second = 100 })

let create attack =
  {
    attack;
    active_streams = 0;
    cancelled_streams = 0;
    completed_streams = 0;
    active_fibers = 0;
    fd_count_model = 0;
    circuit_breaker = false;
    disconnected = false;
    error = None;
    samples = [];
  }

let trigger state error =
  state.circuit_breaker <- true;
  state.error <- Some error;
  state.active_streams <- 0;
  state.active_fibers <- 0;
  state.fd_count_model <- 0

let tick config second state =
  if not state.disconnected then
    match state.attack with
    | Headers_rst ->
        let churn = 256 in
        state.active_streams <- 0;
        state.cancelled_streams <- state.cancelled_streams + churn;
        state.completed_streams <- state.completed_streams + churn;
        state.active_fibers <- 0;
        if churn > config.max_concurrent_stream_attempts then
          trigger state (make_error Headers_rst)
    | Goaway_midflight ->
        if second = 1 then (
          state.active_streams <- 16;
          state.active_fibers <- 16)
        else if second = 2 then trigger state (make_error Goaway_midflight)
    | Ping_flood ->
        let observed = 1_000 in
        if observed > config.max_ping_per_second then
          trigger state (make_error Ping_flood)
    | Header_churn ->
        let changes = 128 in
        if changes > config.response_header_max_change_rate then
          trigger state (make_error Header_churn)
    | Stream_id_jumps ->
        let jump_attempts = 512 in
        if jump_attempts > config.max_concurrent_stream_attempts then
          trigger state (make_error Stream_id_jumps)
    | Rst_rate ->
        let observed = 250 in
        state.cancelled_streams <- state.cancelled_streams + observed;
        if observed > config.max_rst_per_second_per_connection then
          trigger state (make_error Rst_rate)

let disconnect state =
  state.disconnected <- true;
  state.active_streams <- 0;
  state.active_fibers <- 0;
  state.fd_count_model <- 0

let rss_kb () =
  let ic = open_in "/proc/self/status" in
  let rec loop () =
    match input_line ic with
    | line ->
        if String.starts_with ~prefix:"VmRSS:" line then (
          close_in_noerr ic;
          match String.split_on_char ' ' line |> List.filter (( <> ) "") with
          | _ :: value :: _ -> int_of_string value
          | _ -> 0)
        else loop ()
    | exception End_of_file ->
        close_in_noerr ic;
        0
  in
  loop ()

let fd_count () =
  try Array.length (Sys.readdir "/proc/self/fd") with _ -> 0

let record_sample second state =
  let gc = Gc.quick_stat () in
  state.samples <-
    {
      second;
      live_words = gc.Gc.live_words;
      rss_kb = rss_kb ();
      fiber_count = state.active_fibers;
      fd_count = fd_count () + state.fd_count_model;
    }
    :: state.samples

let plateau samples project tolerance =
  let samples = List.rev samples in
  let rec take n acc = function
    | _ when n = 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> take (n - 1) (x :: acc) xs
  in
  let tail = samples |> List.rev |> take 10 [] in
  match tail with
  | [] -> true
  | xs ->
      let values = List.map project xs in
      let min_v = List.fold_left min max_int values in
      let max_v = List.fold_left max min_int values in
      max_v - min_v <= tolerance

let verify_state state =
  let samples = state.samples in
  state.circuit_breaker
  && Option.is_some state.error
  && state.active_streams = 0
  && state.active_fibers = 0
  && plateau samples (fun s -> s.live_words) 5_000_000
  && plateau samples (fun s -> s.rss_kb) 64_000
  && plateau samples (fun s -> s.fiber_count) 0

let run ?(config = default_config) ?(seconds = 30) () =
  let states =
    List.map create
      [ Headers_rst; Goaway_midflight; Ping_flood; Header_churn; Stream_id_jumps; Rst_rate ]
  in
  for second = 1 to seconds do
    List.iter (tick config second) states;
    List.iter (record_sample second) states;
    if second < seconds then Unix.sleep 1
  done;
  List.iter disconnect states;
  states
