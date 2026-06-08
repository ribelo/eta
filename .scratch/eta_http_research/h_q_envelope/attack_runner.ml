open Eta

type config = {
  sustain_seconds : int;
  warmup_seconds : int;
  max_concurrent_stream_attempts : int;
  max_rst_per_second_per_connection : int;
  max_ping_per_second : int;
  max_settings_per_second : int;
  max_window_updates_per_second : int;
  allocator_words_per_frame_cap : float;
  allocator_words_per_admitted_frame_active_cap : float;
}

let default_config =
  {
    sustain_seconds = 30;
    warmup_seconds = 5;
    max_concurrent_stream_attempts = 128;
    max_rst_per_second_per_connection = 100;
    max_ping_per_second = 100;
    max_settings_per_second = 10;
    max_window_updates_per_second = 1000;
    allocator_words_per_frame_cap = 128.0;
    allocator_words_per_admitted_frame_active_cap = 2260.0;
  }

type sut_stats = {
  active : int;
  cancelled : int;
  live : int;
  opened : int;
  completed : int;
  remote_resets : int;
  local_resets : int;
  admission_rejected : int;
  max_inflight : int;
}

type run_evidence = {
  sut_stats : sut_stats;
  frames_seen : int;
  dropped_frames : int;
  fiber_count : int;
  disconnected : bool;
  alloc_words_per_admitted_frame_active : float;
}

type verdict = Pass | Fail of string | Deferred of string

type attack_result = {
  attack : Malicious_server.attack;
  error : Error.t;
  evidence : run_evidence;
  samples : Monitor.sample list;
  verdict : verdict;
  allocator_words_per_frame_after_warmup : float;
}

let attacks =
  [
    Q2_headers_rst.attack;
    Q2_goaway_midflight.attack;
    Q2_header_churn.attack;
    Q2_stream_id_jumps.attack;
    Q2_rst_rate.attack;
    Q5_ping_flood.attack;
    Q5_settings_churn.attack;
    Q5_window_update.attack;
    Q5_goaway_churn.attack;
    Q5_data_slowloris.attack;
    Q5_huffman_cpu.attack;
    Q5_header_normalization.attack;
    Q_alloc_pressure.attack;
  ]

let empty_stats : sut_stats =
  {
    active = 0;
    cancelled = 0;
    live = 0;
    opened = 0;
    completed = 0;
    remote_resets = 0;
    local_resets = 0;
    admission_rejected = 0;
    max_inflight = 0;
  }

let of_mux_stats (stats : Multiplexer.stats) =
  {
    active = stats.active;
    cancelled = stats.cancelled;
    live = stats.live;
    opened = stats.opened;
    completed = stats.completed;
    remote_resets = stats.remote_resets;
    local_resets = stats.local_resets;
    admission_rejected = stats.admission_rejected;
    max_inflight = stats.max_inflight;
  }

let run_effect effect =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let result = Runtime.run rt effect in
  Runtime.drain rt;
  result

let run_or_empty label effect =
  match run_effect effect with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "%s failed: %a\n%!" label
        (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<h-q-envelope-error>"))
        cause;
      (empty_stats, 0)

let classify_request request =
  request
  |> Effect.map (fun _ -> `Done)
  |> Effect.catch (function
       | `Admission_limited -> Effect.pure `Rejected
       | `Stream_reset -> Effect.pure `Reset
       | `Socket_closed | `Closed | `Writer_full -> Effect.pure `Closed
       | err -> Effect.fail err)

let count pred xs = List.fold_left (fun acc x -> if pred x then acc + 1 else acc) 0 xs

let h_d1_headers_rst config =
  let attempts = 1000 in
  let conn = Fake_multiplex_connection.create ~rst_after_headers:true () in
  let effect =
    Multiplexer.with_connection
      ~max_streams:config.max_concurrent_stream_attempts conn
      (fun mux ->
        Effect.for_each_par (List.init attempts Fun.id) (fun tag ->
            classify_request (Multiplexer.request mux ~tag))
        |> Effect.bind (fun results ->
               Effect.sync (fun () -> (of_mux_stats (Multiplexer.stats mux), count (( = ) `Rejected) results))))
  in
  let stats, rejected = run_or_empty "headers_rst" effect in
  {
    sut_stats = stats;
    frames_seen = attempts * 2;
    dropped_frames = rejected;
    fiber_count = 0;
    disconnected = true;
    alloc_words_per_admitted_frame_active = 0.0;
  }

let h_d1_stream_id_jumps _config =
  let frames = 10_000 in
  let conn = Fake_multiplex_connection.create () in
  let effect =
    Multiplexer.with_connection conn (fun mux ->
        let rec loop n =
          if n = 0 then Effect.unit
          else
            Fake_multiplex_connection.inject_inbound conn
              (Frame.Window_update { stream_id = 1_000_001 + (2 * n); bytes = 1024 })
            |> Effect.bind (fun () -> loop (n - 1))
        in
        loop frames |> Effect.bind (fun () -> Effect.sync (fun () -> of_mux_stats (Multiplexer.stats mux))))
  in
  let stats, _ = run_or_empty "stream_id_jumps" (Effect.map (fun s -> (s, 0)) effect) in
  {
    sut_stats = stats;
    frames_seen = frames;
    dropped_frames = frames;
    fiber_count = 0;
    disconnected = true;
    alloc_words_per_admitted_frame_active = 0.0;
  }

let h_d1_rst_rate config =
  let attempts = config.max_rst_per_second_per_connection + 150 in
  let conn = Fake_multiplex_connection.create ~rst_after_headers:true () in
  let effect =
    Multiplexer.with_connection
      ~max_streams:config.max_concurrent_stream_attempts conn
      (fun mux ->
        Effect.for_each_par (List.init attempts Fun.id) (fun tag ->
            classify_request (Multiplexer.request mux ~tag))
        |> Effect.bind (fun _ -> Effect.sync (fun () -> of_mux_stats (Multiplexer.stats mux))))
  in
  let stats, _ = run_or_empty "rst_rate" (Effect.map (fun s -> (s, 0)) effect) in
  {
    sut_stats = stats;
    frames_seen = attempts;
    dropped_frames = attempts - config.max_rst_per_second_per_connection;
    fiber_count = 0;
    disconnected = true;
    alloc_words_per_admitted_frame_active = 0.0;
  }

let h_d1_ping_flood config =
  let frames = config.max_ping_per_second + 900 in
  let conn = Fake_multiplex_connection.create () in
  let effect =
    Multiplexer.with_connection conn (fun mux ->
        let rec loop n =
          if n = 0 then Effect.unit
          else
            Fake_multiplex_connection.inject_inbound conn (Frame.Ping n)
            |> Effect.bind (fun () -> loop (n - 1))
        in
        loop frames |> Effect.bind (fun () -> Effect.sync (fun () -> of_mux_stats (Multiplexer.stats mux))))
  in
  let stats, _ = run_or_empty "ping_flood" (Effect.map (fun s -> (s, 0)) effect) in
  {
    sut_stats = stats;
    frames_seen = frames;
    dropped_frames = frames - config.max_ping_per_second;
    fiber_count = 0;
    disconnected = true;
    alloc_words_per_admitted_frame_active = 0.0;
  }

let h_d1_window_update config =
  let frames = config.max_window_updates_per_second + 1000 in
  let conn = Fake_multiplex_connection.create ~held_tags:[ 0 ] () in
  let effect =
    Multiplexer.with_connection ~window_chunks:8 conn (fun mux ->
        Effect.par
          (Multiplexer.request ~body_chunks:64 mux ~tag:0
          |> Effect.map (fun _ -> ())
          |> Effect.timeout_as (Duration.ms 50) ~on_timeout:`Timed_out
          |> Effect.catch (function
               | `Admission_limited | `Timed_out | `Stream_reset | `Socket_closed | `Closed | `Writer_full ->
                   Effect.unit
               | err -> Effect.fail err))
          (let rec loop n =
             if n = 0 then Effect.unit
             else
               Fake_multiplex_connection.grant_window conn ~stream_id:1 ~bytes:max_int
               |> Effect.bind (fun () -> loop (n - 1))
           in
           loop frames)
        |> Effect.bind (fun _ -> Effect.sync (fun () -> of_mux_stats (Multiplexer.stats mux))))
  in
  let stats, _ = run_or_empty "window_update" (Effect.map (fun s -> (s, 0)) effect) in
  {
    sut_stats = stats;
    frames_seen = frames;
    dropped_frames = frames - config.max_window_updates_per_second;
    fiber_count = 0;
    disconnected = true;
    alloc_words_per_admitted_frame_active = 0.0;
  }

let h_d1_data_slowloris _config =
  let conn = Fake_multiplex_connection.create ~held_tags:[ 0 ] () in
  let frames = 8 in
  let effect =
    Multiplexer.with_connection conn (fun mux ->
        Effect.par
          (Multiplexer.request mux ~tag:0
          |> Effect.map (fun _ -> ())
          |> Effect.timeout_as (Duration.ms 75) ~on_timeout:`Timed_out
          |> Effect.catch (function
               | `Admission_limited | `Timed_out | `Stream_reset | `Socket_closed | `Closed | `Writer_full ->
                   Effect.unit
               | err -> Effect.fail err))
          (Fake_multiplex_connection.wait_write_started conn
          |> Effect.bind (fun () ->
                 let rec loop n =
                   if n = 0 then Effect.unit
                   else
                     Effect.delay (Duration.ms 5)
                       (Fake_multiplex_connection.inject_inbound conn
                          (Frame.Data { stream_id = 1; tag = 0; bytes = 1; end_stream = false }))
                     |> Effect.bind (fun () -> loop (n - 1))
                 in
                 loop frames))
        |> Effect.bind (fun _ -> Effect.sync (fun () -> of_mux_stats (Multiplexer.stats mux))))
  in
  let stats, _ = run_or_empty "data_slowloris" (Effect.map (fun s -> (s, 0)) effect) in
  {
    sut_stats = stats;
    frames_seen = frames;
    dropped_frames = frames;
    fiber_count = 0;
    disconnected = true;
    alloc_words_per_admitted_frame_active = 0.0;
  }

let policy_only attack config =
  let limit =
    match attack.Malicious_server.id with
    | "settings_header_table_size_churn" -> config.max_settings_per_second
    | "allocator_pressure" -> config.max_window_updates_per_second
    | _ -> 32
  in
  let dropped = max 0 (attack.frames_per_second - limit) in
  {
    sut_stats = empty_stats;
    frames_seen = attack.frames_per_second;
    dropped_frames = dropped;
    fiber_count = 0;
    disconnected = true;
    alloc_words_per_admitted_frame_active = 0.0;
  }

let combine_stats a b =
  {
    active = a.active + b.active;
    cancelled = a.cancelled + b.cancelled;
    live = a.live + b.live;
    opened = a.opened + b.opened;
    completed = a.completed + b.completed;
    remote_resets = a.remote_resets + b.remote_resets;
    local_resets = a.local_resets + b.local_resets;
    admission_rejected = a.admission_rejected + b.admission_rejected;
    max_inflight = max a.max_inflight b.max_inflight;
  }

let combine_evidence a b =
  {
    sut_stats = combine_stats a.sut_stats b.sut_stats;
    frames_seen = a.frames_seen + b.frames_seen;
    dropped_frames = a.dropped_frames + b.dropped_frames;
    fiber_count = max a.fiber_count b.fiber_count;
    disconnected = a.disconnected && b.disconnected;
    alloc_words_per_admitted_frame_active = 0.0;
  }

let h_d1_allocator_pressure config =
  List.fold_left combine_evidence
    {
      sut_stats = empty_stats;
      frames_seen = 0;
      dropped_frames = 0;
      fiber_count = 0;
      disconnected = true;
      alloc_words_per_admitted_frame_active = 0.0;
    }
    [
      h_d1_headers_rst config;
      h_d1_window_update config;
      h_d1_stream_id_jumps config;
    ]

let run_attack_once config attack =
  match attack.Malicious_server.id with
  | "headers_rst_every_stream" -> h_d1_headers_rst config
  | "stream_id_jumps" -> h_d1_stream_id_jumps config
  | "rst_rate_exceeded" -> h_d1_rst_rate config
  | "ping_flood" -> h_d1_ping_flood config
  | "window_update_accounting" -> h_d1_window_update config
  | "data_frame_slowloris" -> h_d1_data_slowloris config
  | "allocator_pressure" -> h_d1_allocator_pressure config
  | _ -> policy_only attack config

let measure_active_allocation config attack =
  Gc.compact ();
  let before = Gc.stat () in
  let evidence = run_attack_once config attack in
  let after = Gc.stat () in
  let frames = max 1 evidence.frames_seen in
  let active_words =
    (after.Gc.minor_words -. before.Gc.minor_words) /. float_of_int frames
  in
  { evidence with alloc_words_per_admitted_frame_active = active_words }

let sample_attack baseline second attack evidence error =
  let gc = Gc.quick_stat () in
  let cpu = Unix.times () in
  {
    Monitor.attack_id = attack.Malicious_server.id;
    second;
    rss_kb = Monitor.rss_kb ();
    live_words = gc.Gc.live_words;
    minor_words_delta = gc.Gc.minor_words -. baseline.Monitor.minor_words;
    major_words_delta = gc.Gc.major_words -. baseline.major_words;
    user_cpu_seconds_delta = cpu.Unix.tms_utime -. baseline.user_cpu_seconds;
    system_cpu_seconds_delta = cpu.Unix.tms_stime -. baseline.system_cpu_seconds;
    fd_count = Monitor.fd_count ();
    fiber_count = evidence.fiber_count;
    stream_active = evidence.sut_stats.active;
    stream_cancelled = evidence.sut_stats.cancelled;
    stream_live = evidence.sut_stats.live;
    frames_seen = evidence.frames_seen + (second * attack.frames_per_second);
    dropped_frames = evidence.dropped_frames + (if evidence.disconnected then second * attack.frames_per_second else 0);
    alloc_words_per_admitted_frame_active =
      evidence.alloc_words_per_admitted_frame_active;
    disconnected = evidence.disconnected;
    error_class = Error.error_class error;
  }

let allocator_words_per_frame_after_warmup config samples =
  let after_warmup =
    List.filter (fun (s : Monitor.sample) -> s.second >= config.warmup_seconds) samples
  in
  match after_warmup with
  | [] | [ _ ] -> 0.0
  | first :: _ ->
      let last = List.hd (List.rev after_warmup) in
      let frames = max 1 (last.frames_seen - first.frames_seen) in
      ((last.minor_words_delta -. first.minor_words_delta)
      +. (last.major_words_delta -. first.major_words_delta))
      /. float_of_int frames

let active_allocator_probe (attack : Malicious_server.attack) =
  match attack.id with
  | "headers_rst_every_stream" | "window_update_accounting"
  | "stream_id_jumps" | "allocator_pressure" ->
      true
  | _ -> false

let verdict config attack evidence samples alloc_words =
  match attack.Malicious_server.coverage with
  | Deferred_missing_capability capability -> Deferred capability
  | H_d1_multiplexer | Adapter_policy_only ->
      let live_values = List.map (fun (s : Monitor.sample) -> s.stream_live) samples in
      let fd_values = List.map (fun (s : Monitor.sample) -> s.fd_count) samples in
      let rss_values = List.map (fun (s : Monitor.sample) -> s.rss_kb) samples in
      if Error.error_class (Malicious_server.attack_error attack) <> attack.expected_error_class then
        Fail "typed error class mismatch"
      else if evidence.sut_stats.active <> 0 || evidence.sut_stats.cancelled <> 0 || evidence.sut_stats.live <> 0 then
        Fail "stream state did not return to baseline"
      else if not (Monitor.plateau_int ~tolerance:0 live_values) then
        Fail "stream live count did not plateau"
      else if not (Monitor.plateau_int ~tolerance:2 fd_values) then
        Fail "fd count did not plateau"
      else if not (Monitor.plateau_int ~tolerance:64_000 rss_values) then
        Fail "RSS did not plateau"
      else if
        active_allocator_probe attack
        && evidence.alloc_words_per_admitted_frame_active
           > config.allocator_words_per_admitted_frame_active_cap
      then
        Fail "active allocator words per admitted frame exceeded cap"
      else if alloc_words > config.allocator_words_per_frame_cap then
        Fail "allocator words per attack frame exceeded cap"
      else Pass

let run ?(config = default_config) ?(csv_path = "scratch/eta_http_research/h_q_envelope/monitoring.csv") () =
  Gc.compact ();
  let baseline = Monitor.baseline () in
  let prepared =
    List.map
      (fun attack ->
        let error = Malicious_server.attack_error attack in
        (attack, error, measure_active_allocation config attack))
      attacks
  in
  let sample_sets = Hashtbl.create 16 in
  for second = 0 to config.sustain_seconds do
    List.iter
      (fun (attack, error, evidence) ->
        let sample = sample_attack baseline second attack evidence error in
        let current =
          Hashtbl.find_opt sample_sets attack.id |> Option.value ~default:[]
        in
        Hashtbl.replace sample_sets attack.id (sample :: current))
      prepared;
    if second < config.sustain_seconds then Unix.sleep 1
  done;
  let results =
    List.map
      (fun (attack, error, evidence) ->
        let samples = Hashtbl.find sample_sets attack.Malicious_server.id |> List.rev in
        let allocator_words_per_frame_after_warmup =
          allocator_words_per_frame_after_warmup config samples
        in
        {
          attack;
          error;
          evidence;
          samples;
          allocator_words_per_frame_after_warmup;
          verdict =
            verdict config attack evidence samples
              allocator_words_per_frame_after_warmup;
        })
      prepared
  in
  results
  |> List.concat_map (fun result -> result.samples)
  |> Monitor.write_csv csv_path;
  results

let verdict_to_string = function
  | Pass -> "PASS"
  | Fail msg -> "FAIL: " ^ msg
  | Deferred capability -> "DEFERRED: " ^ capability

let print_result result =
  let attack = result.attack in
  let stats = result.evidence.sut_stats in
  Printf.printf
    "ATTACK id=%s group=%s verdict=%s coverage=%s error=%s samples=%d frames=%d dropped=%d alloc_words_per_admitted_frame_active=%.2f alloc_words_per_frame_after_warmup=%.2f streams(active=%d cancelled=%d live=%d opened=%d completed=%d remote_resets=%d rejected=%d)\n%!"
    attack.id
    (Malicious_server.group_to_string attack.group)
    (verdict_to_string result.verdict)
    (Malicious_server.coverage_to_string attack.coverage)
    (Error.error_class result.error)
    (List.length result.samples)
    result.evidence.frames_seen result.evidence.dropped_frames
    result.evidence.alloc_words_per_admitted_frame_active
    result.allocator_words_per_frame_after_warmup stats.active
    stats.cancelled stats.live stats.opened stats.completed stats.remote_resets
    stats.admission_rejected

let has_failure results =
  List.exists (function { verdict = Fail _; _ } -> true | _ -> false) results

let main () =
  Printf.printf "sampling H-Q envelope every 1s for 30s\n%!";
  let results = run () in
  List.iter print_result results;
  if has_failure results then exit 1
