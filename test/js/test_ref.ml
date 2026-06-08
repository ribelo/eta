open Test_support

let tests =
  [
    ("ref_get_set",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let r = Ref.make_unsafe 1 in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Ref.get" 1 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Ref.get r))
       in
       let p2 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_unit "Ref.set" exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Ref.set r 2))
       in
       let p3 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Ref.get after set" 2 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Ref.get r))
       in
       Js.Promise.all [| p1; p2; p3 |]
       |> Js.Promise.then_ (fun _ -> Js.Promise.resolve ()));
    ("ref_modify",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let r = Ref.make_unsafe 10 in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Ref.modify" 10 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Ref.modify r (fun v -> (v, v + 1))))
       in
       let p2 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Ref.get after modify" 11 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Ref.get r))
       in
       Js.Promise.all [| p1; p2 |]
       |> Js.Promise.then_ (fun _ -> Js.Promise.resolve ()));
  ]
