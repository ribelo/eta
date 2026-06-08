module Body_stream = Http.Body.Stream
module Chunked = Http.Body.Chunked
module Transducer = Http.Body.Transducer

let total_bytes = 100 * 1024 * 1024
let chunk_size = 64 * 1024
let rss_limit_kib = 128 * 1024

type rss = {
  baseline_kib : int;
  mutable max_kib : int;
}

let rss_kib () =
  let ic = open_in "/proc/self/status" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let rec loop () =
        match input_line ic with
        | line when String.length line >= 6 && String.sub line 0 6 = "VmRSS:" ->
            Scanf.sscanf line "VmRSS: %d kB" Fun.id
        | _ -> loop ()
        | exception End_of_file -> 0
      in
      loop ())

let make_rss () =
  let baseline_kib = rss_kib () in
  { baseline_kib; max_kib = baseline_kib }

let sample rss =
  let current = rss_kib () in
  if current > rss.max_kib then rss.max_kib <- current

let generated_stream total =
  let remaining = ref total in
  Body_stream.of_reader (fun () ->
      if !remaining = 0 then Eta.Effect.pure Body_stream.End
      else
        let len = min chunk_size !remaining in
        remaining := !remaining - len;
        let chunk = Bytes.make len 'x' in
        Eta.Effect.pure
          (if !remaining = 0 then Body_stream.Last chunk
           else Body_stream.Chunk chunk))

let run_or_fail rt label effect =
  match Eta.Runtime.run rt effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "%s: %a" label
           (Eta.Cause.pp Http.Error.pp)
           cause)

let rec count_stream rss stream total =
  sample rss;
  Body_stream.read stream
  |> Eta.Effect.bind (function
       | None -> Eta.Effect.pure total
       | Some chunk ->
           count_stream rss stream (total + Bytes.length chunk))

let write_bytes flow bytes =
  Eta.Effect.sync (fun () ->
      Eio.Flow.copy_string (Bytes.unsafe_to_string bytes) flow)

let rec write_all flow = function
  | [] -> Eta.Effect.unit
  | chunk :: rest ->
      write_bytes flow chunk
      |> Eta.Effect.bind (fun () -> write_all flow rest)

let rec write_chunked_stream rss flow stream =
  sample rss;
  Body_stream.read stream
  |> Eta.Effect.bind (function
       | None -> write_bytes flow (Chunked.encode_last_chunk ())
       | Some chunk ->
           write_all flow (Chunked.encode_chunk chunk)
           |> Eta.Effect.bind (fun () -> write_chunked_stream rss flow stream))

let make_error message =
  Http.Error.make ~protocol:H1 ~method_:"POST" ~uri:"/rss"
    (Decode_error { codec = "s3-gzip-rss"; message })

let read_exact_blocking flow len =
  let out = Bytes.create len in
  let rec loop off =
    if off = len then out
    else
      let scratch = Cstruct.create (len - off) in
      let got = Eio.Flow.single_read flow scratch in
      Cstruct.blit_to_bytes scratch 0 out off got;
      loop (off + got)
  in
  loop 0

let read_char flow =
  Bytes.get (read_exact_blocking flow 1) 0

let read_headers flow =
  let buffer = Buffer.create 512 in
  let rec loop () =
    let c = read_char flow in
    Buffer.add_char buffer c;
    let len = Buffer.length buffer in
    if
      len >= 4
      && String.equal
           (String.sub (Buffer.contents buffer) (len - 4) 4)
           "\r\n\r\n"
    then Buffer.contents buffer
    else loop ()
  in
  loop ()

let chunked_reader flow =
  let read_exact len =
    Eta.Effect.sync (fun () ->
        try Ok (read_exact_blocking flow len)
        with exn -> Error (Printexc.to_string exn))
    |> Eta.Effect.bind (function
         | Ok bytes -> Eta.Effect.pure bytes
         | Error message -> Eta.Effect.fail (make_error message))
  in
  let read_line ~limit =
    Eta.Effect.sync (fun () ->
        try
          let buffer = Buffer.create 32 in
          let rec loop seen =
            if seen > limit then Error "chunk line exceeded limit"
            else
              match read_char flow with
              | '\r' -> (
                  match read_char flow with
                  | '\n' -> Ok (Buffer.contents buffer)
                  | c ->
                      Buffer.add_char buffer '\r';
                      Buffer.add_char buffer c;
                      loop (seen + 2))
              | c ->
                  Buffer.add_char buffer c;
                  loop (seen + 1)
          in
          loop 0
        with exn -> Error (Printexc.to_string exn))
    |> Eta.Effect.bind (function
         | Ok line -> Eta.Effect.pure line
         | Error message -> Eta.Effect.fail (make_error message))
  in
  { Chunked.read_exact; read_line }

let chunked_body_stream decoder =
  Body_stream.of_reader (fun () ->
      Chunked.read decoder
      |> Eta.Effect.map (function
           | None -> Body_stream.End
           | Some chunk -> Body_stream.Chunk chunk))

let handle_connection rt rss flow =
  let headers = read_headers flow in
  if not (String.contains headers 'P') then failwith "server did not receive POST";
  let context =
    { Chunked.protocol = H1; method_ = "POST"; uri = "/rss" }
  in
  let decoder = Chunked.create ~context ~reader:(chunked_reader flow) () in
  let request_body =
    chunked_body_stream decoder |> Transducer.gzip_decode
  in
  let request_bytes =
    run_or_fail rt "server request decode" (count_stream rss request_body 0)
  in
  Eio.Flow.copy_string
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Encoding: gzip\r\n\r\n"
    flow;
  let response_body = generated_stream total_bytes |> Transducer.gzip_encode in
  run_or_fail rt "server response write"
    (write_chunked_stream rss flow response_body);
  Eio.Flow.shutdown flow `Send;
  request_bytes

let authenticator () =
  match Ca_certs.authenticator () with
  | Ok authenticator -> authenticator
  | Error (`Msg msg) -> failwith msg

let run env =
  Eio.Switch.run @@ fun sw ->
  let rss = make_rss () in
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~reuse_port:false ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port =
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> port
    | `Unix _ -> failwith "unexpected unix socket"
  in
  let server_done, server_resolver = Eio.Promise.create () in
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  Eio.Fiber.fork ~sw (fun () ->
      let result =
        try
          Eio.Switch.run @@ fun conn_sw ->
          let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
          Ok (handle_connection rt rss flow)
        with exn -> Error (Printexc.to_string exn)
      in
      Eio.Promise.resolve server_resolver result);
  let client =
    Http.Client.make_h1 ~sw ~net ~authenticator:(authenticator ()) ()
  in
  let url = Printf.sprintf "http://127.0.0.1:%d/rss" port in
  let request_body = generated_stream total_bytes |> Transducer.gzip_encode in
  let request =
    Http.Request.make ~headers:[ "Content-Encoding", "gzip" ]
      ~body:(Http.Request.Stream request_body)
      "POST" url
  in
  let response =
    run_or_fail rt "client request" (Http.request client request)
  in
  if response.status <> 200 then
    failwith (Printf.sprintf "expected status 200, got %d" response.status);
  let response_body = Transducer.gzip_decode response.body in
  let response_bytes =
    run_or_fail rt "client response decode" (count_stream rss response_body 0)
  in
  let request_bytes =
    match Eio.Promise.await server_done with
    | Ok bytes -> bytes
    | Error message -> failwith message
  in
  let delta_kib = rss.max_kib - rss.baseline_kib in
  Printf.printf
    "eta_http_s3_gzip_rss outcome=ok request_bytes=%d response_bytes=%d baseline_rss_kib=%d max_rss_kib=%d delta_rss_kib=%d limit_kib=%d\n%!"
    request_bytes response_bytes rss.baseline_kib rss.max_kib delta_kib
    rss_limit_kib;
  if request_bytes <> total_bytes || response_bytes <> total_bytes then exit 1;
  if delta_kib > rss_limit_kib then exit 1

let () = Eio_main.run run
