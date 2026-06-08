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

let tests =
  [
    ("stream_pure_collect",
     fun () ->
       let runtime = Runtime.create () in
       let stream =
         Stream.range ~start:1 ~stop:5
         |> Stream.map (fun x -> x * 2)
         |> Stream.filter (fun x -> x > 4)
         |> Stream.take 2
       in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok [ 6; 8 ] -> ()
             | Exit.Ok actual ->
                 check_equal_list "stream_pure_collect" [ 6; 8 ] actual
             | Exit.Error _ -> fail "stream_pure_collect" "expected ok" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (run_collect stream))
       in
       p);
    ("stream_empty",
     fun () ->
       let runtime = Runtime.create () in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok [] -> ()
             | _ -> fail "stream_empty" "expected empty list" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (run_collect Stream.empty))
       in
       p);
    ("stream_concat",
     fun () ->
       let runtime = Runtime.create () in
       let stream =
         Stream.concat (Stream.from_iterable [ 1; 2 ]) (Stream.from_iterable [ 3; 4 ])
       in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok [ 1; 2; 3; 4 ] -> ()
             | _ -> fail "stream_concat" "expected [1;2;3;4]" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (run_collect stream))
       in
       p);
    ("stream_scan",
     fun () ->
       let runtime = Runtime.create () in
       let stream =
         Stream.from_iterable [ 1; 2; 3; 4 ]
         |> Stream.scan (fun acc x -> acc + x) 0
       in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok [ 1; 3; 6; 10 ] -> ()
             | _ -> fail "stream_scan" "expected [1;3;6;10]" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (run_collect stream))
       in
       p);
    ("stream_grouped",
     fun () ->
       let runtime = Runtime.create () in
       let stream =
         Stream.from_iterable [ 1; 2; 3; 4; 5 ]
         |> Stream.grouped 2
       in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok actual ->
                 (match actual with
                 | [ [ 1; 2 ]; [ 3; 4 ]; [ 5 ] ] -> ()
                 | _ ->
                     let s = String.concat ";" (List.map (fun l -> "[" ^ String.concat ";" (List.map string_of_int l) ^ "]") actual) in
                     fail "stream_grouped" ("expected [[1;2];[3;4];[5]], got [" ^ s ^ "]") |> raise)
             | _ -> fail "stream_grouped" "expected ok" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (run_collect stream))
       in
       p);
    ("stream_flat_map",
     fun () ->
       let runtime = Runtime.create () in
       let stream =
         Stream.from_iterable [ 1; 2; 3 ]
         |> Stream.flat_map (fun x -> Stream.from_iterable [ x; x ])
       in
       let p =
         Js.Promise.then_
           (fun exit ->
             (match exit with
             | Exit.Ok actual ->
                 (match actual with
                 | [ 1; 1; 2; 2; 3; 3 ] -> ()
                 | _ ->
                     let s = String.concat ";" (List.map string_of_int actual) in
                     fail "stream_flat_map" ("expected [1;1;2;2;3;3], got [" ^ s ^ "]") |> raise)
             | _ -> fail "stream_flat_map" "expected ok" |> raise);
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (run_collect stream))
       in
       p);
  ]

let () =
  ignore
    (Js.Promise.catch
       (fun error ->
         let exn = Js.Exn.anyToExnInternal (Obj.magic error) in
         Printf.eprintf "FAILED: %s\n" (Printexc.to_string exn);
         raise exn)
       (Eta_js_test.run_all tests))
