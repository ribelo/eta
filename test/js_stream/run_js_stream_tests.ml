open Eta_js
open Eta_js_stream

module Js = Js_of_ocaml.Js
module Unsafe = Js_of_ocaml.Js.Unsafe

let fail name message = failwith (name ^ ": " ^ message)

let check name condition =
  if not condition then fail name "check failed"

let check_equal_int name expected actual =
  if expected <> actual then
    fail name (Printf.sprintf "expected %d, got %d" expected actual)

let check_equal_list name expected actual =
  if expected <> actual then
    fail name (Printf.sprintf "expected %s, got %s"
      (String.concat ";" (List.map string_of_int expected))
      (String.concat ";" (List.map string_of_int actual)))

let queue_microtask f =
  ignore
    (Unsafe.fun_call (Unsafe.js_expr "queueMicrotask")
       [| Unsafe.inject (Js.wrap_callback f) |])

let run_stream runtime stream done_ check_result =
  Runtime.run runtime (run_collect stream)
    ~on_result:(fun result ->
      Eta_js_test.finish done_ (fun () -> check_result result))

let tests =
  [
    ("stream_pure_collect",
     fun done_ ->
       let runtime = Runtime.create () in
       let stream =
         Stream.range ~start:1 ~stop:5
         |> Stream.map (fun x -> x * 2)
         |> Stream.filter (fun x -> x > 4)
         |> Stream.take 2
       in
       run_stream runtime stream done_ (function
       | Exit.Ok [ 6; 8 ] -> ()
       | Exit.Ok actual ->
           check_equal_list "stream_pure_collect" [ 6; 8 ] actual
       | Exit.Error _ -> fail "stream_pure_collect" "expected ok"));
    ("stream_empty",
     fun done_ ->
       let runtime = Runtime.create () in
       run_stream runtime Stream.empty done_ (function
       | Exit.Ok [] -> ()
       | _ -> fail "stream_empty" "expected empty list"));
    ("stream_concat",
     fun done_ ->
       let runtime = Runtime.create () in
       let stream =
         Stream.concat (Stream.from_iterable [ 1; 2 ]) (Stream.from_iterable [ 3; 4 ])
       in
       run_stream runtime stream done_ (function
       | Exit.Ok [ 1; 2; 3; 4 ] -> ()
       | _ -> fail "stream_concat" "expected [1;2;3;4]"));
    ("stream_scan",
     fun done_ ->
       let runtime = Runtime.create () in
       let stream =
         Stream.from_iterable [ 1; 2; 3; 4 ]
         |> Stream.scan (fun acc x -> acc + x) 0
       in
       run_stream runtime stream done_ (function
       | Exit.Ok [ 1; 3; 6; 10 ] -> ()
       | _ -> fail "stream_scan" "expected [1;3;6;10]"));
    ("stream_grouped",
     fun done_ ->
       let runtime = Runtime.create () in
       let stream =
         Stream.from_iterable [ 1; 2; 3; 4; 5 ]
         |> Stream.grouped 2
       in
       run_stream runtime stream done_ (function
       | Exit.Ok [ [ 1; 2 ]; [ 3; 4 ]; [ 5 ] ] -> ()
       | Exit.Ok actual ->
           let s =
             String.concat ";"
               (List.map
                  (fun l ->
                    "[" ^ String.concat ";" (List.map string_of_int l) ^ "]")
                  actual)
           in
           fail "stream_grouped" ("expected [[1;2];[3;4];[5]], got [" ^ s ^ "]")
       | _ -> fail "stream_grouped" "expected ok"));
    ("stream_grouped_preserves_order_across_chunks",
     fun done_ ->
       let runtime = Runtime.create () in
       let stream =
         Stream.concat (Stream.from_iterable [ 1; 2; 3 ])
           (Stream.from_iterable [ 4; 5 ])
         |> Stream.grouped 2
       in
       run_stream runtime stream done_ (function
       | Exit.Ok [ [ 1; 2 ]; [ 3; 4 ]; [ 5 ] ] -> ()
       | Exit.Ok actual ->
           let s =
             String.concat ";"
               (List.map
                  (fun l ->
                    "[" ^ String.concat ";" (List.map string_of_int l) ^ "]")
                  actual)
           in
           fail "stream_grouped_preserves_order_across_chunks"
             ("expected [[1;2];[3;4];[5]], got [" ^ s ^ "]")
       | _ ->
           fail "stream_grouped_preserves_order_across_chunks" "expected ok"));
    ("stream_flat_map",
     fun done_ ->
       let runtime = Runtime.create () in
       let stream =
         Stream.from_iterable [ 1; 2; 3 ]
         |> Stream.flat_map (fun x -> Stream.from_iterable [ x; x ])
       in
       run_stream runtime stream done_ (function
       | Exit.Ok [ 1; 1; 2; 2; 3; 3 ] -> ()
       | Exit.Ok actual ->
           let s = String.concat ";" (List.map string_of_int actual) in
           fail "stream_flat_map" ("expected [1;1;2;2;3;3], got [" ^ s ^ "]")
       | _ -> fail "stream_flat_map" "expected ok"));
    ("stream_map_effect_preserves_order_and_caps_admission",
     fun done_ ->
       let runtime = Runtime.create () in
       let active = ref 0 in
       let maximum = ref 0 in
       let mapper_calls = ref 0 in
       let map value =
         incr mapper_calls;
         Effect.sync (fun () ->
             incr active;
             maximum := max !maximum !active)
         |> Effect.bind (fun () ->
                Effect.delay (Duration.ms 1) (Effect.pure (value * 2)))
         |> Effect.finally (Effect.sync (fun () -> decr active))
       in
       let inputs = List.init 12 (fun index -> index + 1) in
       let stream = Stream.from_iterable inputs |> Stream.map_effect map in
       check_equal_int "stream_map_effect lazy mapper" 0 !mapper_calls;
       run_stream runtime stream done_ (function
       | Exit.Ok actual ->
           check_equal_list "stream_map_effect order"
             (List.map (fun value -> value * 2) inputs) actual;
           check_equal_int "stream_map_effect peak" 8 !maximum;
           check_equal_int "stream_map_effect cleanup" 0 !active;
           check_equal_int "stream_map_effect mapper calls" 12 !mapper_calls
       | Exit.Error _ -> fail "stream_map_effect" "expected ok"));
    ("stream_map_effect_invokes_mapper_only_as_workers_admit",
     fun done_ ->
       let runtime = Runtime.create () in
       let mapper_calls = ref 0 in
       let release = ref false in
       let blocked = ref [] in
       let check_first_wave_and_release () =
         try
           check_equal_int "stream_map_effect first-wave mapper calls" 8
             !mapper_calls;
           check_equal_int "stream_map_effect first-wave blocked effects" 8
             (List.length !blocked);
           release := true;
           List.iter (fun complete -> complete ()) !blocked
         with exn -> Eta_js_test.finish done_ (fun () -> raise exn)
       in
       let rec await_first_wave attempts =
         if !mapper_calls >= 8 then check_first_wave_and_release ()
         else if attempts = 0 then
           Eta_js_test.finish done_ (fun () ->
               fail "stream_map_effect first-wave mapper calls"
                 (Printf.sprintf "expected 8, got %d" !mapper_calls))
         else queue_microtask (fun () -> await_first_wave (attempts - 1))
       in
       let map value =
         incr mapper_calls;
         Effect.async ~register:(fun resume ->
             let complete () = resume (Exit.Ok (value * 2)) in
             if !release then complete () else blocked := complete :: !blocked;
             None)
       in
       let inputs = List.init 12 (fun index -> index + 1) in
       let stream = Stream.from_iterable inputs |> Stream.map_effect map in
       Runtime.run runtime (run_collect stream)
         ~on_result:(fun result ->
           Eta_js_test.finish done_ (fun () ->
               match result with
               | Exit.Ok actual ->
                   check_equal_list "stream_map_effect admitted mapper order"
                     (List.map (fun value -> value * 2) inputs) actual;
                   check_equal_int "stream_map_effect final mapper calls" 12
                     !mapper_calls
               | Exit.Error _ ->
                   fail "stream_map_effect admitted mapper" "expected ok"));
       queue_microtask (fun () -> await_first_wave 40));
    ("stream_map_effect_preserves_typed_failure",
     fun done_ ->
       let runtime = Runtime.create () in
       let stream =
         Stream.from_iterable [ 1; 2; 3 ]
         |> Stream.map_effect (function
              | 2 -> Effect.fail `Boom
              | value -> Effect.pure value)
       in
       run_stream runtime stream done_ (function
       | Exit.Error (Cause.Fail `Boom) -> ()
       | Exit.Error _ ->
           fail "stream_map_effect_preserves_typed_failure"
             "expected raw typed failure"
       | Exit.Ok _ ->
           fail "stream_map_effect_preserves_typed_failure" "expected error"));
    ("stream_fail_preserves_typed_error",
     fun done_ ->
       let runtime = Runtime.create () in
       let stream : (int, [ `Boom | `Other ]) Stream.t = Stream.fail `Boom in
       run_stream runtime stream done_ (function
       | Exit.Error (Cause.Fail `Boom) -> ()
       | Exit.Error (Cause.Fail _) ->
           fail "stream_fail_preserves_typed_error"
             "expected raw typed failure, got different typed value"
       | Exit.Error _ ->
           fail "stream_fail_preserves_typed_error" "expected typed failure"
       | Exit.Ok _ -> fail "stream_fail_preserves_typed_error" "expected error"));
  ]

let () =
  Eta_js_test.main tests
