(* effet-otel: OTLP/JSON over HTTP/1.1 exporter for Effet's tracer capability.

   Hand-rolled to keep the dependency closure to {effet, eio, eio.unix}. The
   exporter accumulates completed spans on an Eio.Stream, a background fiber
   drains the stream, encodes each batch as an OTLP/JSON
   ExportTraceServiceRequest, and POSTs it to the configured endpoint. *)

(* ------------------------------------------------------------------ *)
(* Hex helpers                                                        *)
(* ------------------------------------------------------------------ *)

let hex_of_bytes b =
  let buf = Buffer.create (2 * Bytes.length b) in
  Bytes.iter (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c))) b;
  Buffer.contents buf

let random_bytes rng n =
  let b = Bytes.create n in
  for i = 0 to n - 1 do
    Bytes.set b i (Char.chr (Random.State.int rng 256))
  done;
  b

(* ------------------------------------------------------------------ *)
(* JSON encoder (minimal, hand-written)                               *)
(* ------------------------------------------------------------------ *)

module Json = struct
  let buf_string buf s =
    Buffer.add_char buf '"';
    String.iter
      (fun c ->
        match c with
        | '"' -> Buffer.add_string buf "\\\""
        | '\\' -> Buffer.add_string buf "\\\\"
        | '\n' -> Buffer.add_string buf "\\n"
        | '\r' -> Buffer.add_string buf "\\r"
        | '\t' -> Buffer.add_string buf "\\t"
        | c when Char.code c < 0x20 ->
            Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
        | c -> Buffer.add_char buf c)
      s;
    Buffer.add_char buf '"'

  let kv buf k v =
    buf_string buf k;
    Buffer.add_char buf ':';
    Buffer.add_string buf v

  let attr buf (k, v) =
    Buffer.add_string buf "{\"key\":";
    buf_string buf k;
    Buffer.add_string buf ",\"value\":{\"stringValue\":";
    buf_string buf v;
    Buffer.add_string buf "}}"

  let attrs buf pairs =
    Buffer.add_char buf '[';
    List.iteri
      (fun i a ->
        if i > 0 then Buffer.add_char buf ',';
        attr buf a)
      pairs;
    Buffer.add_char buf ']'
end

(* ------------------------------------------------------------------ *)
(* Span record (one collected span, ready to encode)                  *)
(* ------------------------------------------------------------------ *)

type span = {
  trace_id : string; (* 32 hex chars *)
  span_id : string; (* 16 hex chars *)
  parent_span_id : string option;
  name : string;
  start_unix_ns : int;
  mutable end_unix_ns : int;
  mutable attrs : (string * string) list;
  mutable events : (string * int * (string * string) list) list;
  mutable links : Effet.Capabilities.span_link list;
  mutable status_code : int; (* 0 unset, 1 ok, 2 error *)
  mutable status_message : string;
}

let encode_span buf s =
  Buffer.add_char buf '{';
  Json.kv buf "traceId" (Printf.sprintf "\"%s\"" s.trace_id);
  Buffer.add_char buf ',';
  Json.kv buf "spanId" (Printf.sprintf "\"%s\"" s.span_id);
  (match s.parent_span_id with
  | Some p ->
      Buffer.add_char buf ',';
      Json.kv buf "parentSpanId" (Printf.sprintf "\"%s\"" p)
  | None -> ());
  Buffer.add_char buf ',';
  Buffer.add_string buf "\"name\":";
  Json.buf_string buf s.name;
  Buffer.add_char buf ',';
  Json.kv buf "kind" "1";
  Buffer.add_char buf ',';
  Json.kv buf "startTimeUnixNano" (Printf.sprintf "\"%d\"" s.start_unix_ns);
  Buffer.add_char buf ',';
  Json.kv buf "endTimeUnixNano" (Printf.sprintf "\"%d\"" s.end_unix_ns);
  Buffer.add_char buf ',';
  Buffer.add_string buf "\"attributes\":";
  Json.attrs buf s.attrs;
  if s.events <> [] then begin
    Buffer.add_char buf ',';
    Buffer.add_string buf "\"events\":[";
    List.iteri
      (fun i (name, ts_ns, attrs) ->
        if i > 0 then Buffer.add_char buf ',';
        Buffer.add_char buf '{';
        Buffer.add_string buf "\"name\":";
        Json.buf_string buf name;
        Buffer.add_char buf ',';
        Json.kv buf "timeUnixNano" (Printf.sprintf "\"%d\"" ts_ns);
        Buffer.add_char buf ',';
        Buffer.add_string buf "\"attributes\":";
        Json.attrs buf attrs;
        Buffer.add_char buf '}')
      s.events;
    Buffer.add_char buf ']'
  end;
  if s.links <> [] then begin
    Buffer.add_char buf ',';
    Buffer.add_string buf "\"links\":[";
    List.iteri
      (fun i { Effet.Capabilities.link_trace_id; link_span_id; link_attrs } ->
        if i > 0 then Buffer.add_char buf ',';
        Buffer.add_char buf '{';
        Json.kv buf "traceId" (Printf.sprintf "\"%s\"" link_trace_id);
        Buffer.add_char buf ',';
        Json.kv buf "spanId" (Printf.sprintf "\"%s\"" link_span_id);
        if link_attrs <> [] then begin
          Buffer.add_char buf ',';
          Buffer.add_string buf "\"attributes\":";
          Json.attrs buf link_attrs
        end;
        Buffer.add_char buf '}')
      s.links;
    Buffer.add_char buf ']'
  end;
  if s.status_code <> 0 then begin
    Buffer.add_char buf ',';
    Buffer.add_string buf "\"status\":{";
    Json.kv buf "code" (string_of_int s.status_code);
    if s.status_message <> "" then begin
      Buffer.add_char buf ',';
      Buffer.add_string buf "\"message\":";
      Json.buf_string buf s.status_message
    end;
    Buffer.add_char buf '}'
  end;
  Buffer.add_char buf '}'

let encode_export_request ~resource_attrs ~scope_name spans =
  let buf = Buffer.create 4096 in
  Buffer.add_string buf "{\"resourceSpans\":[{\"resource\":{\"attributes\":";
  Json.attrs buf resource_attrs;
  Buffer.add_string buf "},\"scopeSpans\":[{\"scope\":{\"name\":";
  Json.buf_string buf scope_name;
  Buffer.add_string buf "},\"spans\":[";
  List.iteri
    (fun i s ->
      if i > 0 then Buffer.add_char buf ',';
      encode_span buf s)
    spans;
  Buffer.add_string buf "]}]}]}";
  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* HTTP/1.1 POST over Eio TCP                                         *)
(* ------------------------------------------------------------------ *)

let post_json ~sw ~net ~host ~port ~path body =
  let body_len = String.length body in
  let request =
    Printf.sprintf
      "POST %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
      path host port body_len body
  in
  Eio.Net.with_tcp_connect ~host ~service:(string_of_int port) net
  @@ fun flow ->
  Eio.Flow.copy_string request flow;
  (try Eio.Flow.shutdown flow `Send with _ -> ());
  let buf = Eio.Buf_read.of_flow ~max_size:65536 flow in
  let _ = sw in
  match Eio.Buf_read.line buf with
  | exception End_of_file -> Error "no response"
  | status_line -> (
      match String.split_on_char ' ' status_line with
      | _ :: code :: _ when code = "200" || code = "202" -> Ok ()
      | _ -> Error status_line)

(* ------------------------------------------------------------------ *)
(* Exporter state                                                     *)
(* ------------------------------------------------------------------ *)

type t = {
  net : [ `Generic ] Eio.Net.ty Eio.Std.r;
  clock : float Eio.Time.clock_ty Eio.Std.r;
  host : string;
  port : int;
  path : string;
  resource_attrs : (string * string) list;
  scope_name : string;
  queue : span Eio.Stream.t;
  mutable next_handle : int;
  table : (int, span) Hashtbl.t;
  rng : Random.State.t;
  flush : unit Eio.Promise.t * unit Eio.Promise.u;
  mutable in_flight : int Atomic.t;
  mutable on_error : string -> unit;
}

let now_ns t =
  let secs = Eio.Time.now t.clock in
  int_of_float (secs *. 1_000_000_000.0)

(* ------------------------------------------------------------------ *)
(* Background exporter fiber                                          *)
(* ------------------------------------------------------------------ *)

let try_post t spans =
  let n = List.length spans in
  let result =
    try
      Eio.Switch.run @@ fun sw ->
      post_json ~sw ~net:t.net ~host:t.host ~port:t.port ~path:t.path
        (encode_export_request ~resource_attrs:t.resource_attrs
           ~scope_name:t.scope_name spans)
    with exn -> Error (Printexc.to_string exn)
  in
  (match result with
  | Ok () -> ()
  | Error msg -> (try t.on_error msg with _ -> ()));
  for _ = 1 to n do
    Atomic.decr t.in_flight
  done

let exporter_loop t =
  let rec drain_more acc remaining =
    if remaining = 0 then List.rev acc
    else
      match Eio.Stream.take_nonblocking t.queue with
      | Some s -> drain_more (s :: acc) (remaining - 1)
      | None -> List.rev acc
  in
  while true do
    let first = Eio.Stream.take t.queue in
    let batch = first :: drain_more [] 31 in
    try_post t batch
  done

(* ------------------------------------------------------------------ *)
(* Tracer methods                                                     *)
(* ------------------------------------------------------------------ *)

let resolve_parent_ids t = function
  | None, None -> (hex_of_bytes (random_bytes t.rng 16), None)
  | _, Some (ext_trace, ext_span) -> (ext_trace, Some ext_span)
  | Some p_handle, None -> (
      match Hashtbl.find_opt t.table p_handle with
      | Some p -> (p.trace_id, Some p.span_id)
      | None -> (hex_of_bytes (random_bytes t.rng 16), None))

let begin_span t ?parent_id ?external_parent ~name ~started_ms:_ () =
  let trace_id, parent_span_id =
    resolve_parent_ids t (parent_id, external_parent)
  in
  let span_id = hex_of_bytes (random_bytes t.rng 8) in
  let start_unix_ns = now_ns t in
  let s =
    {
      trace_id;
      span_id;
      parent_span_id;
      name;
      start_unix_ns;
      end_unix_ns = start_unix_ns;
      attrs = [];
      events = [];
      links = [];
      status_code = 0;
      status_message = "";
    }
  in
  let handle = t.next_handle in
  t.next_handle <- handle + 1;
  Hashtbl.replace t.table handle s;
  handle

let map_status (st : Effet.Capabilities.span_status) =
  match st with
  | Effet.Capabilities.Ok -> (1, "")
  | Effet.Capabilities.Error msg -> (2, msg)
  | Effet.Capabilities.Cancelled -> (2, "cancelled")

let end_span t ~span_id ~status ~ended_ms:_ =
  match Hashtbl.find_opt t.table span_id with
  | None -> ()
  | Some s ->
      Hashtbl.remove t.table span_id;
      s.end_unix_ns <- now_ns t;
      let code, message = map_status status in
      s.status_code <- code;
      s.status_message <- message;
      Atomic.incr t.in_flight;
      Eio.Stream.add t.queue s

let add_attr t ~key ~value =
  (* Attach to the most recently opened, still-open span. The runtime drives
     ordering via the fiber-local active span; we approximate it by walking
     the table. For a single fiber this is exact; for parallel fibers the
     runtime's annotate-then-named pattern still ends up under the right
     parent because annotate is invoked synchronously before the next
     begin_span on the same fiber. *)
  let target = ref None in
  Hashtbl.iter
    (fun h s ->
      match !target with
      | None -> target := Some (h, s)
      | Some (h', _) when h > h' -> target := Some (h, s)
      | _ -> ())
    t.table;
  match !target with
  | Some (_, s) -> s.attrs <- (key, value) :: s.attrs
  | None -> ()

let add_event t ~span_id ~name ~ts_ms ~attrs =
  match Hashtbl.find_opt t.table span_id with
  | None -> ()
  | Some s ->
      let ts_ns =
        if ts_ms = 0 then now_ns t else ts_ms * 1_000_000
      in
      s.events <- (name, ts_ns, attrs) :: s.events

let add_link t link =
  let target = ref None in
  Hashtbl.iter
    (fun h s ->
      match !target with
      | None -> target := Some (h, s)
      | Some (h', _) when h > h' -> target := Some (h, s)
      | _ -> ())
    t.table;
  match !target with
  | Some (_, s) -> s.links <- link :: s.links
  | None -> ()

let inspect t ~span_id : Effet.Capabilities.span_info option =
  match Hashtbl.find_opt t.table span_id with
  | Some s ->
      Some
        {
          Effet.Capabilities.trace_id = s.trace_id;
          span_id = s.span_id;
          name = s.name;
        }
  | None -> None

(* ------------------------------------------------------------------ *)
(* Public constructor                                                 *)
(* ------------------------------------------------------------------ *)

let create ~sw ~net ~clock ?(host = "127.0.0.1") ?(port = 4318)
    ?(path = "/v1/traces") ?(service_name = "effet") ?service_version
    ?(resource_attrs = []) ?(scope_name = "effet") ?on_error () =
  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Std.r) in
  let clock = (clock :> float Eio.Time.clock_ty Eio.Std.r) in
  let on_error =
    Option.value on_error ~default:(fun msg ->
        prerr_endline ("[effet-otel] export failed: " ^ msg))
  in
  let resource_attrs =
    let base = [ ("service.name", service_name) ] in
    let base =
      match service_version with
      | Some v -> base @ [ ("service.version", v) ]
      | None -> base
    in
    base @ resource_attrs
  in
  let rng = Random.State.make_self_init () in
  let t =
    {
      net;
      clock;
      host;
      port;
      path;
      resource_attrs;
      scope_name;
      queue = Eio.Stream.create 1024;
      next_handle = 1;
      table = Hashtbl.create 64;
      rng;
      flush = Eio.Promise.create ();
      in_flight = Atomic.make 0;
      on_error;
    }
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try exporter_loop t with _ -> ());
      `Stop_daemon);
  t

let tracer t : Effet.Capabilities.tracer =
  object
    method begin_span ?parent_id ?external_parent ~name ~started_ms () =
      begin_span t ?parent_id ?external_parent ~name ~started_ms ()

    method end_span ~span_id ~status ~ended_ms =
      end_span t ~span_id ~status ~ended_ms

    method add_attr ~key ~value = add_attr t ~key ~value
    method add_event ~span_id ~name ~ts_ms ~attrs =
      add_event t ~span_id ~name ~ts_ms ~attrs
    method add_link link = add_link t link
    method inspect ~span_id = inspect t ~span_id
  end

let flush ?(timeout_s = 5.0) t =
  let deadline = Eio.Time.now t.clock +. timeout_s in
  let rec wait () =
    if Atomic.get t.in_flight = 0 then ()
    else if Eio.Time.now t.clock > deadline then ()
    else begin
      Eio.Time.sleep t.clock 0.005;
      wait ()
    end
  in
  wait ()
