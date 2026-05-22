open Eta

type kind = Span | Log | Metric

let trim_cr s =
  let len = String.length s in
  if len > 0 && s.[len - 1] = '\r' then String.sub s 0 (len - 1) else s

let parse_content_length line =
  match String.index_opt line ':' with
  | None -> None
  | Some idx ->
      let key = String.sub line 0 idx |> String.lowercase_ascii |> String.trim in
      if String.equal key "content-length" then
        let value = String.sub line (idx + 1) (String.length line - idx - 1) in
        try Some (int_of_string (String.trim value)) with Failure _ -> Some 0
      else None

let rec read_headers br len =
  let line = Eio.Buf_read.line br |> trim_cr in
  if String.equal line "" then len
  else
    let len = match parse_content_length line with Some n -> n | None -> len in
    read_headers br len

let handle_connection requests bytes flow =
  try
    let br = Eio.Buf_read.of_flow ~max_size:(16 * 1024 * 1024) flow in
    let _request_line = Eio.Buf_read.line br in
    let content_length = read_headers br 0 in
    if content_length > 0 then
      ignore (Eio.Buf_read.take content_length br : string);
    Atomic.incr requests;
    ignore (Atomic.fetch_and_add bytes content_length : int);
    Eio.Flow.copy_string
      "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      flow;
    try Eio.Flow.shutdown flow `Send with _ -> ()
  with _ -> ()

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> invalid_arg "expected TCP listener"

let start_collector ~sw ~net =
  let requests = Atomic.make 0 in
  let bytes = Atomic.make 0 in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:128 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try
         while true do
           let flow, _addr = Eio.Net.accept ~sw socket in
           Eio.Fiber.fork ~sw (fun () -> handle_connection requests bytes flow)
         done
       with _ -> ());
      `Stop_daemon);
  (port, requests, bytes)

let emit_span (tracer : Capabilities.tracer) i =
  let name = "bench.span." ^ string_of_int i in
  let span = tracer#begin_span ~name ~started_ms:i () in
  tracer#end_span ~span_id:span ~status:Capabilities.Ok ~ended_ms:(i + 1)

let emit_log (logger : Capabilities.logger) i =
  logger#log
    {
      Capabilities.ts_ms = i;
      level = Capabilities.Info;
      body = "bench log";
      attrs = [ ("route", "/bench") ];
      trace_id = "0af7651916cd43dd8448eb211c80319c";
      span_id = Printf.sprintf "%016x" i;
    }

let emit_metric (meter : Capabilities.meter) i =
  meter#record ~name:"bench.metric" ~description:"bench" ~unit_:"1"
    ~kind:Capabilities.Counter_monotonic ~attrs:[ ("route", "/bench") ]
    ~value:(Capabilities.Int 1) ~ts_ms:i

let emit kind exporter count =
  match kind with
  | Span ->
      let tracer = Eta_otel.tracer exporter in
      for i = 1 to count do
        emit_span tracer i
      done
  | Log ->
      let logger = Eta_otel.logger exporter in
      for i = 1 to count do
        emit_log logger i
      done
  | Metric ->
      let meter = Eta_otel.meter exporter in
      for i = 1 to count do
        emit_metric meter i
      done

let measure_once kind count =
  Gc.compact ();
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let port, requests, bytes = start_collector ~sw ~net in
  let exporter =
    Eta_otel.create ~sw ~net ~clock ~host:"127.0.0.1" ~port
      ~service_name:"eta-otel-e2e-bench" ~on_error:(fun _ -> ()) ()
  in
  let start = Unix.gettimeofday () in
  emit kind exporter count;
  Eta_otel.flush ~timeout_s:10.0 exporter;
  let stop = Unix.gettimeofday () in
  let elapsed_ns = (stop -. start) *. 1_000_000_000.0 in
  (elapsed_ns, Atomic.get requests, Atomic.get bytes)

let mean xs = List.fold_left ( +. ) 0. xs /. float_of_int (List.length xs)

let min_float = function
  | [] -> 0.0
  | x :: xs -> List.fold_left min x xs

let max_float = function
  | [] -> 0.0
  | x :: xs -> List.fold_left max x xs

let stddev xs =
  match xs with
  | [] | [ _ ] -> 0.0
  | _ ->
      let m = mean xs in
      let ss = List.fold_left (fun acc x -> acc +. ((x -. m) *. (x -. m))) 0.0 xs in
      sqrt (ss /. float_of_int (List.length xs - 1))

let kind_name = function Span -> "span" | Log -> "log" | Metric -> "metric"

let run_kind ~samples ~count kind =
  let rec loop i walls reqs bytes =
    if i = samples then (List.rev walls, List.rev reqs, List.rev bytes)
    else
      let wall, requests, body_bytes = measure_once kind count in
      loop (i + 1) (wall :: walls) (requests :: reqs) (body_bytes :: bytes)
  in
  let walls, reqs, bytes = loop 0 [] [] [] in
  let mean_wall = mean walls in
  let throughput = float_of_int count /. (mean_wall /. 1_000_000_000.0) in
  Printf.printf
    "%s.%d wall_ns mean=%.0f stddev=%.0f min=%.0f max=%.0f throughput_per_s=%.2f requests=%s bytes=%s samples=%s\n%!"
    (kind_name kind) count mean_wall (stddev walls) (min_float walls)
    (max_float walls) throughput
    (String.concat ";" (List.map string_of_int reqs))
    (String.concat ";" (List.map string_of_int bytes))
    (String.concat ";" (List.map (Printf.sprintf "%.0f") walls))

let samples = ref 5
let count = ref 1_000

let () =
  let rec parse = function
    | [] -> ()
    | "--samples" :: value :: rest ->
        samples := int_of_string value;
        parse rest
    | "--count" :: value :: rest ->
        count := int_of_string value;
        parse rest
    | arg :: _ -> invalid_arg ("unknown argument: " ^ arg)
  in
  parse (List.tl (Array.to_list Sys.argv));
  List.iter (run_kind ~samples:!samples ~count:!count) [ Span; Log; Metric ]
