open Eta_js
open Eta_js_stream

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
  ]

let () =
  Eta_js_test.main tests
