open Eta_http_fuzz_support

let header_gen =
  Crowbar.map
    [ bounded_string 32; bounded_string 64 ]
    (fun name value -> (name, value))

let chunk_gen = bounded_string 192

type stream_op =
  | Open of int
  | Remote_reset of int
  | Complete of int
  | Release of int
  | Close

let stream_op_gen =
  Crowbar.choose
    [
      Crowbar.map [ Crowbar.range 256 ] (fun tag -> Open tag);
      Crowbar.map [ Crowbar.range 64 ] (fun index -> Remote_reset index);
      Crowbar.map [ Crowbar.range 64 ] (fun index -> Complete index);
      Crowbar.map [ Crowbar.range 64 ] (fun index -> Release index);
      Crowbar.const Close;
    ]

let stream_ops_gen = bounded_list 16 stream_op_gen

let pick_stream streams index =
  match !streams with
  | [] -> None
  | streams ->
      let index = index mod List.length streams in
      Some (List.nth streams index)

let check_stream_stats (stats : Eta_http.H2.Stream_state.stats) =
  check_nonnegative "active" stats.active;
  check_nonnegative "cancelled" stats.cancelled;
  check_nonnegative "inflight" stats.inflight;
  check_nonnegative "live" stats.live;
  check_nonnegative "opened" stats.opened;
  check_nonnegative "completed" stats.completed;
  check_nonnegative "local_resets" stats.local_resets;
  check_nonnegative "remote_resets" stats.remote_resets;
  check_nonnegative "admission_rejected" stats.admission_rejected;
  check_nonnegative "max_inflight" stats.max_inflight;
  Crowbar.check_eq ~pp:Crowbar.pp_int
    (stats.active + stats.cancelled)
    stats.inflight;
  if stats.inflight > stats.max_concurrent then
    Crowbar.failf "inflight %d exceeded max_concurrent %d" stats.inflight
      stats.max_concurrent;
  if stats.live > stats.opened then
    Crowbar.failf "live %d exceeded opened %d" stats.live stats.opened;
  if stats.completed > stats.opened then
    Crowbar.failf "completed %d exceeded opened %d" stats.completed stats.opened

let () =
  Crowbar.add_test ~name:"h2 security arbitrary chunks do not escape"
    [ chunk_gen ] (fun chunk ->
      let security = Eta_http.H2.Security.create () in
      let len = String.length chunk in
      let bytes = Bigstringaf.of_string ~off:0 ~len chunk in
      ignore
        (Eta_http.H2.Security.observe security bytes ~off:0 ~len
          : Eta_http.Error.kind option));

  Crowbar.add_test ~name:"h2 header validation arbitrary pair does not escape"
    [ header_gen ] (fun header ->
      ignore
        (Eta_http.H2.Security.validate_headers [ header ]
          : Eta_http.Error.kind option));

  Crowbar.add_test ~name:"h2 stream state operation sequence invariants"
    [ stream_ops_gen ] (fun ops ->
      let state = Eta_http.H2.Stream_state.create ~max_concurrent:8 in
      let streams = ref [] in
      List.iter
        (fun op ->
          (match op with
          | Open tag -> (
              match Eta_http.H2.Stream_state.open_stream state ~tag with
              | Ok stream -> streams := stream :: !streams
              | Error () -> ())
          | Remote_reset index -> (
              match pick_stream streams index with
              | None -> ()
              | Some stream ->
                  Eta_http.H2.Stream_state.mark_remote_reset state
                    (Eta_http.H2.Stream_state.id stream))
          | Complete index -> (
              match pick_stream streams index with
              | None -> ()
              | Some stream -> Eta_http.H2.Stream_state.mark_complete state stream)
          | Release index -> (
              match pick_stream streams index with
              | None -> ()
              | Some stream ->
                  ignore
                    (Eta_http.H2.Stream_state.release state stream
                      : Eta_http.H2.Stream_state.release))
          | Close -> Eta_http.H2.Stream_state.close state);
          check_stream_stats (Eta_http.H2.Stream_state.stats state))
        ops)
