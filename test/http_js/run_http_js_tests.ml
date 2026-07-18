module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

module E = Eta.Effect
module H = Eta_http

let fail name message = Eta_js_test.fail name message

let check name condition =
  if not condition then fail name "check failed"

let check_equal_int name expected actual =
  if expected <> actual then
    fail name (Printf.sprintf "expected %d, got %d" expected actual)

let check_equal_string name expected actual =
  if not (String.equal expected actual) then
    fail name (Printf.sprintf "expected %S, got %S" expected actual)

let check_equal_option_string name expected actual =
  if actual <> expected then
    fail name
      (Printf.sprintf "expected %s, got %s"
         (Option.value ~default:"<none>" expected)
         (Option.value ~default:"<none>" actual))

let pp_http_error fmt error = Format.pp_print_string fmt (H.Error.to_string error)

let pp_cause cause =
  Format.asprintf "%a" (Eta.Cause.pp pp_http_error) cause

let expect_ok name = function
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause -> fail name ("expected Ok, got " ^ pp_cause cause)

let expect_fail name pred = function
  | Eta.Exit.Error (Eta.Cause.Fail error) when pred error -> ()
  | Eta.Exit.Error cause ->
      fail name ("unexpected failure cause: " ^ pp_cause cause)
  | Eta.Exit.Ok _ -> fail name "expected typed failure, got Ok"

let expect_effect_error name pred = function
  | Error error when pred error -> ()
  | Error error -> fail name ("unexpected error: " ^ H.Error.to_string error)
  | Ok _ -> fail name "expected Error, got Ok"

let kind pred error = pred error.H.Error.kind

let is_host_api_unavailable api = function
  | H.Error.Host_api_unavailable { api = actual; _ } -> String.equal api actual
  | _ -> false

let is_host_api_error api = function
  | H.Error.Host_api_error { api = actual; _ } -> String.equal api actual
  | _ -> false

let is_host_policy policy = function
  | H.Error.Host_policy_error { policy = actual; _ } ->
      String.equal policy actual
  | _ -> false

let is_unsupported feature = function
  | H.Error.Unsupported_adapter_feature { feature = actual; _ } ->
      String.equal feature actual
  | _ -> false

let is_protocol_violation kind = function
  | H.Error.Connection_protocol_violation { kind = actual; _ } ->
      String.equal kind actual
  | _ -> false

let is_request_body_too_large = function
  | H.Error.Request_body_too_large _ -> true
  | _ -> false

let is_body_too_large = function
  | H.Error.Body_too_large _ -> true
  | _ -> false

let bytes value = Bytes.of_string value

let read_response client request =
  H.Client.request client request
  |> E.bind (fun response ->
         H.Body.Stream.read_all response.H.Response.body
         |> E.map (fun body ->
                  ( response.H.Response.status,
                  response.H.Response.headers,
                  Bytes.to_string body )))

let capture eff = E.to_result eff

let run_eta ?services ?(finally = fun () -> ()) eff done_ check_result =
  let runtime = Eta_jsoo.Runtime.create ?services () in
  Eta_jsoo.Runtime.run runtime eff ~on_result:(fun result ->
      finally ();
      Eta_js_test.finish done_ (fun () -> check_result result))

let install_global name value =
  let previous = Unsafe.get Unsafe.global name in
  Unsafe.set Unsafe.global name value;
  fun () -> Unsafe.set Unsafe.global name previous

let js_get_string object_ name =
  Js.to_string
    (Unsafe.fun_call
       (Unsafe.js_expr "(function(value) { return String(value); })")
       [| Unsafe.inject (Unsafe.get object_ name) |])

let js_get_bool object_ name =
  Js.to_bool (Unsafe.get object_ name)

let js_get_int object_ name = Unsafe.get object_ name

let start_server on_ready =
  let start =
    Unsafe.js_expr
      {|
      (function(cb) {
        const http = require("node:http");
        const server = http.createServer((req, res) => {
          const chunks = [];
          req.on("data", chunk => chunks.push(chunk));
          req.on("end", () => {
            if (req.url === "/hello") {
              res.writeHead(201, { "x-eta-test": "hello" });
              res.end("hello");
            } else if (req.url === "/echo") {
              const body = Buffer.concat(chunks);
              res.writeHead(200, {
                "x-eta-method": req.method,
                "content-type": "application/octet-stream"
              });
              res.end(body);
            } else if (req.url === "/redirect") {
              res.writeHead(302, { "location": "/hello" });
              res.end("redirect");
            } else if (req.url === "/hang") {
              /* Intentionally keep the response open. */
            } else {
              res.writeHead(404);
              res.end("not found");
            }
          });
        });
        server.listen(0, "127.0.0.1", () => {
          cb(server, "http://127.0.0.1:" + server.address().port);
        });
      })
    |}
  in
  ignore
    (Unsafe.fun_call start
       [|
         Unsafe.inject
           (Js.wrap_callback (fun server url ->
                on_ready server (Js.to_string url)));
       |])

let close_server server =
  ignore (Unsafe.meth_call server "close" [||])

let test_local_server_runtime_service done_ =
  start_server @@ fun server base_url ->
  let service = Eta_http_js.runtime_service () in
  let client = H.Client.make_runtime () in
  let get_request = H.Request.make "GET" (base_url ^ "/hello") in
  let post_request =
    H.Request.make ~body:(Fixed [ bytes "payload" ]) "POST"
      (base_url ^ "/echo")
  in
  let redirect_request = H.Request.make "GET" (base_url ^ "/redirect") in
  let eff =
    read_response client get_request
    |> E.bind (fun get_result ->
           read_response client post_request
           |> E.bind (fun post_result ->
                  read_response client redirect_request
                  |> E.bind (fun redirect_result ->
                         H.Client.stats client
                         |> E.map (fun stats ->
                                ( get_result,
                                  post_result,
                                  redirect_result,
                                  stats )))))
  in
  run_eta ~services:[ service ] ~finally:(fun () -> close_server server) eff
    done_ (fun result ->
      let (get_result, post_result, redirect_result, stats) =
        expect_ok "local server" result
      in
      let status, headers, body = get_result in
      check_equal_int "local GET status" 201 status;
      check_equal_option_string "local GET header" (Some "hello")
        (H.Core.Header.get "x-eta-test" headers);
      check_equal_string "local GET body" "hello" body;
      let status, headers, body = post_result in
      check_equal_int "local POST status" 200 status;
      check_equal_option_string "local POST method" (Some "POST")
        (H.Core.Header.get "x-eta-method" headers);
      check_equal_string "local POST body" "payload" body;
      let status, headers, body = redirect_result in
      check_equal_int "local redirect status" 302 status;
      check_equal_option_string "local redirect location" (Some "/hello")
        (H.Core.Header.get "location" headers);
      check_equal_string "local redirect body" "redirect" body;
      check "local stats none" (Option.is_none stats))

let install_options_fetch state =
  let factory =
    Unsafe.js_expr
      {|
      (function(state) {
        return function(url, init) {
          state.url = String(url);
          state.method = init.method;
          state.mode = init.mode;
          state.redirect = init.redirect;
          state.credentials = init.credentials;
          state.referrerPolicy = init.referrerPolicy;
          state.cache = init.cache;
          state.bodyLength = init.body ? init.body.length : 0;
          const chunks = [new Uint8Array([97, 98]), new Uint8Array([99])];
          const reader = {
            read: function() {
              if (chunks.length === 0) return Promise.resolve({ done: true });
              return Promise.resolve({ done: false, value: chunks.shift() });
            },
            cancel: function() {
              state.cancelled = true;
              return Promise.resolve();
            },
            releaseLock: function() { state.released = true; }
          };
          return Promise.resolve({
            type: "basic",
            status: 202,
            headers: {
              forEach: function(cb) { cb("yes", "x-fetch-test"); }
            },
            body: {
              getReader: function() {
                state.reader = true;
                return reader;
              }
            },
            arrayBuffer: function() {
              state.arrayBuffer = true;
              return Promise.resolve(new Uint8Array([120]).buffer);
            }
          });
        };
      })
    |}
  in
  install_global "fetch" (Unsafe.fun_call factory [| Unsafe.inject state |])

let test_fake_fetch_options_and_stream done_ =
  let state = Unsafe.obj [||] in
  let restore = install_options_fetch state in
  let client = Eta_http_js.Client.make () in
  let request =
    H.Request.make ~headers:[ ("x-one", "1") ]
      ~body:(Fixed [ bytes "abcd" ])
      "POST" "https://example.test/stream"
  in
  let eff =
    read_response client request
    |> E.bind (fun result ->
           H.Client.stats client |> E.map (fun stats -> (result, stats)))
  in
  run_eta ~finally:restore eff done_ (fun result ->
      let (status, headers, body), stats =
        expect_ok "fake options stream" result
      in
      check_equal_int "fake status" 202 status;
      check_equal_option_string "fake response header" (Some "yes")
        (H.Core.Header.get "x-fetch-test" headers);
      check_equal_string "fake streamed body" "abc" body;
      check_equal_string "fetch method" "POST" (js_get_string state "method");
      check_equal_string "fetch mode" "cors" (js_get_string state "mode");
      check_equal_string "fetch redirect" "manual"
        (js_get_string state "redirect");
      check_equal_string "fetch credentials" "omit"
        (js_get_string state "credentials");
      check_equal_string "fetch referrerPolicy" "no-referrer"
        (js_get_string state "referrerPolicy");
      check_equal_string "fetch cache" "no-store"
        (js_get_string state "cache");
      check_equal_int "fetch body length" 4 (js_get_int state "bodyLength");
      check "fetch used reader" (js_get_bool state "reader");
      check "fetch did not fallback arrayBuffer"
        (not (js_get_bool state "arrayBuffer"));
      check "fetch stats none" (Option.is_none stats))

let install_upload_fetch state =
  let factory =
    Unsafe.js_expr
      {|
      (function(state) {
        return function(_url, init) {
          state.bodyLength = init.body ? init.body.length : 0;
          return Promise.resolve({
            type: "basic",
            status: 200,
            headers: { forEach: function(_cb) {} },
            body: null,
            arrayBuffer: function() {
              return Promise.resolve(new Uint8Array([]).buffer);
            }
          });
        };
      })
    |}
  in
  install_global "fetch" (Unsafe.fun_call factory [| Unsafe.inject state |])

let test_rewindable_upload_cap done_ =
  let state = Unsafe.obj [||] in
  let restore = install_upload_fetch state in
  let success_client = Eta_http_js.Client.make () in
  let capped_client =
    Eta_http_js.Client.make ~max_buffered_request_body_bytes:2 ()
  in
  let rewindable =
    H.Request.Rewindable_stream
      {
        length = Some 3;
        make = (fun () -> H.Body.Stream.of_bytes [ bytes "abc" ]);
      }
  in
  let success =
    H.Client.request success_client
      (H.Request.make ~body:rewindable "POST" "https://example.test/upload")
  in
  let failure =
    capture
      (H.Client.request capped_client
         (H.Request.make ~body:rewindable "POST" "https://example.test/upload"))
  in
  let eff =
    success
    |> E.bind (fun _response -> failure)
  in
  run_eta ~finally:restore eff done_ (fun result ->
      let failure = expect_ok "rewindable upload cap" result in
      check_equal_int "rewindable uploaded length" 3
        (js_get_int state "bodyLength");
      expect_effect_error "rewindable cap"
        (kind is_request_body_too_large)
        failure)

let install_never_fetch state =
  let factory =
    Unsafe.js_expr
      {|
      (function(state) {
        return function(_url, init) {
          state.signal = init.signal;
          return new Promise(function(_resolve, _reject) {});
        };
      })
    |}
  in
  install_global "fetch" (Unsafe.fun_call factory [| Unsafe.inject state |])

let test_cancellation_aborts_fetch done_ =
  let state = Unsafe.obj [||] in
  let restore = install_never_fetch state in
  let client = Eta_http_js.Client.make () in
  let request = H.Request.make "GET" "https://example.test/hang" in
  let eff =
    H.Client.request client request
    |> E.map_error (fun error -> `Http error)
    |> E.timeout_as (Eta.Duration.ms 5) ~on_timeout:`Timeout
  in
  run_eta ~finally:restore eff done_ (fun result ->
      (match result with
      | Eta.Exit.Error (Eta.Cause.Fail `Timeout) -> ()
      | Eta.Exit.Error cause ->
          fail "abort" ("expected timeout, got " ^ Format.asprintf "%a" (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>")) cause)
      | Eta.Exit.Ok _ -> fail "abort" "expected timeout");
      let signal = Unsafe.get state "signal" in
      check "abort signal" (js_get_bool signal "aborted"))

let test_validation_failures done_ =
  let client = Eta_http_js.Client.make () in
  let stream_body = H.Body.Stream.of_bytes [ bytes "x" ] in
  let cases =
    [
      ( "duplicate header",
        H.Request.make ~headers:[ ("x-one", "1"); ("X-One", "2") ] "GET"
          "https://example.test/",
        kind (is_host_policy "duplicate-request-header") );
      ( "forbidden header",
        H.Request.make ~headers:[ ("Content-Length", "1") ] "GET"
          "https://example.test/",
        kind (is_host_policy "fetch-forbidden-header") );
      ( "forbidden method",
        H.Request.make "CONNECT" "https://example.test/",
        kind (is_host_policy "fetch-forbidden-method") );
      ( "get body",
        H.Request.make ~body:(Fixed [ bytes "x" ]) "GET"
          "https://example.test/",
        kind (is_protocol_violation "request_body") );
      ( "stream body",
        H.Request.make ~body:(Stream stream_body) "POST"
          "https://example.test/",
        kind (is_unsupported "request_body_stream") );
      ( "relative url",
        H.Request.make "GET" "/relative",
        kind (is_protocol_violation "url") );
      ( "invalid method",
        H.Request.make "BAD METHOD" "https://example.test/",
        kind (is_protocol_violation "method") );
    ]
  in
  let eff =
    E.all
      (List.map
         (fun (_, request, _) -> capture (H.Client.request client request))
         cases)
  in
  run_eta eff done_ (fun result ->
      let results = expect_ok "validation failures" result in
      List.iter2
        (fun (name, _, pred) result -> expect_effect_error name pred result)
        cases results)

let test_runtime_unsupported_options done_ =
  let service = Eta_http_js.runtime_service () in
  let protocol_client = H.Client.make_runtime ~protocol:H.Client.H1 () in
  let ca_client = H.Client.make_runtime ~ca_file:"ca.pem" () in
  let request = H.Request.make "GET" "https://example.test/" in
  let eff =
    E.all
      [
        capture (H.Client.request protocol_client request);
        capture (H.Client.request ca_client request);
      ]
  in
  run_eta ~services:[ service ] eff done_ (fun result ->
      match expect_ok "runtime unsupported" result with
      | [ protocol; ca_file ] ->
          expect_effect_error "forced protocol" (kind (is_unsupported "protocol"))
            protocol;
          expect_effect_error "ca_file" (kind (is_unsupported "ca_file")) ca_file
      | _ -> fail "runtime unsupported" "unexpected result count")

let test_missing_host_apis done_ =
  let undefined = Unsafe.js_expr "undefined" in
  let client = Eta_http_js.Client.make () in
  let request = H.Request.make "GET" "https://example.test/" in
  let previous_fetch = Unsafe.get Unsafe.global "fetch" in
  let previous_abort_controller = Unsafe.get Unsafe.global "AbortController" in
  let missing_fetch =
    Unsafe.set Unsafe.global "fetch" undefined;
    capture (H.Client.request client request)
  in
  let missing_abort_controller =
    E.sync (fun () ->
        Unsafe.set Unsafe.global "fetch" previous_fetch;
        Unsafe.set Unsafe.global "AbortController" undefined)
    |> E.bind (fun () -> capture (H.Client.request client request))
  in
  let restore () =
    Unsafe.set Unsafe.global "fetch" previous_fetch;
    Unsafe.set Unsafe.global "AbortController" previous_abort_controller
  in
  let eff =
    missing_fetch
    |> E.bind (fun fetch_error ->
           missing_abort_controller
           |> E.map (fun abort_error -> (fetch_error, abort_error)))
  in
  run_eta ~finally:restore eff done_ (fun result ->
      let fetch_error, abort_error = expect_ok "missing host APIs" result in
      expect_effect_error "missing fetch"
        (kind (is_host_api_unavailable "fetch"))
        fetch_error;
      expect_effect_error "missing AbortController"
        (kind (is_host_api_unavailable "AbortController"))
        abort_error)

let install_read_error_fetch state =
  let factory =
    Unsafe.js_expr
      {|
      (function(state) {
        return function(_url, _init) {
          const reader = {
            read: function() { return Promise.reject(new Error("read boom")); },
            cancel: function() { state.cancelled = true; return Promise.resolve(); },
            releaseLock: function() { state.released = true; }
          };
          return Promise.resolve({
            type: "basic",
            status: 200,
            headers: { forEach: function(_cb) {} },
            body: { getReader: function() { return reader; } },
            arrayBuffer: function() {
              return Promise.resolve(new Uint8Array([]).buffer);
            }
          });
        };
      })
    |}
  in
  install_global "fetch" (Unsafe.fun_call factory [| Unsafe.inject state |])

let test_read_error_maps_to_host_api_error done_ =
  let state = Unsafe.obj [||] in
  let restore = install_read_error_fetch state in
  let client = Eta_http_js.Client.make () in
  let eff =
    H.Client.request client (H.Request.make "GET" "https://example.test/read")
    |> E.bind (fun response ->
           capture (H.Body.Stream.read_all response.H.Response.body))
  in
  run_eta ~finally:restore eff done_ (fun result ->
      let read_result = expect_ok "read error" result in
      expect_effect_error "read error"
        (kind (is_host_api_error "ReadableStreamDefaultReader.read"))
        read_result)

let install_array_buffer_fetch state =
  let factory =
    Unsafe.js_expr
      {|
      (function(state) {
        return function(_url, _init) {
          return Promise.resolve({
            type: "basic",
            status: 206,
            headers: {
              forEach: function(cb) { cb("bytes", "x-body-source"); }
            },
            body: {},
            arrayBuffer: function() {
              state.arrayBufferCalls = (state.arrayBufferCalls || 0) + 1;
              return Promise.resolve(new Uint8Array([120, 121]).buffer);
            }
          });
        };
      })
    |}
  in
  install_global "fetch" (Unsafe.fun_call factory [| Unsafe.inject state |])

let test_array_buffer_fallback_and_cap done_ =
  let state = Unsafe.obj [||] in
  let restore = install_array_buffer_fetch state in
  let success_client = Eta_http_js.Client.make () in
  let capped_client = Eta_http_js.Client.make ~max_response_body_bytes:1 () in
  let request = H.Request.make "GET" "https://example.test/array-buffer" in
  let eff =
    read_response success_client request
    |> E.bind (fun success ->
           capture
             (H.Client.request capped_client request
             |> E.bind (fun response ->
                    H.Body.Stream.read_all response.H.Response.body))
           |> E.map (fun capped -> (success, capped)))
  in
  run_eta ~finally:restore eff done_ (fun result ->
      let (status, headers, body), capped =
        expect_ok "arrayBuffer fallback" result
      in
      check_equal_int "arrayBuffer status" 206 status;
      check_equal_option_string "arrayBuffer header" (Some "bytes")
        (H.Core.Header.get "x-body-source" headers);
      check_equal_string "arrayBuffer body" "xy" body;
      check_equal_int "arrayBuffer call count" 2
        (js_get_int state "arrayBufferCalls");
      expect_effect_error "arrayBuffer cap" (kind is_body_too_large) capped)

let install_opaque_fetch response_type status =
  let factory =
    Unsafe.js_expr
      {|
      (function(responseType, status) {
        return function(_url, _init) {
          return Promise.resolve({
            type: responseType,
            status: status,
            headers: { forEach: function(_cb) {} },
            body: null,
            arrayBuffer: function() {
              return Promise.resolve(new Uint8Array([]).buffer);
            }
          });
        };
      })
    |}
  in
  install_global "fetch"
    (Unsafe.fun_call factory
       [|
         Unsafe.inject (Js.string response_type);
         Unsafe.inject status;
       |])

let test_opaque_fetch_response_fails done_ =
  let restore = install_opaque_fetch "opaqueredirect" 0 in
  let client = Eta_http_js.Client.make () in
  let eff =
    capture
      (H.Client.request client
         (H.Request.make "GET" "https://example.test/redirect"))
  in
  run_eta ~finally:restore eff done_ (fun result ->
      let response_result = expect_ok "opaque response" result in
      expect_effect_error "opaque response"
        (kind (is_host_policy "opaque-fetch-response"))
        response_result)

let install_discard_fetch state =
  let factory =
    Unsafe.js_expr
      {|
      (function(state) {
        return function(_url, _init) {
          const reader = {
            read: function() { return new Promise(function(_resolve) {}); },
            cancel: function() {
              state.cancelled = true;
              return Promise.resolve();
            },
            releaseLock: function() { state.released = true; }
          };
          return Promise.resolve({
            type: "basic",
            status: 200,
            headers: { forEach: function(_cb) {} },
            body: { getReader: function() { return reader; } },
            arrayBuffer: function() {
              return Promise.resolve(new Uint8Array([]).buffer);
            }
          });
        };
      })
    |}
  in
  install_global "fetch" (Unsafe.fun_call factory [| Unsafe.inject state |])

let test_discard_cancels_reader done_ =
  let state = Unsafe.obj [||] in
  let restore = install_discard_fetch state in
  let client = Eta_http_js.Client.make () in
  let eff =
    H.Client.request client (H.Request.make "GET" "https://example.test/discard")
    |> E.bind (fun response -> H.Body.Stream.discard response.H.Response.body)
  in
  run_eta ~finally:restore eff done_ (fun result ->
      ignore (expect_ok "discard" result);
      check "discard cancelled reader" (js_get_bool state "cancelled"))

let install_large_fetch state =
  let factory =
    Unsafe.js_expr
      {|
      (function(state) {
        return function(_url, _init) {
          const chunks = [new Uint8Array([1, 2, 3])];
          const reader = {
            read: function() {
              if (chunks.length === 0) return Promise.resolve({ done: true });
              return Promise.resolve({ done: false, value: chunks.shift() });
            },
            cancel: function() {
              state.cancelled = true;
              return Promise.resolve();
            },
            releaseLock: function() { state.released = true; }
          };
          return Promise.resolve({
            type: "basic",
            status: 200,
            headers: { forEach: function(_cb) {} },
            body: { getReader: function() { return reader; } },
            arrayBuffer: function() {
              return Promise.resolve(new Uint8Array([1, 2, 3]).buffer);
            }
          });
        };
      })
    |}
  in
  install_global "fetch" (Unsafe.fun_call factory [| Unsafe.inject state |])

let test_response_cap_cancels_reader done_ =
  let state = Unsafe.obj [||] in
  let restore = install_large_fetch state in
  let client = Eta_http_js.Client.make ~max_response_body_bytes:2 () in
  let eff =
    H.Client.request client (H.Request.make "GET" "https://example.test/large")
    |> E.bind (fun response ->
           capture (H.Body.Stream.read_all response.H.Response.body))
  in
  run_eta ~finally:restore eff done_ (fun result ->
      let body_result = expect_ok "response cap" result in
      expect_effect_error "response cap" (kind is_body_too_large) body_result;
      check "response cap cancelled reader" (js_get_bool state "cancelled"))

let tests =
  [
    ("local server runtime service", test_local_server_runtime_service);
    ("fake fetch options and stream", test_fake_fetch_options_and_stream);
    ("rewindable upload cap", test_rewindable_upload_cap);
    ("cancellation aborts fetch", test_cancellation_aborts_fetch);
    ("validation failures", test_validation_failures);
    ("runtime unsupported options", test_runtime_unsupported_options);
    ("missing host APIs", test_missing_host_apis);
    ("read error maps to host API error", test_read_error_maps_to_host_api_error);
    ("arrayBuffer fallback and cap", test_array_buffer_fallback_and_cap);
    ("opaque fetch response fails", test_opaque_fetch_response_fails);
    ("discard cancels reader", test_discard_cancels_reader);
    ("response cap cancels reader", test_response_cap_cancels_reader);
  ]

let () = Eta_js_test.main tests
