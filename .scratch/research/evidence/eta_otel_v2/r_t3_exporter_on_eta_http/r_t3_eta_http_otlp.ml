let getenv name default =
  match Sys.getenv_opt name with Some value -> value | None -> default

let arg index default =
  if Array.length Sys.argv > index then Sys.argv.(index) else default

let otlp_retry_status = function 429 | 502 | 503 | 504 -> true | _ -> false

let hex32 i = Printf.sprintf "%032x" i
let hex16 i = Printf.sprintf "%016x" i

let make_span i : Eta_otel.Internal.span =
  let start_unix_ns = 1_700_000_000_000_000_000 + (i * 1_000_000) in
  {
    trace_id = hex32 (0x1000 + i);
    span_id = hex16 (0x2000 + i);
    parent_span_id = None;
    trace_flags = 1;
    trace_state = [];
    baggage = [];
    name = Printf.sprintf "r_t3.span.%04d" i;
    kind = Eta.Capabilities.Client;
    start_unix_ns;
    end_unix_ns = start_unix_ns + 500_000;
    attrs =
      [
        ("probe", "r_t3_exporter_on_eta_http");
        ("span.index", string_of_int i);
      ];
    events = [];
    links = [];
    status_code = 1;
    status_message = "";
  }

let make_payload count =
  let rec loop i acc =
    if i = 0 then acc else loop (i - 1) (make_span i :: acc)
  in
  Eta_otel.Internal.encode_traces_request
    ~resource_attrs:
      [
        ("service.name", "eta-r-t3");
        ("service.version", "research");
      ]
    ~scope_name:"eta.r_t3" (loop count [])

let run ~host ~port ~count =
  let uri = Printf.sprintf "http://%s:%d/v1/traces" host port in
  let body = make_payload count in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net stdenv in
  let clock = Eio.Stdenv.clock stdenv in
  let client = Eta_http_eio.Client.make_h1 ~sw ~net () in
  let tracer = Eta.Tracer.in_memory () in
  let rt =
    Eta_eio.Runtime.create ~sw ~clock ~tracer:(Eta.Tracer.as_capability tracer) ()
  in
  let request =
    Eta_http.Request.make "POST" uri
      ~headers:
        [
          ("content-type", "application/json");
          ("accept", "application/json");
        ]
      ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ])
  in
  let policy =
    Eta_http.Retry_policy.always ~max_attempts:3 ~retry_status:otlp_retry_status
      ()
  in
  let eff =
    Eta_http.Observability.Tracer.request_with_retry ~enabled:false ~policy client
      request
    |> Eta.Effect.bind (fun response ->
           Eta_http.Body.Stream.read_all response.body
           |> Eta.Effect.map (fun response_body ->
                  (response.Eta_http.Response.status, response_body)))
  in
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok (status, response_body) ->
      let eta_http_spans = Eta.Tracer.dump tracer in
      if eta_http_spans <> [] then (
        Format.eprintf "r_t3_eta_http_otlp unexpected_spans=%a@."
          (Format.pp_print_list
             ~pp_sep:(fun fmt () -> Format.fprintf fmt ", ")
             (fun fmt span -> Format.pp_print_string fmt span.Eta.Tracer.name))
          eta_http_spans;
        exit 3);
      let response_body = Bytes.to_string response_body in
      Printf.printf
        "r_t3_eta_http_otlp status=%d spans=%d body_bytes=%d eta_http_spans=%d\n%!"
        status count (String.length response_body) (List.length eta_http_spans);
      if status < 200 || status >= 300 then (
        prerr_endline response_body;
        exit 2)
  | Eta.Exit.Error cause ->
      Format.eprintf "r_t3_eta_http_otlp error=%a@."
        (Eta.Cause.pp Eta_http.Error.pp)
        cause;
      exit 1

let () =
  let host = arg 1 (getenv "OTEL_HOST" "127.0.0.1") in
  let port = int_of_string (arg 2 (getenv "OTEL_PORT" "4318")) in
  let count = int_of_string (arg 3 (getenv "OTEL_SPANS" "1000")) in
  run ~host ~port ~count
