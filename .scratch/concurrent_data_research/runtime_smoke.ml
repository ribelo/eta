open Concurrent_data_research

let with_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Effet.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  f rt

let with_traced_runtime f =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let tracer = Effet.Tracer.in_memory () in
  let rt =
    Effet.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~tracer:(Effet.Tracer.as_capability tracer) ~auto_instrument:true ~env:() ()
  in
  f rt tracer

let check_list name expected actual =
  Alcotest.(check (list int)) name expected actual

let () =
  with_runtime @@ fun rt ->
  check_list "wrapper queue" [ 1; 2; 3 ] (Fixtures.wrapper_queue_fixture rt);
  with_runtime @@ fun rt ->
  Alcotest.(check (list string))
    "wrapper deferred"
    [ "loaded:v1"; "loaded:v1"; "loaded:v1" ]
    (List.sort String.compare (Fixtures.wrapper_deferred_fixture rt));
  with_runtime @@ fun rt ->
  let wrapper_fast, wrapper_slow = Fixtures.wrapper_pubsub_fixture rt in
  check_list "wrapper pubsub fast" [ 1; 2; 3 ] wrapper_fast;
  check_list "wrapper pubsub slow" [ 1 ] wrapper_slow;
  with_runtime @@ fun rt ->
  Alcotest.(check bool) "wrapper latch" true (Fixtures.wrapper_latch_fixture rt);
  check_list "direct queue" [ 1; 2; 3 ] (Fixtures.direct_queue_fixture ());
  Alcotest.(check (list string))
    "direct deferred"
    [ "loaded:v1"; "loaded:v1"; "loaded:v1" ]
    (Fixtures.direct_deferred_fixture ());
  let direct_fast, direct_slow = Fixtures.direct_pubsub_fixture () in
  check_list "direct pubsub fast" [ 1; 2; 3 ] direct_fast;
  check_list "direct pubsub slow" [ 1 ] direct_slow;
  Alcotest.(check bool) "direct latch" true (Fixtures.direct_latch_fixture ());
  with_traced_runtime @@ fun rt tracer ->
  let names = Fixtures.wrapper_tracing_fixture rt tracer in
  Alcotest.(check (list string))
    "wrapper operations are traced by auto-instrumentation"
    [ "fixture.queue"; "queue.close"; "queue.offer" ]
    (List.sort String.compare names);
  print_endline "concurrent_data_research smoke passed"
