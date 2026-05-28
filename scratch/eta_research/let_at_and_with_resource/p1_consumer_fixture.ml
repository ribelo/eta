open Eta

module Pulse = struct
  module Client = struct
    type client = { endpoint : string }
    type stream = { topic : string; recv : unit -> (string, [ `Closed ]) Effect.t }

    let with_client endpoint body =
      let client = { endpoint } in
      Effect.finally Effect.unit (body client)

    let with_record_stream client topic body =
      let stream = { topic; recv = (fun () -> Effect.pure client.endpoint) } in
      Effect.finally Effect.unit (body stream)

    let acquire_client endpoint = Effect.pure { endpoint }
    let release_client _client = Effect.unit
  end
end

module Keyboard = struct
  module Monitor = struct
    type monitor = { device : string }

    let with_monitor device body =
      let monitor = { device } in
      Effect.finally Effect.unit (body monitor)
  end
end

module Ptt_loop = struct
  let run ~client ~stream ~monitor =
    let open Syntax in
    let* packet = stream.Pulse.Client.recv () in
    Effect.pure (client.Pulse.Client.endpoint ^ ":" ^ stream.topic ^ ":" ^ monitor.Keyboard.Monitor.device ^ ":" ^ packet)
end

module Effect_with_resource = struct
  let with_resource ~acquire ~release body =
    let open Syntax in
    let* resource = Effect.acquire_release ~acquire ~release in
    body resource
end

let h_a_status_quo () =
  Pulse.Client.with_client "pulse.local" @@ fun client ->
  Pulse.Client.with_record_stream client "ptt" @@ fun stream ->
  Keyboard.Monitor.with_monitor "kbd0" @@ fun monitor ->
  Ptt_loop.run ~client ~stream ~monitor

let h_b_cps_resource_no_let_at () =
  Effect_with_resource.with_resource
    ~acquire:(Pulse.Client.acquire_client "pulse.local")
    ~release:Pulse.Client.release_client
  @@ fun client ->
  Pulse.Client.with_record_stream client "ptt" @@ fun stream ->
  Keyboard.Monitor.with_monitor "kbd0" @@ fun monitor ->
  Ptt_loop.run ~client ~stream ~monitor

let h_c_let_at_only () =
  let ( let@ ) f k = f k in
  let@ client = Pulse.Client.with_client "pulse.local" in
  let@ stream = Pulse.Client.with_record_stream client "ptt" in
  let@ monitor = Keyboard.Monitor.with_monitor "kbd0" in
  Ptt_loop.run ~client ~stream ~monitor

let h_d_both () =
  let ( let@ ) f k = f k in
  let@ client =
    Effect_with_resource.with_resource
      ~acquire:(Pulse.Client.acquire_client "pulse.local")
      ~release:Pulse.Client.release_client
  in
  let@ stream = Pulse.Client.with_record_stream client "ptt" in
  let@ monitor = Keyboard.Monitor.with_monitor "kbd0" in
  Ptt_loop.run ~client ~stream ~monitor

let h_e_cps_only () =
  Effect_with_resource.with_resource
    ~acquire:(Pulse.Client.acquire_client "pulse.local")
    ~release:Pulse.Client.release_client
  @@ fun client ->
  Pulse.Client.with_record_stream client "ptt" @@ fun stream ->
  Keyboard.Monitor.with_monitor "kbd0" @@ fun monitor ->
  Ptt_loop.run ~client ~stream ~monitor

let h_f_cookbook_local () =
  let ( let@ ) f k = f k in
  let@ client = Pulse.Client.with_client "pulse.local" in
  let@ stream = Pulse.Client.with_record_stream client "ptt" in
  let@ monitor = Keyboard.Monitor.with_monitor "kbd0" in
  Ptt_loop.run ~client ~stream ~monitor

let snippets =
  [
    ( "H-A",
      {|Pulse.Client.with_client "pulse.local" @@ fun client ->
Pulse.Client.with_record_stream client "ptt" @@ fun stream ->
Keyboard.Monitor.with_monitor "kbd0" @@ fun monitor ->
Ptt_loop.run ~client ~stream ~monitor|} );
    ( "H-B",
      {|Effect.with_resource
  ~acquire:(Pulse.Client.acquire_client "pulse.local")
  ~release:Pulse.Client.release_client
@@ fun client ->
Pulse.Client.with_record_stream client "ptt" @@ fun stream ->
Keyboard.Monitor.with_monitor "kbd0" @@ fun monitor ->
Ptt_loop.run ~client ~stream ~monitor|} );
    ( "H-C",
      {|let@ client = Pulse.Client.with_client "pulse.local" in
let@ stream = Pulse.Client.with_record_stream client "ptt" in
let@ monitor = Keyboard.Monitor.with_monitor "kbd0" in
Ptt_loop.run ~client ~stream ~monitor|} );
    ( "H-D",
      {|let@ client =
  Effect.with_resource
    ~acquire:(Pulse.Client.acquire_client "pulse.local")
    ~release:Pulse.Client.release_client
in
let@ stream = Pulse.Client.with_record_stream client "ptt" in
let@ monitor = Keyboard.Monitor.with_monitor "kbd0" in
Ptt_loop.run ~client ~stream ~monitor|} );
    ( "H-E",
      {|Effect.use
  ~acquire:(Pulse.Client.acquire_client "pulse.local")
  ~release:Pulse.Client.release_client
@@ fun client ->
Pulse.Client.with_record_stream client "ptt" @@ fun stream ->
Keyboard.Monitor.with_monitor "kbd0" @@ fun monitor ->
Ptt_loop.run ~client ~stream ~monitor|} );
    ( "H-F",
      {|let ( let@ ) f k = f k in
let@ client = Pulse.Client.with_client "pulse.local" in
let@ stream = Pulse.Client.with_record_stream client "ptt" in
let@ monitor = Keyboard.Monitor.with_monitor "kbd0" in
Ptt_loop.run ~client ~stream ~monitor|} );
  ]

let non_blank_lines s =
  String.split_on_char '\n' s
  |> List.filter (fun line -> String.trim line <> "")
  |> List.length

let leading_spaces line =
  let rec loop i =
    if i < String.length line && line.[i] = ' ' then loop (i + 1) else i
  in
  loop 0

let average_indent s =
  let lines =
    String.split_on_char '\n' s
    |> List.filter (fun line -> String.trim line <> "")
  in
  let total = List.fold_left (fun acc line -> acc + leading_spaces line) 0 lines in
  float total /. float (List.length lines)

let () =
  List.iter
    (fun (name, snippet) ->
      Printf.printf "%s lines=%d avg_indent=%.2f\n" name (non_blank_lines snippet)
        (average_indent snippet))
    snippets
