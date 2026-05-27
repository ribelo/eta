# Dependency Usage Audit

Run: bash lib/otel/audit/run.sh
Last updated: 2026-05-24T01:17:10Z
Current sites: 134

Every eta-otel call site for package-boundary or external dependencies is
listed by the generated matches below. The catalog is not a gate; it is the
truth-of-record for where eta-otel reaches outside Eta core.

Search:

    rg -n -t ocaml 'Eta_http\.|Eta_stream\.|Eio\.|Yojson\.' lib/otel

## Classification

| Dependency | Sites | Classification | Why it stays |
| --- | --- | --- | --- |
| eta-http | eta_otel.ml transport and client lifecycle | structural | OTLP/HTTP export must dogfood eta-http. Retry, body draining, response status handling, and recursion suppression all belong at this package boundary. |
| eta-stream | eta_otel.ml stream/mailbox/drain aliases and drain runner | structural | Bounded signal queues, batching, merge, and drain are the core Eta primitive shape for exporter pipelines. |
| Eio | public constructor capabilities, clock reads, and test harnesses | structural | Applications own switch/net/clock authority. eta-otel stores only the capabilities needed to build eta-http clients and timestamp spans. Tests use Eio to stand up deterministic loopback fixtures. |
| Yojson | OTLP/JSON encoders and JSON assertions in tests | structural | OTLP/JSON is the chosen wire format for this package slice. Removing Yojson requires replacing the JSON codec across all signal encoders. |

## Current Matches

<!-- BEGIN DEP_MATCHES -->
- test/otel/test_logger.ml:18:  Eio.Switch.run @@ fun sw ->
- test/otel/test_logger.ml:22:      ~clock:(Eio.Stdenv.clock stdenv)
- test/otel/test_logger.ml:29:  Eio.Switch.run @@ fun sw ->
- test/otel/test_logger.ml:34:      ~clock:(Eio.Stdenv.clock stdenv)
- test/otel/test_logger.ml:90:  Eio.Switch.run @@ fun sw ->
- test/otel/test_logger.ml:93:    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
- test/otel/test_logger.ml:106:    Eio.Switch.run @@ fun sw ->
- test/otel/test_logger.ml:107:    let net = Eio.Stdenv.net stdenv in
- test/otel/test_logger.ml:108:    Eio.Net.with_tcp_connect ~host:"127.0.0.1" ~service:"27686" net (fun _ ->
- test/otel/test_logger.ml:119:    Eio.Switch.run @@ fun sw ->
- test/otel/test_logger.ml:120:    let net = Eio.Stdenv.net stdenv in
- test/otel/test_logger.ml:121:    let clock = Eio.Stdenv.clock stdenv in
- lib/otel/eta_otel.ml:13:module Eta_stream = Eta_stream.Stream
- lib/otel/eta_otel.ml:14:module Mailbox = Eta_stream.Mailbox
- lib/otel/eta_otel.ml:15:module Drain_counter = Eta_stream.Drain_counter
- lib/otel/eta_otel.ml:35:type yj = Yojson.Safe.t
- lib/otel/eta_otel.ml:194:  Yojson.Safe.to_string payload
- lib/otel/eta_otel.ml:258:  Yojson.Safe.to_string payload
- lib/otel/eta_otel.ml:411:  Yojson.Safe.to_string payload
- lib/otel/eta_otel.ml:422:  Eta_http.Retry_policy.always ~max_attempts:3
- lib/otel/eta_otel.ml:426:  Eta_http.Core.Header.of_list
- lib/otel/eta_otel.ml:433:  Eta_http.Request.make ~headers:otlp_headers
- lib/otel/eta_otel.ml:434:    ~body:(Eta_http.Request.Fixed [ Bytes.of_string body ])
- lib/otel/eta_otel.ml:447:  http_client : Eta_http.Client.t;
- lib/otel/eta_otel.ml:448:  clock : float Eio.Time.clock_ty Eio.Std.r;
- lib/otel/eta_otel.ml:465:  let secs = Eio.Time.now t.clock in
- lib/otel/eta_otel.ml:469:  let secs = Eio.Time.now t.clock in
- lib/otel/eta_otel.ml:558:  Eta_http.Observability.Tracer.request_with_retry ~enabled:false
- lib/otel/eta_otel.ml:561:         Eta_http.Body.Stream.read_all response.Eta_http.Response.body
- lib/otel/eta_otel.ml:563:                (response.Eta_http.Response.status, body)))
- lib/otel/eta_otel.ml:565:         Eta.Effect.fail (`Export_error (Eta_http.Error.to_string error)))
- lib/otel/eta_otel.ml:653:         |> Eta_stream.run_drain)
- lib/otel/eta_otel.ml:673:       (Eta_http.Client.shutdown t.http_client
- lib/otel/eta_otel.ml:829:  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Std.r) in
- lib/otel/eta_otel.ml:830:  let clock = (clock :> float Eio.Time.clock_ty Eio.Std.r) in
- lib/otel/eta_otel.ml:868:  let http_client = Eta_http.Client.make_h1 ~sw ~net () in
- test/otel/test_tracer.ml:12:  Eio.Switch.run @@ fun sw ->
- test/otel/test_tracer.ml:16:      ~clock:(Eio.Stdenv.clock stdenv)
- test/otel/test_tracer.ml:23:  Eio.Switch.run @@ fun sw ->
- test/otel/test_tracer.ml:24:  let net = Eio.Stdenv.net stdenv in
- test/otel/test_tracer.ml:25:  let clock = Eio.Stdenv.clock stdenv in
- test/otel/test_tracer.ml:143:   Eio.Fiber.create_key for active-span propagation; there is no global
- test/otel/test_tracer.ml:243:  Eio.Switch.run @@ fun sw ->
- test/otel/test_tracer.ml:246:    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
- test/otel/test_tracer.ml:263:    Eio.Switch.run @@ fun sw ->
- test/otel/test_tracer.ml:264:    let net = Eio.Stdenv.net stdenv in
- test/otel/test_tracer.ml:265:    Eio.Net.with_tcp_connect ~host:"127.0.0.1" ~service:"27686" net (fun _ ->
- lib/otel/eta_otel.mli:11:  sw:Eio.Switch.t ->
- lib/otel/eta_otel.mli:12:  net:_ Eio.Net.t ->
- lib/otel/eta_otel.mli:13:  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
- test/otel/run.ml:37:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:39:    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
- test/otel/run.ml:40:      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
- test/otel/run.ml:42:  tcp_port (Eio.Net.listening_addr socket)
- test/otel/run.ml:63:    let reader = Eio.Buf_read.of_flow ~max_size:(1024 * 1024) flow in
- test/otel/run.ml:65:    let target = parse_request_target (Eio.Buf_read.line reader) in
- test/otel/run.ml:67:      match Eio.Buf_read.line reader with
- test/otel/run.ml:77:      ignore (Eio.Buf_read.take !content_length reader : string);
- test/otel/run.ml:84:    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:16 net
- test/otel/run.ml:85:      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
- test/otel/run.ml:87:  let port = tcp_port (Eio.Net.listening_addr socket) in
- test/otel/run.ml:88:  Eio.Fiber.fork_daemon ~sw (fun () ->
- test/otel/run.ml:91:             Eio.Switch.run @@ fun conn_sw ->
- test/otel/run.ml:92:             let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
- test/otel/run.ml:94:             if delay_s > 0.0 then Eio.Time.sleep clock delay_s;
- test/otel/run.ml:95:             Eio.Flow.copy_string response flow;
- test/otel/run.ml:96:             try Eio.Flow.shutdown flow `Send with _ -> ()
- test/otel/run.ml:109:        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:16 net
- test/otel/run.ml:110:          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
- test/otel/run.ml:112:      let port = tcp_port (Eio.Net.listening_addr socket) in
- test/otel/run.ml:115:      Eio.Fiber.fork_daemon ~sw (fun () ->
- test/otel/run.ml:118:               Eio.Switch.run @@ fun conn_sw ->
- test/otel/run.ml:119:               let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
- test/otel/run.ml:125:               if delay_s > 0.0 then Eio.Time.sleep clock delay_s;
- test/otel/run.ml:126:               Eio.Flow.copy_string responses.(index) flow;
- test/otel/run.ml:127:               try Eio.Flow.shutdown flow `Send with _ -> ()
- test/otel/run.ml:140:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:143:      ~net:(Eio.Stdenv.net stdenv)
- test/otel/run.ml:144:      ~clock:(Eio.Stdenv.clock stdenv)
- test/otel/run.ml:178:  let json = Yojson.Safe.from_string body in
- test/otel/run.ml:187:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:188:  let clock = Eio.Stdenv.clock stdenv in
- test/otel/run.ml:191:      ~net:(Eio.Stdenv.net stdenv)
- test/otel/run.ml:212:  let json = Yojson.Safe.from_string body in
- test/otel/run.ml:223:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:224:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:229:      ~clock:(Eio.Stdenv.clock stdenv)
- test/otel/run.ml:242:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:243:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:244:  let clock = Eio.Stdenv.clock stdenv in
- test/otel/run.ml:263:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:264:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:265:  let clock = Eio.Stdenv.clock stdenv in
- test/otel/run.ml:292:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:293:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:294:  let clock = Eio.Stdenv.clock stdenv in
- test/otel/run.ml:319:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:320:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:321:  let clock = Eio.Stdenv.clock stdenv in
- test/otel/run.ml:333:  let started = Eio.Time.now clock in
- test/otel/run.ml:335:  let elapsed = Eio.Time.now clock -. started in
- test/otel/run.ml:340:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:341:  let gate, release = Eio.Promise.create () in
- test/otel/run.ml:342:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:347:      ~clock:(Eio.Stdenv.clock stdenv)
- test/otel/run.ml:351:      ~on_send:(fun ~path:_ ~body:_ -> Eio.Promise.await gate)
- test/otel/run.ml:361:  Eio.Promise.resolve release ();
- test/otel/run.ml:367:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:368:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:373:      ~clock:(Eio.Stdenv.clock stdenv)
- test/otel/run.ml:392:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:393:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:397:      ~clock:(Eio.Stdenv.clock stdenv)
- test/otel/run.ml:422:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:423:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:424:  let clock = Eio.Stdenv.clock stdenv in
- test/otel/run.ml:449:  let json = Yojson.Safe.from_string body in
- test/otel/run.ml:464:    Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:465:    Eio.Net.with_tcp_connect ~host:"127.0.0.1" ~service:"27686" net (fun _ ->
- test/otel/run.ml:472:  Eio.Switch.run @@ fun sw ->
- test/otel/run.ml:478:        [ ("test.run_id", string_of_int (int_of_float (Eio.Time.now clock))) ]
- test/otel/run.ml:491:                 Eio.Time.sleep clock 0.005))
- test/otel/run.ml:495:                 Eio.Time.sleep clock 0.010))
- test/otel/run.ml:512:  let net = Eio.Stdenv.net stdenv in
- test/otel/run.ml:513:  let clock = Eio.Stdenv.clock stdenv in
- test/otel/test_metrics.ml:21:  Eio.Switch.run @@ fun sw ->
- test/otel/test_metrics.ml:25:      ~clock:(Eio.Stdenv.clock stdenv)
- test/otel/test_metrics.ml:143:    Eio.Switch.run @@ fun sw ->
- test/otel/test_metrics.ml:144:    let net = Eio.Stdenv.net stdenv in
- test/otel/test_metrics.ml:145:    Eio.Net.with_tcp_connect ~host:"127.0.0.1" ~service:"27686" net (fun _ ->
- test/otel/test_metrics.ml:156:    Eio.Switch.run @@ fun sw ->
- test/otel/test_metrics.ml:157:    let net = Eio.Stdenv.net stdenv in
- test/otel/test_metrics.ml:158:    let clock = Eio.Stdenv.clock stdenv in
- test/otel/test_metrics.ml:194:    let json = Yojson.Safe.from_string body in
<!-- END DEP_MATCHES -->
