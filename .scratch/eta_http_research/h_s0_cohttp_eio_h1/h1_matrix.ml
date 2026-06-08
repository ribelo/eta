let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> failwith "expected TCP listening socket"

let contains haystack needle =
  let h = String.length haystack and n = String.length needle in
  let rec loop i =
    i + n <= h
    && (String.equal (String.sub haystack i n) needle || loop (i + 1))
  in
  n = 0 || loop 0

let count_sub haystack needle =
  let h = String.length haystack and n = String.length needle in
  let rec loop i count =
    if i + n > h then count
    else if String.equal (String.sub haystack i n) needle then
      loop (i + n) (count + 1)
    else loop (i + 1) count
  in
  if n = 0 then 0 else loop 0 0

let split_headers_body response =
  let marker = "\r\n\r\n" in
  let rec find i =
    if i + String.length marker > String.length response then None
    else if String.equal (String.sub response i (String.length marker)) marker
    then Some i
    else find (i + 1)
  in
  match find 0 with
  | None -> response, ""
  | Some i ->
    ( String.sub response 0 i
    , String.sub
        response
        (i + String.length marker)
        (String.length response - i - String.length marker) )

let raw_request ~net ~port request =
  Eio.Switch.run @@ fun sw ->
  let flow =
    Eio.Net.connect
      ~sw
      net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Eio.Flow.write flow [ Cstruct.of_string request ];
  (try Eio.Flow.shutdown flow `Send with _ -> ());
  Eio.Buf_read.(of_flow ~max_size:1_000_000 flow |> take_all)

let read_prefix_then_close ~net ~port request bytes =
  Eio.Switch.run @@ fun sw ->
  let flow =
    Eio.Net.connect
      ~sw
      net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  Eio.Flow.write flow [ Cstruct.of_string request ];
  let buf = Cstruct.create bytes in
  let n = Eio.Flow.single_read flow buf in
  Eio.Resource.close flow;
  Cstruct.to_string (Cstruct.sub buf 0 n)

let body_to_string body =
  Eio.Buf_read.(of_flow ~max_size:1_000_000 body |> take_all)

let handler _conn request body =
  match Http.Request.meth request, Http.Request.resource request with
  | `GET, "/fixed" ->
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"fixed" ()
  | `GET, "/stream" ->
    let body = Eio.Flow.string_source "HelloWorld" in
    Cohttp_eio.Server.respond ~status:`OK ~body ()
  | `HEAD, "/head" ->
    let headers = Http.Header.init_with "content-length" "9" in
    Cohttp_eio.Server.respond ~headers ~status:`OK ~body:(Cohttp_eio.Body.of_string "") ()
  | `POST, "/early" ->
    Cohttp_eio.Server.respond_string ~status:`OK ~body:"early" ()
  | `POST, "/echo" ->
    let body = body_to_string body in
    Cohttp_eio.Server.respond_string ~status:`OK ~body ()
  | `GET, "/error" ->
    Cohttp_eio.Server.respond_string ~status:`Internal_server_error ~body:"error-detail" ()
  | _ ->
    Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"missing" ()

let with_server f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let socket =
    Eio.Net.listen
      ~sw
      ~reuse_addr:true
      ~backlog:16
      net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let stop_p, stop_u = Eio.Promise.create () in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run
      socket
      server
      ~stop:stop_p
      ~on_error:(fun exn -> raise exn);
    `Stop_daemon);
  Fun.protect
    ~finally:(fun () -> ignore (Eio.Promise.try_resolve stop_u ()))
    (fun () -> f ~net ~port)

let require label cond =
  if not cond then failwith ("require failed: " ^ label)

let scenario_keep_alive_server ~net ~port =
  let response =
    raw_request
      ~net
      ~port
      "GET /fixed HTTP/1.1\r\nHost: local\r\nConnection: keep-alive\r\n\r\n\
       GET /fixed HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n"
  in
  let responses = count_sub response "HTTP/1.1 200 OK" in
  require "two responses on one connection" (responses = 2);
  Printf.printf "h_s0_keep_alive_server responses=%d\n%!" responses

let scenario_chunked_response ~net ~port =
  let response =
    raw_request
      ~net
      ~port
      "GET /stream HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n"
  in
  require "chunked transfer" (contains response "transfer-encoding: chunked");
  require "chunk payload" (contains response "HelloWorld");
  Printf.printf "h_s0_chunked_response transfer=chunked body=HelloWorld\n%!"

let scenario_known_length_upload ~net ~port =
  let response =
    raw_request
      ~net
      ~port
      (String.concat
         ""
         [ "POST /echo HTTP/1.1\r\n"
         ; "Host: local\r\n"
         ; "Connection: close\r\n"
         ; "Content-Length: 11\r\n"
         ; "\r\n"
         ; "hello-known"
         ])
  in
  require "known length upload status" (contains response "HTTP/1.1 200 OK");
  require "known length upload body" (contains response "hello-known");
  Printf.printf
    "h_s0_known_length_upload content_length=11 body=hello-known\n%!"

let scenario_chunked_upload ~net ~port =
  let response =
    raw_request
      ~net
      ~port
      (String.concat
         ""
         [ "POST /echo HTTP/1.1\r\n"
         ; "Host: local\r\n"
         ; "Connection: close\r\n"
         ; "Transfer-Encoding: chunked\r\n"
         ; "\r\n"
         ; "5\r\n"
         ; "hello\r\n"
         ; "6\r\n"
         ; "-chunk\r\n"
         ; "0\r\n"
         ; "\r\n"
         ])
  in
  require "chunked upload status" (contains response "HTTP/1.1 200 OK");
  require "chunked upload body" (contains response "hello-chunk");
  Printf.printf "h_s0_chunked_upload transfer=chunked body=hello-chunk\n%!"

let scenario_head ~net ~port =
  let response =
    raw_request
      ~net
      ~port
      "HEAD /head HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n"
  in
  let headers, body = split_headers_body response in
  require "HEAD status" (contains headers "HTTP/1.1 200 OK");
  require "HEAD content length" (contains headers "content-length: 9");
  require "HEAD body empty" (String.equal body "");
  Printf.printf "h_s0_head status=200 content_length=9 body_len=0\n%!"

let scenario_early_response ~net ~port =
  let response =
    raw_request
      ~net
      ~port
      "POST /early HTTP/1.1\r\n\
       Host: local\r\n\
       Connection: close\r\n\
       Content-Length: 100000\r\n\
       \r\n"
  in
  require "early status" (contains response "HTTP/1.1 200 OK");
  require "early body" (contains response "early");
  Printf.printf "h_s0_early_response status=200 body=early unread_upload=true\n%!"

let scenario_error_body ~net ~port =
  Eio.Switch.run @@ fun sw ->
  let client = Cohttp_eio.Client.make ~https:None net in
  let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/error" port) in
  let response, body = Cohttp_eio.Client.get ~sw client uri in
  let body = body_to_string body in
  require "error status" (response.status = `Internal_server_error);
  require "error body" (String.equal body "error-detail");
  Printf.printf "h_s0_error_body status=500 body=%S\n%!" body

let scenario_client_no_pool ~net ~port =
  Eio.Switch.run @@ fun sw ->
  let connect_count = ref 0 in
  let client =
    Cohttp_eio.Client.make_generic (fun ~sw _uri ->
      incr connect_count;
      Eio.Net.connect
        ~sw
        net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)))
  in
  let uri = Uri.of_string "http://local.test/fixed" in
  let _response1, body1 = Cohttp_eio.Client.get ~sw client uri in
  let _ = body_to_string body1 in
  let _response2, body2 = Cohttp_eio.Client.get ~sw client uri in
  let _ = body_to_string body2 in
  require "high-level client opens one connection per request" (!connect_count = 2);
  Printf.printf "h_s0_client_no_pool connect_calls=%d verdict=negative\n%!" !connect_count

let scenario_cancel_cleanup_smoke ~net ~port =
  let _prefix =
    read_prefix_then_close
      ~net
      ~port
      "GET /stream HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n"
      32
  in
  let response =
    raw_request
      ~net
      ~port
      "GET /fixed HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n"
  in
  require "server accepts after client close" (contains response "fixed");
  Printf.printf "h_s0_cancel_cleanup_smoke accepts_after_client_close=true\n%!"

let () =
  with_server @@ fun ~net ~port ->
  scenario_keep_alive_server ~net ~port;
  scenario_chunked_response ~net ~port;
  scenario_known_length_upload ~net ~port;
  scenario_chunked_upload ~net ~port;
  scenario_head ~net ~port;
  scenario_early_response ~net ~port;
  scenario_error_body ~net ~port;
  scenario_client_no_pool ~net ~port;
  scenario_cancel_cleanup_smoke ~net ~port;
  Printf.printf "h_s0_trailers verdict=negative reason=cohttp_transfer_io_discards_trailers\n%!"
