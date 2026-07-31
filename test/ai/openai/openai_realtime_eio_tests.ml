module E = Eta.Effect
module R = Eta_ai_openai.Audio.Realtime
module T = Eta_ai_openai_realtime_eio

type read_action =
  | Return of string
  | Await_return : unit Eio.Promise.t * string -> read_action
  | Await_dynamic : string Eio.Promise.t -> read_action
  | Await : unit Eio.Promise.t -> read_action

type scripted_flow = {
  reads : read_action Stdlib.Queue.t;
  mutable pending : string option;
  mutable writes : int;
  fail_write : int option;
  mutable closed : int;
  close_resolver : unit Eio.Promise.u;
  mutable active_writes : int;
  mutable max_active_writes : int;
  mutable written : string list;
}

module Scripted_flow = struct
  type t = scripted_flow
  let read_methods = []
  let rec next_chunk t =
    match t.pending with
    | Some chunk -> chunk
    | None ->
        (match Stdlib.Queue.take_opt t.reads with
         | Some (Return chunk) -> chunk
         | Some (Await_return (promise, chunk)) ->
             Eio.Promise.await promise;
             chunk
         | Some (Await_dynamic promise) -> Eio.Promise.await promise
         | Some (Await promise) -> Eio.Promise.await promise; raise End_of_file
         | None -> raise End_of_file)
  let single_read t dst =
    let chunk = next_chunk t in
    let len = min (String.length chunk) (Cstruct.length dst) in
    Cstruct.blit_from_string chunk 0 dst 0 len;
    if len = String.length chunk then t.pending <- None
    else t.pending <- Some (String.sub chunk len (String.length chunk - len));
    len
  let single_write t bufs =
    t.writes <- t.writes + 1;
    t.active_writes <- t.active_writes + 1;
    t.max_active_writes <- max t.max_active_writes t.active_writes;
    Fun.protect
      ~finally:(fun () -> t.active_writes <- t.active_writes - 1)
      (fun () ->
        Eio.Fiber.yield ();
        if t.fail_write = Some t.writes then failwith "scripted write failure";
        t.written <-
          (Cstruct.concat bufs |> Cstruct.to_string) :: t.written;
        Cstruct.lenv bufs)
  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
  let shutdown _ _ = ()
  let close t =
    t.closed <- t.closed + 1;
    if t.closed = 1 then Eio.Promise.resolve t.close_resolver ()
end

let switching_response key =
  "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: "
  ^ Eta_http_ws.Codec.accept_key ~sha1:Eta_http_tls_openssl.sha1 key ^ "\r\n\r\n"

let scripted_flow ?fail_write ?(frames = []) key =
  let closed, close_resolver = Eio.Promise.create () in
  let reads = Stdlib.Queue.create () in
  Stdlib.Queue.push (Return (switching_response key)) reads;
  List.iter (fun frame -> Stdlib.Queue.push (Return frame) reads) frames;
  Stdlib.Queue.push (Await closed) reads;
  let state = { reads; pending = None; writes = 0; fail_write; closed = 0;
                close_resolver;
                active_writes = 0; max_active_writes = 0; written = [] } in
  let flow : Eta_http_eio.Ws.Client.flow =
    Eio.Resource.T
      (state, Eio.Resource.handler
         (Eio.Resource.H (Eio.Resource.Close, Scripted_flow.close)
          :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Scripted_flow))))
  in
  state, flow

let gated_scripted_flow frame key =
  let release, resolver = Eio.Promise.create () in
  let closed, close_resolver = Eio.Promise.create () in
  let reads = Stdlib.Queue.create () in
  Stdlib.Queue.push (Return (switching_response key)) reads;
  Stdlib.Queue.push (Await_return (release, frame)) reads;
  Stdlib.Queue.push (Await closed) reads;
  let state =
    {
      reads;
      pending = None;
      writes = 0;
      fail_write = None;
      closed = 0;
      close_resolver;
      active_writes = 0;
      max_active_writes = 0;
      written = [];
    }
  in
  let flow : Eta_http_eio.Ws.Client.flow =
    Eio.Resource.T
      (state, Eio.Resource.handler
         (Eio.Resource.H (Eio.Resource.Close, Scripted_flow.close)
          :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Scripted_flow))))
  in
  state, flow, resolver

let dynamic_scripted_flow key =
  let chunk, resolver = Eio.Promise.create () in
  let closed, close_resolver = Eio.Promise.create () in
  let reads = Stdlib.Queue.create () in
  Stdlib.Queue.push (Return (switching_response key)) reads;
  Stdlib.Queue.push (Await_dynamic chunk) reads;
  Stdlib.Queue.push (Await closed) reads;
  let state =
    {
      reads; pending = None; writes = 0; fail_write = None; closed = 0;
      close_resolver;
      active_writes = 0; max_active_writes = 0; written = [];
    }
  in
  let flow : Eta_http_eio.Ws.Client.flow =
    Eio.Resource.T
      (state, Eio.Resource.handler
         (Eio.Resource.H (Eio.Resource.Close, Scripted_flow.close)
          :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Scripted_flow))))
  in
  state, flow, resolver

let with_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  f env sw rt

let expect_runtime_drained env rt label =
  match
    Eio.Time.with_timeout (Eio.Stdenv.clock env) 0.2 (fun () ->
        Eta.Runtime.drain rt;
        Ok ())
  with
  | Ok () -> ()
  | Error `Timeout -> Alcotest.fail (label ^ " left runtime work pending")

let with_traced_runtime f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env)
      ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  f env sw rt tracer

let frame opcode payload =
  Eta_http_ws.Codec.encode
    { Eta_http_ws.Codec.fin = true; opcode; payload = Bytes.of_string payload }
  |> Bytes.to_string

let key = "dGhlIHNhbXBsZSBub25jZQ=="
let api_key = Eta_ai.api_key "sk-test"
let url path = Eta_http.Core.Url.of_string ("http://api.openai.test" ^ path)
let pcm_audio () = match Eta_ai.audio_pcm16_base64 "AAE=" with Eta_ai.Audio value -> value | _ -> assert false

let conversation_session () =
  R.Conversation.session ~model:"gpt-realtime-2" ()
  |> Result.get_ok
let transcription_session () =
  R.Transcription.session ~input_audio_format:R.Transcription.Pcm16_24khz
    ~model:"gpt-live-transcribe" ()
  |> Result.get_ok
let translation_session () = R.Translation.session ~model:"gpt-realtime-translate" ~output_language:"es" ()

let connect_conversation sw flow =
  T.Conversation.connect_session_on_flow ~key ~sw ~flow ~api_key
    (url "/v1/realtime?model=gpt-realtime-2") (conversation_session ())
let connect_transcription sw flow =
  T.Transcription.connect_session_on_flow ~key ~sw ~flow ~api_key
    (url "/v1/realtime?model=gpt-live-transcribe") (transcription_session ())
let connect_translation sw flow =
  T.Translation.connect_session_on_flow ~key ~sw ~flow ~api_key
    (url "/v1/realtime/translations?model=gpt-realtime-translate") (translation_session ())

let run_ok rt label eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error _ -> Alcotest.fail (label ^ " failed")

let wait_writes state expected =
  let rec loop fuel =
    if state.writes >= expected && state.active_writes = 0 then ()
    else if fuel = 0 then Alcotest.fail "timed out waiting for write"
    else (Eio.Fiber.yield (); loop (fuel - 1))
  in loop 1000

let outgoing_event_types state =
  List.rev state.written
  |> List.filter_map (fun encoded ->
         match
           Eta_http_ws.Codec.decode ~masked:true (Bytes.of_string encoded)
         with
         | Ok ({ opcode = Eta_http_ws.Codec.Text; payload; _ }, _) ->
             Option.bind
               (Eta_ai.Json.parse (Bytes.to_string payload)
                |> Result.to_option)
               (Eta_ai.Json.string_member "type")
         | Ok _ | Error _ -> None)

let outgoing_json state =
  List.rev state.written
  |> List.filter_map (fun encoded ->
         match Eta_http_ws.Codec.decode ~masked:true (Bytes.of_string encoded) with
         | Ok ({ opcode = Eta_http_ws.Codec.Text; payload; _ }, _) ->
             Eta_ai.Json.parse (Bytes.to_string payload) |> Result.to_option
         | Ok _ | Error _ -> None)

let fork_run ~sw rt eff =
  let promise, resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolver (Eta.Runtime.run rt eff));
  promise

let expect_fail label predicate = function
  | Eta.Exit.Error (Eta.Cause.Fail error) when predicate error -> ()
  | Eta.Exit.Error _ -> Alcotest.fail (label ^ ": wrong failure")
  | Eta.Exit.Ok _ -> Alcotest.fail (label ^ ": unexpectedly succeeded")

let expect_transcription_fail label predicate = function
  | Eta.Exit.Error (Eta.Cause.Fail error) when predicate error -> ()
  | Eta.Exit.Error _ -> Alcotest.fail (label ^ ": wrong failure")
  | Eta.Exit.Ok _ -> Alcotest.fail (label ^ ": unexpectedly succeeded")

let expect_conversation_fail label predicate = function
  | Eta.Exit.Error (Eta.Cause.Fail error) when predicate error -> ()
  | Eta.Exit.Error _ -> Alcotest.fail (label ^ ": wrong failure")
  | Eta.Exit.Ok _ -> Alcotest.fail (label ^ ": unexpectedly succeeded")

let test_initialization_failure_closes_connection () =
  with_runtime @@ fun _ sw rt ->
  let state, flow = scripted_flow ~fail_write:2 key in
  (match Eta.Runtime.run rt (connect_conversation sw flow) with
   | Eta.Exit.Error _ -> () | Eta.Exit.Ok _ -> Alcotest.fail "expected initialization failure");
  Alcotest.(check int) "flow closed exactly once" 1 state.closed

let test_oaerr_malformed_frames_are_outer_decode () =
  let run encoded connect read is_decode =
    with_runtime @@ fun _ sw rt ->
    let state, flow = scripted_flow ~frames:[ encoded ] key in
    let connection = run_ok rt "connect" (connect sw flow) in
    (match Eta.Runtime.run rt (read connection) with
     | Eta.Exit.Error (Eta.Cause.Fail error) when is_decode error ->
         ()
     | _ -> Alcotest.fail "malformed frame did not fail through outer Decode");
    Alcotest.(check int) "decode releases once" 1 state.closed
  in
  run (frame Eta_http_ws.Codec.Text "{not-json") connect_conversation
    T.Conversation.read_event
    (function
      | T.Conversation.Openai_error (Eta_ai_openai.Error.Decode _) -> true
      | _ -> false);
  run (frame Eta_http_ws.Codec.Binary "\000\001") connect_conversation
    T.Conversation.read_event
    (function
      | T.Conversation.Openai_error (Eta_ai_openai.Error.Decode _) -> true
      | _ -> false);
  run (frame Eta_http_ws.Codec.Binary "\000\001") connect_transcription
    T.Transcription.read_event
    (function
      | T.Transcription.Openai_error (Eta_ai_openai.Error.Decode _) -> true
      | _ -> false);
  run (frame Eta_http_ws.Codec.Binary "\000\001") connect_translation
    T.Translation.read_event
    (function
      | T.Translation.Openai_error (Eta_ai_openai.Error.Decode _) -> true
      | _ -> false)

let test_oaerr_02qe_typed_error_delivered_in_band () =
  (* oaerr-02qe/oartc-ebfd: a documented recoverable provider error is delivered
     as a typed in-band event; oaerr-g6ee: the caller decides whether the
     connection continues. *)
  with_runtime @@ fun _ sw rt ->
  let error_frame =
    frame Eta_http_ws.Codec.Text
      {|{"type":"error","event_id":"recoverable","error":{"type":"invalid_request_error","code":"bad_audio","message":"nope","param":"audio"},"marker":"complete"}|}
  in
  let next_frame =
    frame Eta_http_ws.Codec.Text
      {|{"type":"session.output_transcript.delta","event_id":"after","delta":"still-running","elapsed_ms":1}|}
  in
  let state, flow = scripted_flow ~frames:[ error_frame; next_frame ] key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  (match run_ok rt "typed error in band" (T.Translation.read_event connection) with
   | Some
       (R.Translation.Error
         { code = Some "bad_audio"; type_ = "invalid_request_error";
           message = "nope"; event_id = "recoverable"; raw; full; _ }) ->
       Alcotest.(check (option string)) "param preserved" (Some "audio")
         (Eta_ai.Json.string_member "param" raw);
       Alcotest.(check (option string)) "nested raw object" (Some "bad_audio")
         (Eta_ai.Json.string_member "code" raw);
       Alcotest.(check (option string)) "complete full event" (Some "complete")
         (Eta_ai.Json.string_member "marker" full)
   | _ -> Alcotest.fail "recoverable error must decode as typed in-band event");
  Alcotest.(check int) "error does not release the connection" 0 state.closed;
  (match run_ok rt "connection stays usable" (T.Translation.read_event connection) with
   | Some (R.Translation.Output_transcript_delta { delta = "still-running"; _ }) -> ()
   | _ -> Alcotest.fail "connection must remain usable after a recoverable error");
  ignore (run_ok rt "caller-chosen abort" (T.Translation.abort connection));
  Alcotest.(check int) "caller abort releases once" 1 state.closed

let test_oastr_conversation_finish_commit_terminal () =
  with_runtime @@ fun _ sw rt ->
  let state, flow, deliver = dynamic_scripted_flow key in
  let connection = run_ok rt "conversation connect" (connect_conversation sw flow) in
  let finished = fork_run ~sw rt (T.Conversation.finish connection) in
  wait_writes state 4;
  Alcotest.(check (list string)) "conversation completion sequence"
    [ "session.update"; "input_audio_buffer.commit"; "response.create" ]
    (outgoing_event_types state);
  let finish_tag =
    outgoing_json state
    |> List.find_map (fun json ->
           if Eta_ai.Json.string_member "type" json = Some "response.create" then
             Option.bind (Eta_ai.Json.object_member "response" json) (fun response ->
             Option.bind (Eta_ai.Json.object_member "metadata" response)
               (Eta_ai.Json.string_member "eta_finish_id"))
           else None)
    |> Option.get
  in
  let events =
    [ {|{"type":"response.created","event_id":"stale-created","response":{"id":"stale","metadata":{"eta_finish_id":"older"}}}|};
      {|{"type":"response.done","event_id":"stale-done","response":{"id":"stale","metadata":{"eta_finish_id":"older"}}}|};
      Printf.sprintf
        {|{"type":"response.created","event_id":"target-created","response":{"id":"r1","metadata":{"eta_finish_id":"%s"}}}|}
        finish_tag;
      Printf.sprintf
        {|{"type":"response.done","event_id":"target-done","response":{"id":"r1","metadata":{"eta_finish_id":"%s"}}}|}
        finish_tag ]
    |> List.map (frame Eta_http_ws.Codec.Text)
    |> String.concat ""
  in
  Eio.Promise.resolve deliver events;
  ignore (run_ok rt "stale created" (T.Conversation.read_event connection));
  ignore (run_ok rt "stale done" (T.Conversation.read_event connection));
  Alcotest.(check bool) "stale response cannot finish" false
    (Eio.Promise.is_resolved finished);
  (match run_ok rt "target created" (T.Conversation.read_event connection) with
   | Some (R.Conversation.Response_created _) -> ()
   | _ -> Alcotest.fail "missing target response.created");
  Alcotest.(check bool) "finish waits for target response.done" false
    (Eio.Promise.is_resolved finished);
  (match run_ok rt "target done" (T.Conversation.read_event connection) with
   | Some (R.Conversation.Response_done _) -> ()
   | _ -> Alcotest.fail "missing target response.done");
  (match Eio.Promise.await finished with
   | Eta.Exit.Ok () -> ()
   | _ -> Alcotest.fail "conversation finish failed");
  Alcotest.(check int) "conversation terminal closes once" 1 state.closed

let test_oastr_transcription_finish_commit_terminal () =
  with_runtime @@ fun _ sw rt ->
  let frames =
    [ {|{"type":"input_audio_buffer.committed","item_id":"i1"}|};
      {|{"type":"conversation.item.input_audio_transcription.completed","event_id":"ev-older","item_id":"older","content_index":0,"transcript":"old","languages":[]}|};
      {|{"type":"conversation.item.input_audio_transcription.completed","event_id":"ev-i1","item_id":"i1","content_index":0,"transcript":"done","languages":[]}|} ]
    |> List.map (frame Eta_http_ws.Codec.Text)
  in
  let state, flow = scripted_flow ~frames key in
  let connection = run_ok rt "transcription connect" (connect_transcription sw flow) in
  let finished = fork_run ~sw rt (T.Transcription.finish connection) in
  wait_writes state 3;
  Alcotest.(check (list string)) "transcription completion sequence"
    [ "session.update"; "input_audio_buffer.commit" ]
    (outgoing_event_types state);
  (match run_ok rt "commit confirmation" (T.Transcription.read_event connection) with
   | Some (R.Transcription.Input_audio_buffer_committed _) -> ()
   | _ -> Alcotest.fail "missing committed item id");
  (match run_ok rt "older completion" (T.Transcription.read_event connection) with
   | Some (R.Transcription.Transcription_completed { item_id = "older"; _ }) -> ()
   | _ -> Alcotest.fail "missing older completion");
  Alcotest.(check bool) "out-of-order older item does not finish" false
    (Eio.Promise.is_resolved finished);
  (match run_ok rt "matching completion" (T.Transcription.read_event connection) with
   | Some (R.Transcription.Transcription_completed { item_id = "i1"; _ }) -> ()
   | _ -> Alcotest.fail "missing transcription completion");
  (match Eio.Promise.await finished with Eta.Exit.Ok () -> () | _ -> Alcotest.fail "transcription finish failed");
  Alcotest.(check int) "transcription terminal closes once" 1 state.closed

let test_oastr_transcription_failed_is_terminal () =
  with_runtime @@ fun _ sw rt ->
  let frames =
    [ {|{"type":"input_audio_buffer.committed","item_id":"i-failed"}|};
      {|{"type":"conversation.item.input_audio_transcription.failed","event_id":"ev-stale","item_id":"older","content_index":0,"error":{"type":"transcription_error","code":"old_audio","message":"stale failure"}}|};
      {|{"type":"conversation.item.input_audio_transcription.failed","event_id":"ev-failed","item_id":"i-failed","content_index":0,"error":{"type":"transcription_error","code":"bad_audio","message":"could not transcribe"}}|} ]
    |> List.map (frame Eta_http_ws.Codec.Text)
  in
  let state, flow = scripted_flow ~frames key in
  let connection =
    run_ok rt "transcription connect" (connect_transcription sw flow)
  in
  let finished = fork_run ~sw rt (T.Transcription.finish connection) in
  wait_writes state 3;
  (match run_ok rt "commit confirmation" (T.Transcription.read_event connection) with
   | Some (R.Transcription.Input_audio_buffer_committed _) -> ()
   | _ -> Alcotest.fail "missing committed item id");
  Alcotest.(check bool) "failed item not yet observed" false
    (Eio.Promise.is_resolved finished);
  (match run_ok rt "stale failure" (T.Transcription.read_event connection) with
   | Some
       (R.Transcription.Transcription_failed
          { item_id = "older"; error; _ }) ->
       Alcotest.(check (option string)) "stale failure preserved in-band"
         (Some "old_audio") (Eta_ai.Json.string_member "code" error)
   | _ -> Alcotest.fail "stale transcription failure was not pullable");
  Alcotest.(check bool) "stale failed item does not finish" false
    (Eio.Promise.is_resolved finished);
  (match run_ok rt "matching failure" (T.Transcription.read_event connection) with
   | Some
       (R.Transcription.Transcription_failed
          { item_id = "i-failed"; content_index = 0; error; _ }) ->
       Alcotest.(check (option string)) "failure preserved in-band"
         (Some "bad_audio") (Eta_ai.Json.string_member "code" error)
   | _ -> Alcotest.fail "matching transcription failure was not pullable");
  (match Eio.Promise.await finished with
   | Eta.Exit.Ok () -> ()
   | Eta.Exit.Error _ ->
       Alcotest.fail "transcription finish did not settle after failure event");
  Alcotest.(check int) "failed transcription terminal closes once" 1
    state.closed

let test_oartr_translation_finish_drains_to_closed () =
  with_runtime @@ fun _ sw rt ->
  let frames =
    [ {|{"type":"session.output_audio.delta","event_id":"audio-1","delta":"AAE=","elapsed_ms":200}|};
      {|{"type":"session.output_transcript.delta","event_id":"text-1","delta":"hola","elapsed_ms":200}|};
      {|{"type":"session.closed","event_id":"closed-1"}|} ]
    |> List.map (frame Eta_http_ws.Codec.Text)
  in
  let state, flow = scripted_flow ~frames key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  let finished = fork_run ~sw rt (T.Translation.finish connection) in
  wait_writes state 3;
  Alcotest.(check (list string)) "translation graceful signal"
    [ "session.update"; "session.close" ] (outgoing_event_types state);
  (match run_ok rt "audio drain" (T.Translation.read_event connection) with
   | Some (R.Translation.Output_audio_delta { delta = "AAE="; _ }) -> () | _ -> Alcotest.fail "audio dropped");
  (match run_ok rt "transcript drain" (T.Translation.read_event connection) with
   | Some (R.Translation.Output_transcript_delta { delta = "hola"; _ }) -> () | _ -> Alcotest.fail "transcript dropped");
  Alcotest.(check bool) "finish still waits before session.closed" false (Eio.Promise.is_resolved finished);
  (match run_ok rt "closed drain fence" (T.Translation.read_event connection) with
   | Some (R.Translation.Session_closed _) -> () | _ -> Alcotest.fail "missing session.closed");
  (match Eio.Promise.await finished with Eta.Exit.Ok () -> () | _ -> Alcotest.fail "translation finish failed");
  Alcotest.(check int) "translation closes at fence exactly once" 1 state.closed

let test_oartc_local_misuse_rejected_before_transmission () =
  with_runtime @@ fun _ sw rt ->
  let state, flow = scripted_flow key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  let finishing = fork_run ~sw rt (T.Translation.finish connection) in
  wait_writes state 3;
  let before = state.writes in
  expect_fail "append after finish" (function T.Translation.Finished -> true | _ -> false)
    (Eta.Runtime.run rt (T.Translation.send_event connection
       (R.Translation.Input_audio_buffer_append { audio = pcm_audio (); event_id = None })));
  expect_fail "second finish" (function T.Translation.Already_finished -> true | _ -> false)
    (Eta.Runtime.run rt (T.Translation.finish connection));
  Alcotest.(check int) "misuse transmitted nothing" before state.writes;
  run_ok rt "abort" (T.Translation.abort connection);
  let after_abort = state.writes in
  expect_fail "send after abort" (function T.Translation.Aborted -> true | _ -> false)
    (Eta.Runtime.run rt (T.Translation.send_event connection
       (R.Translation.Session_update { session = translation_session (); event_id = None })));
  Alcotest.(check int) "post-abort transmitted nothing" after_abort state.writes;
  (match Eio.Promise.await finishing with Eta.Exit.Error _ -> () | _ -> Alcotest.fail "aborted finish succeeded");
  Alcotest.(check int) "abort releases once" 1 state.closed

let test_oaerr_local_event_validation_precedes_transmission () =
  with_runtime @@ fun _ sw rt ->
  let state, flow = scripted_flow key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  let before = state.writes in
  expect_fail "long event id"
    (function
      | T.Translation.Openai_error (Eta_ai_openai.Error.Invalid_request _) -> true
      | _ -> false)
    (Eta.Runtime.run rt
       (T.Translation.send_event connection
          (R.Translation.Session_update
             {
               session = translation_session ();
               event_id = Some (String.make 513 'x');
             })));
  let wrong_audio =
    { (pcm_audio ()) with Eta_ai.format = Eta_ai.G711_ulaw }
  in
  expect_fail "translation audio format"
    (function
      | T.Translation.Openai_error (Eta_ai_openai.Error.Invalid_request _) -> true
      | _ -> false)
    (Eta.Runtime.run rt
       (T.Translation.send_event connection
          (R.Translation.Input_audio_buffer_append
             { audio = wrong_audio; event_id = None })));
  Alcotest.(check int) "invalid events transmitted nothing" before state.writes;
  run_ok rt "abort" (T.Translation.abort connection)

let test_transcription_validation_and_bounds () =
  with_runtime @@ fun _ sw rt ->
  let bad_state, bad_flow = scripted_flow key in
  (match
     R.Transcription.session
       ~input_audio_format:R.Transcription.Pcm16_24khz
       ~model:"gpt-live-transcribe" ~keywords:[ "bad\nkeyword" ] ()
   with
   | Error (Eta_ai_openai.Error.Invalid_request _) -> ()
   | Error error ->
       Alcotest.failf "unexpected transcription validation error: %s"
         (Format.asprintf "%a" Eta_ai_openai.Error.pp error)
   | Ok _ -> Alcotest.fail "invalid transcription keyword was accepted");
  Alcotest.(check int) "invalid session transmitted nothing" 0 bad_state.writes;
  expect_transcription_fail "invalid pending bound"
    (function
      | T.Transcription.Openai_error (Eta_ai_openai.Error.Invalid_request _) -> true
      | _ -> false)
    (Eta.Runtime.run rt
       (T.Transcription.connect_session_on_flow ~key ~max_pending_events:0
          ~sw ~flow:bad_flow ~api_key
          (url "/v1/realtime?model=gpt-live-transcribe")
          (transcription_session ())));
  Alcotest.(check int) "invalid bounds transmitted nothing" 0 bad_state.writes;
  let bounded_state, bounded_flow = scripted_flow key in
  let bounded =
    run_ok rt "caller bounds"
      (T.Transcription.connect_session_on_flow ~key ~max_message_size:2048
         ~max_pending_events:1 ~sw ~flow:bounded_flow ~api_key
         (url "/v1/realtime?model=gpt-live-transcribe")
         (transcription_session ()))
  in
  Alcotest.(check int) "bounded connection initialized" 2 bounded_state.writes;
  run_ok rt "bounded abort" (T.Transcription.abort bounded)

let test_oastr_second_concurrent_read_fails_immediately () =
  with_runtime @@ fun _ sw rt ->
  let state, flow = scripted_flow key in
  let connection = run_ok rt "conversation connect" (connect_conversation sw flow) in
  let first = fork_run ~sw rt (T.Conversation.read_event connection) in
  Eio.Fiber.yield ();
  expect_conversation_fail "second concurrent read" (function T.Conversation.Concurrent_read -> true | _ -> false)
    (Eta.Runtime.run rt (T.Conversation.read_event connection));
  run_ok rt "abort" (T.Conversation.abort connection);
  ignore (Eio.Promise.await first);
  Alcotest.(check int) "concurrent read abort releases once" 1 state.closed

let test_h2_effect_construction_is_lazy () =
  with_runtime @@ fun _ sw rt ->
  let frames =
    [ frame Eta_http_ws.Codec.Text
        {|{"type":"session.future","event_id":"future","marker":"read"}|} ]
  in
  let state, flow = scripted_flow ~frames key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  let discarded_abort = T.Translation.abort connection in
  let discarded_read = T.Translation.read_event connection in
  ignore discarded_abort;
  ignore discarded_read;
  run_ok rt "send after discarded abort"
    (T.Translation.send_event connection
       (R.Translation.Session_update
          { session = translation_session (); event_id = Some "still-open" }));
  (match run_ok rt "read after discarded read"
      (T.Translation.read_event connection) with
   | Some (R.Translation.Unknown { type_ = "session.future"; _ }) -> ()
   | _ -> Alcotest.fail "discarded read reserved connection");
  run_ok rt "executed abort" (T.Translation.abort connection);
  Alcotest.(check int) "executed abort releases" 1 state.closed

let masked_frame payload =
  Eta_http_ws.Codec.encode ~mask:(Bytes.of_string "mask")
    { Eta_http_ws.Codec.fin = true; opcode = Eta_http_ws.Codec.Text;
      payload = Bytes.of_string payload }
  |> Bytes.to_string

let test_h3_transport_failure_resolves_finish_with_primary () =
  with_runtime @@ fun _ sw rt ->
  let state, flow, deliver = dynamic_scripted_flow key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  let finished = fork_run ~sw rt (T.Translation.finish connection) in
  wait_writes state 3;
  Eio.Promise.resolve deliver (masked_frame {|{"type":"session.closed","event_id":"x"}|});
  let read_message =
    match Eta.Runtime.run rt (T.Translation.read_event connection) with
    | Eta.Exit.Error (Eta.Cause.Fail
        (T.Translation.Websocket (`Protocol message))) -> message
    | _ -> Alcotest.fail "read did not preserve transport Protocol"
  in
  (match Eio.Promise.await finished with
   | Eta.Exit.Error (Eta.Cause.Fail
       (T.Translation.Websocket (`Protocol message))) ->
       Alcotest.(check string) "same primary transport failure"
         read_message message
   | _ -> Alcotest.fail "finish remained blocked or lost transport failure");
  Alcotest.(check int) "transport failure releases once" 1 state.closed

let test_m7_cleanup_failure_preserves_decode_primary () =
  with_runtime @@ fun _ sw rt ->
  let state, flow =
    scripted_flow ~fail_write:3
      ~frames:[ frame Eta_http_ws.Codec.Text "{malformed" ] key
  in
  let connection = run_ok rt "conversation connect" (connect_conversation sw flow) in
  (match Eta.Runtime.run rt (T.Conversation.read_event connection) with
   | Eta.Exit.Error (Eta.Cause.Fail
       (T.Conversation.Openai_error (Eta_ai_openai.Error.Decode _))) -> ()
   | _ -> Alcotest.fail "failing close-frame cleanup masked Decode");
  Alcotest.(check int) "cleanup attempted and flow released" 1 state.closed

let test_oastr_finish_with_caller_timeout () =
  with_runtime @@ fun _ sw rt ->
  let state, flow = scripted_flow key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  expect_fail "caller timeout" (function T.Translation.Timeout -> true | _ -> false)
    (Eta.Runtime.run rt (T.Translation.finish_with_timeout ~timeout:(Eta.Duration.ms 2) connection));
  Alcotest.(check int) "timeout cancellation releases once" 1 state.closed

let test_oastr_finish_with_timeout_states () =
  (* Success before the deadline. *)
  with_runtime @@ fun env sw rt ->
  let closed_frame =
    frame Eta_http_ws.Codec.Text {|{"type":"session.closed","event_id":"closed-1"}|}
  in
  let state, flow = scripted_flow ~frames:[ closed_frame ] key in
  let connection = run_ok rt "connect" (connect_translation sw flow) in
  let finished =
    fork_run ~sw rt
      (T.Translation.finish_with_timeout ~timeout:(Eta.Duration.ms 500)
         connection)
  in
  wait_writes state 3;
  (match run_ok rt "reader observes closed" (T.Translation.read_event connection) with
   | Some (R.Translation.Session_closed _) -> ()
   | _ -> Alcotest.fail "reader must observe session.closed");
  (match Eio.Promise.await finished with
   | Eta.Exit.Ok () -> ()
   | Eta.Exit.Error _ ->
       Alcotest.fail "bounded finish succeeds before deadline failed");
  expect_runtime_drained env rt "successful bounded finish";
  (* A bounded finish after terminal completion reports Already_finished
     immediately instead of waiting for the deadline. *)
  expect_fail "already finished"
    (function T.Translation.Already_finished -> true | _ -> false)
    (Eta.Runtime.run rt
       (T.Translation.finish_with_timeout ~timeout:(Eta.Duration.ms 10000)
          connection));
  Alcotest.(check int) "terminal close released once" 1 state.closed;
  (* A concurrent duplicate bounded finish is rejected without a deadline wait. *)
  with_runtime @@ fun _ sw rt ->
  let _state, flow = scripted_flow key in
  let connection = run_ok rt "connect" (connect_translation sw flow) in
  let first =
    fork_run ~sw rt
      (T.Translation.finish_with_timeout ~timeout:(Eta.Duration.ms 10000)
         connection)
  in
  Eio.Fiber.yield ();
  expect_fail "duplicate finish"
    (function T.Translation.Already_finished -> true | _ -> false)
    (Eta.Runtime.run rt
       (T.Translation.finish_with_timeout ~timeout:(Eta.Duration.ms 10000)
          connection));
  ignore (run_ok rt "first finish abort" (T.Translation.abort connection));
  ignore (Eio.Promise.await first);
  (* A transport failure before the deadline is returned, not masked as Timeout. *)
  with_runtime @@ fun env sw rt ->
  let _state, flow = scripted_flow ~fail_write:3 key in
  let connection = run_ok rt "connect" (connect_conversation sw flow) in
  expect_fail "transport failure before deadline"
    (function T.Conversation.Websocket _ -> true | _ -> false)
    (Eta.Runtime.run rt
       (T.Conversation.finish_with_timeout ~timeout:(Eta.Duration.ms 10000)
          connection));
  expect_runtime_drained env rt "early bounded-finish failure";
  (* A caller abort after an in-band provider error is returned, not Timeout. *)
  with_runtime @@ fun _ sw rt ->
  let error_frame =
    frame Eta_http_ws.Codec.Text
      {|{"type":"error","event_id":"recoverable","error":{"type":"invalid_request_error","code":"bad_audio","message":"nope"}}|}
  in
  let state, flow = scripted_flow ~frames:[ error_frame ] key in
  let connection = run_ok rt "connect" (connect_translation sw flow) in
  ignore (run_ok rt "in-band error" (T.Translation.read_event connection));
  ignore (run_ok rt "caller abort" (T.Translation.abort connection));
  expect_fail "caller abort preserved"
    (function T.Translation.Aborted -> true | _ -> false)
    (Eta.Runtime.run rt
       (T.Translation.finish_with_timeout ~timeout:(Eta.Duration.ms 10000)
          connection));
  Alcotest.(check int) "abort released once" 1 state.closed;
  (* Timeout with a failing cleanup still returns Timeout and releases once. *)
  with_runtime @@ fun _ sw rt ->
  let state, flow = scripted_flow ~fail_write:4 key in
  let connection = run_ok rt "connect" (connect_translation sw flow) in
  expect_fail "timeout survives failing cleanup"
    (function T.Translation.Timeout -> true | _ -> false)
    (Eta.Runtime.run rt
       (T.Translation.finish_with_timeout ~timeout:(Eta.Duration.ms 2)
          connection));
  Alcotest.(check int) "failing cleanup released once" 1 state.closed

let test_oastr_finish_with_timeout_parent_cancellation () =
  with_runtime @@ fun env sw rt ->
  let state, flow = scripted_flow key in
  let connection = run_ok rt "connect" (connect_translation sw flow) in
  let cancelled =
    Eta.Runtime.run rt
      (E.race
         [ T.Translation.finish_with_timeout ~timeout:(Eta.Duration.seconds 10)
             connection
           |> E.map (fun () -> `Finished);
           E.sleep (Eta.Duration.ms 2) |> E.map (fun () -> `Cancelled) ])
  in
  (match cancelled with
   | Eta.Exit.Ok `Cancelled -> ()
   | Eta.Exit.Ok `Finished ->
       Alcotest.fail "bounded finish completed instead of being cancelled"
   | Eta.Exit.Error _ ->
       Alcotest.fail "cancelling bounded finish failed the race");
  Alcotest.(check int) "parent cancellation releases once" 1 state.closed;
  expect_runtime_drained env rt "parent-cancelled bounded finish";
  let writes_after_drain = state.writes in
  Eio.Fiber.yield ();
  Alcotest.(check int) "no later timer write" writes_after_drain state.writes;
  Alcotest.(check int) "no later timer release" 1 state.closed

let test_oastr_realtime_bounds_and_overrides () =
  Alcotest.(check bool) "positive default message bound" true
    (T.default_max_message_size > 0);
  Alcotest.(check bool) "positive default pending bound" true
    (T.default_max_pending_events > 0);
  with_runtime @@ fun _ sw rt ->
  let oversized =
    frame Eta_http_ws.Codec.Text
      {|{"type":"conversation.item.input_audio_transcription.delta","item_id":"i","delta":"too-large"}|}
  in
  let state, flow, release = gated_scripted_flow oversized key in
  let connection =
    run_ok rt "bounded transcription connect"
      (T.Transcription.connect_session_on_flow ~key ~max_message_size:8
         ~max_pending_events:1 ~sw ~flow ~api_key
         (url "/v1/realtime?model=gpt-live-transcribe")
         (transcription_session ()))
  in
  Eio.Promise.resolve release ();
  expect_transcription_fail "message bound"
    (function T.Transcription.Websocket (`Protocol message) ->
      String.length message > 0 | _ -> false)
    (Eta.Runtime.run rt (T.Transcription.read_event connection));
  Alcotest.(check int) "bound failure releases once" 1 state.closed;
  let pending_frames =
    List.init 3 (fun index ->
        frame Eta_http_ws.Codec.Text
          (Printf.sprintf {|{"type":"future.%d","marker":%d}|} index index))
  in
  let pending_state, pending_flow =
    scripted_flow ~frames:pending_frames key
  in
  let pending =
    run_ok rt "pending bound connect"
      (T.Transcription.connect_session_on_flow ~key ~max_pending_events:1
         ~sw ~flow:pending_flow ~api_key
         (url "/v1/realtime?model=gpt-live-transcribe")
         (transcription_session ()))
  in
  for _ = 1 to 10 do Eio.Fiber.yield () done;
  Alcotest.(check int) "third frame remains unread under capacity one" 2
    (Stdlib.Queue.length pending_state.reads);
  for _ = 1 to 3 do
    ignore (run_ok rt "bounded pending read"
      (T.Transcription.read_event pending))
  done;
  run_ok rt "pending abort" (T.Transcription.abort pending)

let test_oastr_outbound_sends_are_serialized () =
  with_runtime @@ fun _ sw rt ->
  let state, flow = scripted_flow key in
  let connection = run_ok rt "conversation connect" (connect_conversation sw flow) in
  Eio.Fiber.List.iter (fun _ -> run_ok rt "send" (T.Conversation.send_event connection R.Conversation.(Response_create { response = None; event_id = None })))
    (List.init 24 Fun.id);
  Alcotest.(check int) "all sends plus upgrade/session" 26 state.writes;
  Alcotest.(check int) "at most one active write" 1 state.max_active_writes;
  run_ok rt "abort" (T.Conversation.abort connection)

let test_oaobs_realtime_lifecycle_without_content () =
  with_traced_runtime @@ fun _ sw rt tracer ->
  let _state, flow = scripted_flow key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  run_ok rt "translation abort" (T.Translation.abort connection);
  Eio.Fiber.yield ();
  let span =
    Eta.Tracer.dump tracer
    |> List.find (fun (span : Eta.Tracer.span) ->
           String.equal span.name "realtime openai translation")
  in
  let attr name = List.assoc_opt name span.attrs in
  Alcotest.(check (option string)) "protocol" (Some "translation")
    (attr "eta.realtime.protocol");
  Alcotest.(check (option string)) "lifecycle" (Some "abort")
    (attr "eta.realtime.lifecycle");
  Alcotest.(check (option string)) "streaming fact" (Some "true")
    (attr "eta.stream");
  List.iter
    (fun forbidden ->
      Alcotest.(check bool) ("no content attribute " ^ forbidden) false
        (List.mem_assoc forbidden span.attrs))
    [ "prompt"; "transcript"; "audio"; "api_key"; "raw_body";
      "gen_ai.request.model"; "gen_ai.request.instructions" ]

let find_named_span tracer name =
  Eta.Tracer.dump tracer
  |> List.find (fun (span : Eta.Tracer.span) -> String.equal span.name name)

let test_oaobs_49xl_decode_failure_classification () =
  with_traced_runtime @@ fun _ sw rt tracer ->
  let _state, flow = scripted_flow ~frames:[ frame Eta_http_ws.Codec.Binary "\000\001" ] key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  expect_fail "outer decode"
    (function
      | T.Translation.Openai_error (Eta_ai_openai.Error.Decode _) -> true
      | _ -> false)
    (Eta.Runtime.run rt (T.Translation.read_event connection));
  Eio.Fiber.yield ();
  let span = find_named_span tracer "realtime openai translation" in
  Alcotest.(check (option string)) "decode classification"
    (Some "decode_error") (List.assoc_opt "error.type" span.attrs);
  Alcotest.(check (option string)) "failure lifecycle" (Some "failure")
    (List.assoc_opt "eta.realtime.lifecycle" span.attrs)

let test_oaobs_49xl_init_send_failure_classification () =
  with_traced_runtime @@ fun _ sw rt tracer ->
  let _state, flow = scripted_flow ~fail_write:2 key in
  expect_fail "initialization send failure"
    (function T.Translation.Websocket _ -> true | _ -> false)
    (Eta.Runtime.run rt
       (T.Translation.connect_session_on_flow ~key ~sw ~flow ~api_key
          (url "/v1/realtime/translations?model=gpt-realtime-translate")
          (translation_session ())));
  Eio.Fiber.yield ();
  let span = find_named_span tracer "realtime openai translation" in
  Alcotest.(check (option string)) "failure lifecycle" (Some "failure")
    (List.assoc_opt "eta.realtime.lifecycle" span.attrs);
  Alcotest.(check bool) "classification present" true
    (Option.is_some (List.assoc_opt "error.type" span.attrs))

let test_oaobs_49xl_timeout_classification () =
  with_traced_runtime @@ fun _ sw rt tracer ->
  let _state, flow = scripted_flow key in
  let connection = run_ok rt "translation connect" (connect_translation sw flow) in
  expect_fail "caller timeout" (function T.Translation.Timeout -> true | _ -> false)
    (Eta.Runtime.run rt
       (T.Translation.finish_with_timeout ~timeout:(Eta.Duration.ms 2) connection));
  Eio.Fiber.yield ();
  let span = find_named_span tracer "realtime openai translation" in
  Alcotest.(check (option string)) "timeout classification" (Some "timeout")
    (List.assoc_opt "error.type" span.attrs);
  Alcotest.(check (option string)) "timeout lifecycle" (Some "timeout")
    (List.assoc_opt "eta.realtime.lifecycle" span.attrs)

let test_oaobs_49xl_connect_failure_classification () =
  with_traced_runtime @@ fun _ sw rt tracer ->
  let closed, close_resolver = Eio.Promise.create () in
  let reads = Stdlib.Queue.create () in
  Stdlib.Queue.push
    (Return "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
    reads;
  Stdlib.Queue.push (Await closed) reads;
  let state =
    {
      reads;
      pending = None;
      writes = 0;
      fail_write = None;
      closed = 0;
      close_resolver;
      active_writes = 0;
      max_active_writes = 0;
      written = [];
    }
  in
  let flow : Eta_http_eio.Ws.Client.flow =
    Eio.Resource.T
      (state, Eio.Resource.handler
         (Eio.Resource.H (Eio.Resource.Close, Scripted_flow.close)
          :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Scripted_flow))))
  in
  expect_fail "upgrade failure"
    (function T.Translation.Websocket (`Upgrade_failed _) -> true | _ -> false)
    (Eta.Runtime.run rt
       (T.Translation.connect_session_on_flow ~key ~sw ~flow ~api_key
          (url "/v1/realtime/translations?model=gpt-realtime-translate")
          (translation_session ())));
  Eio.Fiber.yield ();
  let span = find_named_span tracer "realtime openai translation" in
  Alcotest.(check (option string)) "connect classification"
    (Some "upgrade_error") (List.assoc_opt "error.type" span.attrs);
  Alcotest.(check (option string)) "connect lifecycle" (Some "connect_failure")
    (List.assoc_opt "eta.realtime.lifecycle" span.attrs)

let tests =
  [ ("realtime-eio-transport",
     [ Alcotest.test_case "initialization failure closes exactly once" `Quick test_initialization_failure_closes_connection;
       Alcotest.test_case "oaerr-noio malformed frames are outer Decode" `Quick test_oaerr_malformed_frames_are_outer_decode;
       Alcotest.test_case "oaerr-02qe/g6ee typed provider error delivered in-band" `Quick test_oaerr_02qe_typed_error_delivered_in_band;
       Alcotest.test_case "oastr-p26t conversation finish commit terminal" `Quick test_oastr_conversation_finish_commit_terminal;
       Alcotest.test_case "oastr-p26t transcription finish commit terminal" `Quick test_oastr_transcription_finish_commit_terminal;
       Alcotest.test_case "oastr-p26t transcription failure terminal" `Quick test_oastr_transcription_failed_is_terminal;
       Alcotest.test_case "oartr-lkjk/zre7/59md translation drain fence" `Quick test_oartr_translation_finish_drains_to_closed;
       Alcotest.test_case "oartc-04l8/qfrz/l098 misuse rejected locally" `Quick test_oartc_local_misuse_rejected_before_transmission;
       Alcotest.test_case "oaerr-huch/qb73 validation precedes transmission" `Quick test_oaerr_local_event_validation_precedes_transmission;
       Alcotest.test_case "oaerr-8ouo transcription validation and bounds" `Quick test_transcription_validation_and_bounds;
       Alcotest.test_case "oastr-jete concurrent read nominal failure" `Quick test_oastr_second_concurrent_read_fails_immediately;
       Alcotest.test_case "H2 abort/read effect construction is lazy" `Quick test_h2_effect_construction_is_lazy;
       Alcotest.test_case "H3 transport failure resolves finish with primary" `Quick test_h3_transport_failure_resolves_finish_with_primary;
       Alcotest.test_case "M7 cleanup failure preserves primary" `Quick test_m7_cleanup_failure_preserves_decode_primary;
       Alcotest.test_case "oastr-ip8c caller timeout cancels finish" `Quick test_oastr_finish_with_caller_timeout;
       Alcotest.test_case "oastr-ip8c finish with timeout states" `Quick test_oastr_finish_with_timeout_states;
       Alcotest.test_case "oastr-ip8c parent cancellation drains timer" `Quick test_oastr_finish_with_timeout_parent_cancellation;
       Alcotest.test_case "oastr-h4gx/nxev/8f7g/659y bounded overrides" `Quick test_oastr_realtime_bounds_and_overrides;
       Alcotest.test_case "oastr-r5x4 outbound sends serialized" `Quick test_oastr_outbound_sends_are_serialized;
       Alcotest.test_case "oaobs-30a6 realtime lifecycle without content" `Quick test_oaobs_realtime_lifecycle_without_content;
       Alcotest.test_case "oaobs-49xl decode failure classification" `Quick test_oaobs_49xl_decode_failure_classification;
       Alcotest.test_case "oaobs-49xl timeout classification" `Quick test_oaobs_49xl_timeout_classification;
       Alcotest.test_case "oaobs-49xl init send failure classification" `Quick test_oaobs_49xl_init_send_failure_classification;
       Alcotest.test_case "oaobs-49xl connect failure classification" `Quick test_oaobs_49xl_connect_failure_classification ]) ]
