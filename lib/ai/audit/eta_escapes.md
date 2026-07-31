# Eta-Primitive-Escape Audit

Run: bash lib/ai/audit/run.sh
Current sites: 97

Sites where eta-ai reaches into raw Eio fiber/switch/promise/mutex/condition
primitives or raw Atomic.t are listed here.

Search:

    rg -n -t ocaml 'Eio\.Fiber\.fork|Eio\.Switch\.run|Eio\.Promise|Eio\.Mutex|Eio\.Condition|Atomic\.[A-Za-z0-9_]+' lib/ai

## Replaceable

No replaceable escapes yet.

## Structural

| Pattern | Sites | Why structural |
| --- | --- | --- |
| Atomic active flag | sse.ml | Enforces single-consumer access to an eta-ai stream while keeping the public API in Eta effects. |

## Debt

No debt escapes yet.

## Current Matches

<!-- BEGIN ESCAPE_MATCHES -->
- lib/ai/audio.ml:10:      opened : bool Atomic.t;
- lib/ai/audio.ml:21:  Stream { length; replayability; open_pull; opened = Atomic.make false }
- lib/ai/audio.ml:45:          if not (Atomic.compare_and_set opened false true) then
- lib/ai/openai/audio_sse.ml:38:  released : bool Atomic.t;
- lib/ai/openai/audio_sse.ml:39:  active : bool Atomic.t;
- lib/ai/openai/audio_sse.ml:88:    released = Atomic.make false;
- lib/ai/openai/audio_sse.ml:89:    active = Atomic.make false;
- lib/ai/openai/audio_sse.ml:109:    (E.sync (fun () -> Atomic.compare_and_set stream.released false true)
- lib/ai/openai/audio_sse.ml:122:  (E.sync (fun () -> Atomic.compare_and_set stream.active false true)
- lib/ai/openai/audio_sse.ml:127:           |> E.finally (E.sync (fun () -> Atomic.set stream.active false))))
- lib/ai/openai/speech.ml:367:  audio_released : bool Atomic.t;
- lib/ai/openai/speech.ml:368:  audio_active : bool Atomic.t;
- lib/ai/openai/speech.ml:376:         Atomic.compare_and_set stream.audio_released false true)
- lib/ai/openai/speech.ml:385:       Atomic.compare_and_set stream.audio_active false true)
- lib/ai/openai/speech.ml:391:                (E.sync (fun () -> Atomic.set stream.audio_active false))))
- lib/ai/openai/speech.ml:484:                audio_released = Atomic.make false;
- lib/ai/openai/speech.ml:485:                audio_active = Atomic.make false;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:98:    send_mutex : Eio.Mutex.t;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:99:    read_active : bool Atomic.t;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:100:    state : int Atomic.t;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:101:    released : bool Atomic.t;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:102:    terminal : (unit, engine_error) result Eio.Promise.t;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:103:    terminal_resolver : (unit, engine_error) result Eio.Promise.u;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:104:    terminal_resolved : bool Atomic.t;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:105:    telemetry_resolver : telemetry_end Eio.Promise.u;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:106:    telemetry_resolved : bool Atomic.t;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:111:    if Atomic.compare_and_set flag false true then Eio.Promise.resolve resolver value
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:136:        Atomic.compare_and_set t.released false true)
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:143:      match Atomic.get t.state with
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:146:          if Atomic.compare_and_set t.state state 2 then true else loop ()
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:168:    E.sync (fun () -> Atomic.set t.state 3)
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:210:    let terminal, terminal_resolver = Eio.Promise.create () in
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:211:    let telemetry, telemetry_resolver = Eio.Promise.create () in
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:213:      { ws; send_mutex = Eio.Mutex.create (); read_active = Atomic.make false;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:214:        state = Atomic.make 0; released = Atomic.make false;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:215:        terminal; terminal_resolver; terminal_resolved = Atomic.make false;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:216:        telemetry_resolver; telemetry_resolved = Atomic.make false;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:224:      (E.sync (fun () -> Eio.Promise.await telemetry)
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:267:    E.sync (fun () -> Eio.Mutex.lock t.send_mutex)
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:271:                  E.sync (fun () -> Eio.Mutex.unlock t.send_mutex)))
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:281:    match Atomic.get t.state with
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:294:    E.sync (fun () -> Atomic.compare_and_set t.read_active false true)
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:314:                       (match Atomic.get t.state = 1 && t.is_terminal event with
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:320:                  E.sync (fun () -> Atomic.set t.read_active false)
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:331:      match Atomic.get t.state with
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:333:          Atomic.set t.state 1;
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:348:    |> E.bind (fun () -> E.sync (fun () -> Eio.Promise.await t.terminal))
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:518:  let finish_counter = Atomic.make 0
- lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml:528:      "eta_finish_" ^ string_of_int (Atomic.fetch_and_add finish_counter 1)
- lib/ai/sse.ml:12:  active : bool Atomic.t;
- lib/ai/sse.ml:29:    active = Atomic.make false;
- lib/ai/sse.ml:41:  if not (Atomic.compare_and_set stream.active false true) then
- lib/ai/sse.ml:46:         (Eta.Effect.sync (fun () -> Atomic.set stream.active false)))
- lib/ai/xai/responses.ml:1119:  active : bool Atomic.t;
- lib/ai/xai/responses.ml:1206:  if not (Atomic.compare_and_set stream.active false true) then
- lib/ai/xai/responses.ml:1210:    |> E.finally (E.sync (fun () -> Atomic.set stream.active false))
- lib/ai/xai/responses.ml:1278:                   active = Atomic.make false;
- lib/ai/xai_eio/common.ml:13:  send_mutex : Eio.Mutex.t;
- lib/ai/xai_eio/common.ml:14:  read_active : bool Atomic.t;
- lib/ai/xai_eio/common.ml:15:  closing : bool Atomic.t;
- lib/ai/xai_eio/common.ml:16:  closed : (string * string) list Eio.Promise.t;
- lib/ai/xai_eio/common.ml:17:  close_resolver : (string * string) list Eio.Promise.u;
- lib/ai/xai_eio/common.ml:18:  attrs_mutex : Eio.Mutex.t;
- lib/ai/xai_eio/common.ml:21:  first_event : bool Atomic.t;
- lib/ai/xai_eio/common.ml:49:  Eio.Mutex.use_rw ~protect:false t.attrs_mutex (fun () ->
- lib/ai/xai_eio/common.ml:52:let is_closing t = Atomic.get t.closing
- lib/ai/xai_eio/common.ml:56:  if Atomic.compare_and_set t.closing false true then
- lib/ai/xai_eio/common.ml:58:      Eio.Mutex.use_rw ~protect:false t.attrs_mutex (fun () -> t.attrs)
- lib/ai/xai_eio/common.ml:60:    Eio.Promise.resolve t.close_resolver attrs
- lib/ai/xai_eio/common.ml:63:  let closed, close_resolver = Eio.Promise.create () in
- lib/ai/xai_eio/common.ml:77:      send_mutex = Eio.Mutex.create ();
- lib/ai/xai_eio/common.ml:78:      read_active = Atomic.make false;
- lib/ai/xai_eio/common.ml:79:      closing = Atomic.make false;
- lib/ai/xai_eio/common.ml:82:      attrs_mutex = Eio.Mutex.create ();
- lib/ai/xai_eio/common.ml:85:      first_event = Atomic.make false;
- lib/ai/xai_eio/common.ml:90:    (E.sync (fun () -> Eio.Promise.await t.closed)
- lib/ai/xai_eio/common.ml:143:  if Atomic.compare_and_set t.closing false true then (
- lib/ai/xai_eio/common.ml:145:      Eio.Mutex.use_rw ~protect:false t.attrs_mutex (fun () -> t.attrs)
- lib/ai/xai_eio/common.ml:147:    Eio.Promise.resolve t.close_resolver attrs;
- lib/ai/xai_eio/common.ml:153:      Eio.Mutex.lock t.send_mutex;
- lib/ai/xai_eio/common.ml:154:      if Atomic.get t.closing then (
- lib/ai/xai_eio/common.ml:155:        Eio.Mutex.unlock t.send_mutex;
- lib/ai/xai_eio/common.ml:164:                    E.sync (fun () -> Eio.Mutex.unlock t.send_mutex)
- lib/ai/xai_eio/common.ml:185:  if not (Atomic.compare_and_set t.read_active false true) then
- lib/ai/xai_eio/common.ml:198:             if Atomic.compare_and_set t.first_event false true then
- lib/ai/xai_eio/common.ml:212:             E.sync (fun () -> Atomic.set t.read_active false)
- lib/ai/xai_eio/realtime.ml:8:  input_transport : R.audio_transport Atomic.t;
- lib/ai/xai_eio/realtime.ml:9:  output_transport : R.audio_transport Atomic.t;
- lib/ai/xai_eio/realtime.ml:50:        ( input_transport session (Atomic.get t.input_transport),
- lib/ai/xai_eio/realtime.ml:51:          output_transport session (Atomic.get t.output_transport) )
- lib/ai/xai_eio/realtime.ml:52:    | _ -> (Atomic.get t.input_transport, Atomic.get t.output_transport)
- lib/ai/xai_eio/realtime.ml:67:           Atomic.set t.input_transport next_input;
- lib/ai/xai_eio/realtime.ml:68:           Atomic.set t.output_transport next_output)
- lib/ai/xai_eio/realtime.ml:72:  match Atomic.get t.input_transport with
- lib/ai/xai_eio/realtime.ml:88:  | `Binary bytes when Atomic.get t.output_transport = R.Binary ->
- lib/ai/xai_eio/realtime.ml:147:      input_transport = Atomic.make R.Json;
- lib/ai/xai_eio/realtime.ml:148:      output_transport = Atomic.make R.Json;
<!-- END ESCAPE_MATCHES -->
