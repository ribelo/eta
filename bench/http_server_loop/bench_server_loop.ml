(* In-process HTTP server serve-loop benchmark for autoresearch.

   This benchmark drives the *real* eta-http server connection state machines
   ([Eta_http_eio.H1.Server_connection.run] / [...H2.Server_connection.run_h2c])
   over an in-memory two-way flow. There is no socket, no external load
   generator, and no OS scheduler between a client and server process. A
   preloaded byte buffer of pipelined requests is fed to the connection; the
   responses it writes are counted and discarded.

   Why in-process instead of oha/h2load over loopback:
   - Deterministic, single-fiber CPU work => signal dominates noise.
   - Allocation is measurable per request via [Gc] counters (the whole process
     only does server work during the timed region).
   - Deltas attribute to the server code we are optimizing, not to the client
     process or to TCP/loopback scheduling.

   It measures exactly the per-request server cost that determines real rps:
   request parsing, header handling, routing, response serialization, and the
   H2 frame/HPACK/flow-control machinery. Real socket syscall cost (a roughly
   fixed Eio/kernel overhead we do not optimize) is intentionally excluded.

   H2 multiplexing: the H2 reader reads at most one [read_buffer_size] chunk and
   then waits (via an ack promise) for the owner fiber to process it before
   reading more. By capping each [single_read] to ~[h2_window] requests' worth
   of bytes, in-flight streams stay bounded (modeling a ~16-deep multiplex
   window) and never trip [max_concurrent_streams]. Correctness is asserted
   every run from the connection [on_close] stats. *)

module Server = Eta_http.Server
module Response = Server.Response
module Body = Server.Body

(* ------------------------------------------------------------------ *)
(* In-memory two-way flow: source streams [src], sink discards/counts. *)
(* [max_read] caps bytes returned per single_read (H2 multiplex bound). *)
(* ------------------------------------------------------------------ *)

module Mem_flow = struct
  type t = {
    src : bytes;
    mutable pos : int;
    src_len : int;
    max_read : int;
    mutable written : int;
  }

  let create ?(max_read = max_int) src =
    { src; pos = 0; src_len = Bytes.length src; max_read; written = 0 }

  let single_read t buf =
    let remaining = t.src_len - t.pos in
    if remaining <= 0 then raise End_of_file
    else begin
      let n = min (min remaining (Cstruct.length buf)) t.max_read in
      Cstruct.blit_from_bytes t.src t.pos buf 0 n;
      t.pos <- t.pos + n;
      n
    end

  let single_write t bufs =
    let n = List.fold_left (fun acc c -> acc + Cstruct.length c) 0 bufs in
    t.written <- t.written + n;
    n

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
  let shutdown _t _cmd = ()
  let read_methods = []
  let close _t = ()
end

let mem_flow_handler =
  Eio.Resource.handler
    (Eio.Resource.H (Eio.Resource.Close, Mem_flow.close)
    :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Mem_flow)))

let make_mem_flow ?max_read src :
    [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t =
  Eio.Resource.T (Mem_flow.create ?max_read src, mem_flow_handler)

(* ------------------------------------------------------------------ *)
(* Handler: mirrors the testsuite server endpoints, fully in-memory.   *)
(* ------------------------------------------------------------------ *)

let static_1k_body = String.make 1024 'x'

let starts_with ~prefix s =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

let handler (req : Server.Request.t) =
  match (req.method_, req.path) with
  | _, "/" -> Eta.Effect.pure (Response.empty ~status:200 ())
  | "POST", "/user" ->
      Body.read_all req.body
      |> Eta.Effect.map (fun _ -> Response.empty ~status:200 ())
  | _, "/static/1k.bin" ->
      Eta.Effect.pure
        (Response.make ~status:200
           ~body:(Response.Body.string static_1k_body)
           ())
  | "POST", "/echo" ->
      Body.read_all req.body
      |> Eta.Effect.map (fun body ->
             Response.make ~status:200
               ~body:(Response.Body.string (Bytes.to_string body))
               ())
  | _, path when starts_with ~prefix:"/user/" path ->
      let id = String.sub path 6 (String.length path - 6) in
      Eta.Effect.pure (Response.text id)
  | _ -> Eta.Effect.pure (Response.empty ~status:404 ())

(* ------------------------------------------------------------------ *)
(* Endpoint set + request stream construction.                         *)
(* ------------------------------------------------------------------ *)

type meth = Get | Post
type endpoint = { name : string; meth : meth; path : string; body : string option }

let endpoints =
  [
    { name = "root"; meth = Get; path = "/"; body = None };
    { name = "user_id"; meth = Get; path = "/user/123"; body = None };
    { name = "post_user"; meth = Post; path = "/user"; body = Some "" };
    { name = "static_1k"; meth = Get; path = "/static/1k.bin"; body = None };
    { name = "echo_1k"; meth = Post; path = "/echo"; body = Some static_1k_body };
  ]

(* ---- H1 ---- *)

let h1_request ep =
  let m = match ep.meth with Get -> "GET" | Post -> "POST" in
  match ep.body with
  | None -> Printf.sprintf "%s %s HTTP/1.1\r\nHost: bench.local\r\n\r\n" m ep.path
  | Some body ->
      Printf.sprintf
        "%s %s HTTP/1.1\r\nHost: bench.local\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s"
        m ep.path (String.length body) body

let repeat_string s n =
  let one = String.length s in
  let buf = Bytes.create (one * n) in
  for i = 0 to n - 1 do
    Bytes.blit_string s 0 buf (i * one) one
  done;
  buf

(* ---- H2 frame + HPACK construction (literal, never-indexed) ---- *)

let h2_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

let hpack_int7 n =
  if n < 128 then [ n ]
  else
    let rec loop n acc =
      if n < 128 then List.rev (n :: acc)
      else loop (n lsr 7) (((128 + (n land 127))) :: acc)
    in
    loop (n - 127) [ 127 ]

let add_hpack_literal buf ~name ~value =
  Buffer.add_char buf '\x00';
  List.iter (fun b -> Buffer.add_char buf (Char.chr b))
    (hpack_int7 (String.length name));
  Buffer.add_string buf name;
  List.iter (fun b -> Buffer.add_char buf (Char.chr b))
    (hpack_int7 (String.length value));
  Buffer.add_string buf value

let h2_header_block ep =
  let buf = Buffer.create 64 in
  let m = match ep.meth with Get -> "GET" | Post -> "POST" in
  add_hpack_literal buf ~name:":method" ~value:m;
  add_hpack_literal buf ~name:":path" ~value:ep.path;
  add_hpack_literal buf ~name:":scheme" ~value:"http";
  add_hpack_literal buf ~name:":authority" ~value:"bench.local";
  (match ep.body with
   | Some b when String.length b > 0 ->
       add_hpack_literal buf ~name:"content-type" ~value:"text/plain"
   | _ -> ());
  Buffer.contents buf

let add_h2_frame buf ~ty ~flags ~stream_id payload =
  let len = String.length payload in
  Buffer.add_char buf (Char.chr ((len lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr ((len lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (len land 0xff));
  Buffer.add_char buf (Char.chr ty);
  Buffer.add_char buf (Char.chr flags);
  Buffer.add_char buf (Char.chr ((stream_id lsr 24) land 0x7f));
  Buffer.add_char buf (Char.chr ((stream_id lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr ((stream_id lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (stream_id land 0xff));
  Buffer.add_string buf payload

let add_h2_settings buf pairs =
  let payload = Buffer.create (6 * List.length pairs) in
  List.iter
    (fun (id, value) ->
      Buffer.add_char payload (Char.chr ((id lsr 8) land 0xff));
      Buffer.add_char payload (Char.chr (id land 0xff));
      Buffer.add_char payload (Char.chr ((value lsr 24) land 0xff));
      Buffer.add_char payload (Char.chr ((value lsr 16) land 0xff));
      Buffer.add_char payload (Char.chr ((value lsr 8) land 0xff));
      Buffer.add_char payload (Char.chr (value land 0xff)))
    pairs;
  add_h2_frame buf ~ty:0x04 ~flags:0x00 ~stream_id:0 (Buffer.contents payload)

let add_h2_window_update buf ~stream_id increment =
  let p = Bytes.create 4 in
  Bytes.set_int32_be p 0 (Int32.of_int increment);
  add_h2_frame buf ~ty:0x08 ~flags:0x00 ~stream_id (Bytes.to_string p)

(* One h2c connection's full client byte stream serving [k] streams:
   preface + client SETTINGS (+ ACK of the server's SETTINGS) + a generous
   connection WINDOW_UPDATE, then [k] requests on stream ids 1,3,..,2k-1.

   We drive H2 as many short connections each multiplexing [k] streams, rather
   than one long connection. The H2 reader is ack-paced (it reads one
   read_buffer_size chunk, then waits for the owner to process it), so dumping
   [k] requests keeps in-flight streams <= k. With k < max_concurrent_streams
   and k*1024 < the 64 KiB connection receive window, neither stream admission
   nor flow control stalls, and there is no per-stream client coordination to
   pollute the timing. Per-connection setup (HPACK tables, frame parser, switch,
   runtime) is real, optimizable H2 server work amortized over [k] streams. *)
let h2_conn_buffer ep block k =
  let buf = Buffer.create 256 in
  Buffer.add_string buf h2_preface;
  add_h2_settings buf [ (0x4, 0x7fffffff) ];
  add_h2_window_update buf ~stream_id:0 0x7ffeffff;
  add_h2_frame buf ~ty:0x04 ~flags:0x01 ~stream_id:0 "";
  for i = 0 to k - 1 do
    let sid = (2 * i) + 1 in
    match ep.body with
    | None | Some "" ->
        add_h2_frame buf ~ty:0x01 ~flags:0x05 ~stream_id:sid block
    | Some b ->
        add_h2_frame buf ~ty:0x01 ~flags:0x04 ~stream_id:sid block;
        add_h2_frame buf ~ty:0x00 ~flags:0x01 ~stream_id:sid b
  done;
  Buffer.to_bytes buf

(* Streams multiplexed per connection. Bounded so that k < max_concurrent (128)
   and k*1024 < 65535 (connection receive window) for the echo body case. *)
let h2_window = 48

(* ------------------------------------------------------------------ *)
(* Connection drivers + correctness validation via on_close stats.     *)
(* ------------------------------------------------------------------ *)

(* Benchmark config: realistic limits, but connection idle/header/body/handler
   timeouts are disabled. They never fire under real load; here they would fire
   only because the in-process client paces streams artificially (letting active
   streams briefly hit zero arms the idle timer). Timeout handling is not an
   optimization target, so removing it eliminates a benchmark artifact. *)
let config =
  let d = Eta_http_eio.Server.Config.default in
  let timeouts =
    {
      Eta_http.Server.Config.request_header_timeout = None;
      request_body_timeout = None;
      response_write_timeout = None;
      response_body_timeout = None;
      idle_timeout = None;
      handler_timeout = None;
    }
  in
  { d with server = { d.server with timeouts } }

let connection_info protocol id =
  {
    Eta_http_eio.Server.Connection_info.id;
    peer = { Server.Request.address = None; port = None };
    protocol;
    tls = false;
    alpn_protocol = None;
  }

exception Bench_invariant of string

let run_h1 ~clock ~src ~n =
  let completed = ref 0 in
  let errors = ref 0 in
  (Eio.Switch.run @@ fun sw ->
   let runtime_factory ~sw ~connection:_ () =
     Eta_eio.Runtime.create ~sw ~clock ()
   in
   Eta_http_eio.H1.Server_connection.run ~sw ~clock ~config
     ~flow:(make_mem_flow src)
     ~connection:(connection_info Server.Error.H1 "bench-h1")
     ~runtime_factory
     ~on_close:(fun (s : Eta_http_eio.H1.Server_connection.stats) ->
       completed := s.completed_requests;
       errors := s.protocol_errors)
     handler);
  if !completed <> n then
    raise (Bench_invariant (Printf.sprintf "h1 completed=%d expected=%d" !completed n));
  if !errors <> 0 then
    raise (Bench_invariant (Printf.sprintf "h1 protocol_errors=%d" !errors))

(* Run one h2c connection serving [k] streams from [src]; validate via stats. *)
let run_h2_conn ~clock ~src ~k =
  let completed = ref 0 in
  let errors = ref 0 in
  let resets = ref 0 in
  (Eio.Switch.run @@ fun sw ->
   let runtime_factory ~sw ~connection:_ () =
     Eta_eio.Runtime.create ~sw ~clock ()
   in
   Eta_http_eio.H2.Server_connection.run_h2c ~sw ~clock ~config
     ~flow:(make_mem_flow src)
     ~peer:(`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
     ~runtime_factory
     ~on_close:(fun (s : Eta_http_eio.H2.Server_connection.stats) ->
       completed := s.completed_streams;
       resets := s.reset_streams;
       errors := s.protocol_errors)
     handler);
  if !completed <> k then
    raise
      (Bench_invariant
         (Printf.sprintf "h2 conn completed=%d expected=%d resets=%d errors=%d"
            !completed k !resets !errors));
  if !resets <> 0 then
    raise (Bench_invariant (Printf.sprintf "h2 reset_streams=%d" !resets));
  if !errors <> 0 then
    raise (Bench_invariant (Printf.sprintf "h2 protocol_errors=%d" !errors))

(* Drive [n] total streams over ceil(n/window) connections. *)
let run_h2 ~clock ~full ~rem ~window ~conns =
  for _ = 1 to conns do
    run_h2_conn ~clock ~src:full ~k:window
  done;
  match rem with None -> () | Some (buf, k) -> run_h2_conn ~clock ~src:buf ~k

(* ------------------------------------------------------------------ *)
(* Measurement.                                                        *)
(* ------------------------------------------------------------------ *)

type sample = { rps : float; minor_per_req : float; major_per_req : float }

let measure ~run ~n : sample =
  Gc.compact ();
  let minor0 = Gc.minor_words () in
  let stat0 = Gc.quick_stat () in
  let t0 = Unix.gettimeofday () in
  run ();
  let t1 = Unix.gettimeofday () in
  let minor1 = Gc.minor_words () in
  let stat1 = Gc.quick_stat () in
  let wall = t1 -. t0 in
  {
    rps = float_of_int n /. wall;
    minor_per_req = (minor1 -. minor0) /. float_of_int n;
    major_per_req = (stat1.major_words -. stat0.major_words) /. float_of_int n;
  }

(* ------------------------------------------------------------------ *)
(* Stats helpers.                                                      *)
(* ------------------------------------------------------------------ *)

let median xs =
  match List.sort compare xs with
  | [] -> 0.0
  | sorted ->
      let arr = Array.of_list sorted in
      let len = Array.length arr in
      if len mod 2 = 1 then arr.(len / 2)
      else (arr.((len / 2) - 1) +. arr.(len / 2)) /. 2.0

let geomean xs =
  match xs with
  | [] -> 0.0
  | _ ->
      let sum_log = List.fold_left (fun acc x -> acc +. log x) 0.0 xs in
      exp (sum_log /. float_of_int (List.length xs))

let mean xs =
  match xs with
  | [] -> 0.0
  | _ -> List.fold_left ( +. ) 0.0 xs /. float_of_int (List.length xs)

let cv xs =
  match xs with
  | [] | [ _ ] -> 0.0
  | _ ->
      let m = mean xs in
      if m = 0.0 then 0.0
      else
        let n = float_of_int (List.length xs) in
        let var =
          List.fold_left (fun acc x -> acc +. ((x -. m) ** 2.0)) 0.0 xs /. n
        in
        sqrt var /. m

(* ------------------------------------------------------------------ *)
(* Driver loop over endpoints.                                         *)
(* ------------------------------------------------------------------ *)

let arg_int name default =
  let rec loop = function
    | a :: b :: _ when a = name -> int_of_string b
    | _ :: rest -> loop rest
    | [] -> default
  in
  loop (Array.to_list Sys.argv)

let arg_present name =
  let rec loop = function
    | a :: _ when a = name -> true
    | _ :: rest -> loop rest
    | [] -> false
  in
  loop (Array.to_list Sys.argv)

let run_proto ~proto ~make_run ~samples ~requests =
  List.map
    (fun ep ->
      let run = make_run ep requests in
      ignore (measure ~run ~n:requests) (* warmup *);
      let samples_list = List.init samples (fun _ -> measure ~run ~n:requests) in
      let rps = List.map (fun s -> s.rps) samples_list in
      let minor = List.map (fun s -> s.minor_per_req) samples_list in
      let major = List.map (fun s -> s.major_per_req) samples_list in
      let med_rps = median rps in
      let med_minor = median minor in
      let med_major = median major in
      Printf.printf "METRIC %s_%s_rps=%.0f\n" proto ep.name med_rps;
      Printf.printf "METRIC %s_%s_minor_words_per_req=%.2f\n" proto ep.name med_minor;
      Printf.printf "METRIC %s_%s_major_words_per_req=%.2f\n" proto ep.name med_major;
      Printf.eprintf "  %s %-10s rps=%-8.0f cv=%.1f%% minor/req=%-7.1f major/req=%.1f\n%!"
        proto ep.name med_rps (cv rps *. 100.0) med_minor med_major;
      (med_rps, med_minor, med_major))
    endpoints

let () =
  let quick = arg_present "--quick" in
  let samples = arg_int "--samples" (if quick then 1 else 9) in
  let requests = arg_int "--requests" (if quick then 1_000 else 40_000) in
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Printf.eprintf "== H1 ==\n%!";
  let h1 =
    run_proto ~proto:"h1" ~samples ~requests ~make_run:(fun ep n ->
        let src = repeat_string (h1_request ep) n in
        fun () -> run_h1 ~clock ~src ~n)
  in
  Printf.eprintf "== H2C ==\n%!";
  let h2 =
    run_proto ~proto:"h2" ~samples ~requests ~make_run:(fun ep n ->
        let block = h2_header_block ep in
        let window = min h2_window n in
        let full = h2_conn_buffer ep block window in
        let conns = n / window in
        let rem_k = n - (conns * window) in
        let rem =
          if rem_k > 0 then Some (h2_conn_buffer ep block rem_k, rem_k) else None
        in
        fun () -> run_h2 ~clock ~full ~rem ~window ~conns)
  in
  let rps_of = List.map (fun (r, _, _) -> r) in
  let minor_of = List.map (fun (_, m, _) -> m) in
  let h1_geo = geomean (rps_of h1) in
  let h2_geo = geomean (rps_of h2) in
  let all_geo = geomean (rps_of h1 @ rps_of h2) in
  Printf.printf "METRIC h1_rps_geomean=%.0f\n" h1_geo;
  Printf.printf "METRIC h2_rps_geomean=%.0f\n" h2_geo;
  Printf.printf "METRIC h1_minor_words_per_req=%.2f\n" (mean (minor_of h1));
  Printf.printf "METRIC h2_minor_words_per_req=%.2f\n" (mean (minor_of h2));
  Printf.printf "METRIC minor_words_per_req=%.2f\n" (mean (minor_of h1 @ minor_of h2));
  (* Primary metric: geomean rps across all H1 + H2 endpoints. *)
  Printf.printf "METRIC rps_geomean=%.0f\n" all_geo;
  Printf.eprintf "\nh1_geo=%.0f h2_geo=%.0f all_geo=%.0f\n%!" h1_geo h2_geo all_geo;
  Printf.printf "%!"
