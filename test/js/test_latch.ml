open Test_support

let tests =
  [
    ("latch_await_release",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let latch = Latch.make_unsafe () in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_unit "Latch.await release" exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Latch.await latch))
       in
       (match Runtime.run_now runtime (Latch.release latch) with
       | Some (Exit.Ok true) -> ()
       | _ -> fail "Latch.release" "expected true" |> raise);
       p1);
    ("latch_second_release_false",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let latch = Latch.make_unsafe () in
       (match Runtime.run_now runtime (Latch.release latch) with
       | Some (Exit.Ok true) -> ()
       | _ -> fail "Latch.first release" "expected true" |> raise);
       (match Runtime.run_now runtime (Latch.release latch) with
       | Some (Exit.Ok false) -> ()
       | _ -> fail "Latch.second release" "expected false" |> raise);
       Js.Promise.resolve ());
    ("latch_is_released",
     fun () ->
       let open Eta_js in
       let latch = Latch.make_unsafe () in
       check "Latch.is_released initial" (not (Latch.is_released latch));
       ignore (Latch.release latch);
       check "Latch.is_released after" (Latch.is_released latch);
       Js.Promise.resolve ());
  ]
