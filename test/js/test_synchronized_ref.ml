open Test_support

let tests =
  [
    ("synchronized_ref_serializes",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let r = Synchronized_ref.make_unsafe 0 in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_unit "Synchronized_ref.update_effect" exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Synchronized_ref.update_effect r (fun v -> Effect.pure (v + 1))))
       in
       let p2 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Synchronized_ref.get" 1 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Synchronized_ref.get r))
       in
       Js.Promise.all [| p1; p2 |]
       |> Js.Promise.then_ (fun _ -> Js.Promise.resolve ()));
    ("synchronized_ref_modify_effect",
     fun () ->
       let open Eta_js in
       let runtime = Runtime.create () in
       let r = Synchronized_ref.make_unsafe 5 in
       let p1 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Synchronized_ref.modify_effect" 15 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime
              (Synchronized_ref.modify_effect r (fun v ->
                   Effect.pure (v * 3, v + 1))))
       in
       let p2 =
         Js.Promise.then_
           (fun exit ->
             check_exit_ok_int "Synchronized_ref.get after modify" 6 exit;
             Js.Promise.resolve ())
           (Runtime.run_promise runtime (Synchronized_ref.get r))
       in
       Js.Promise.all [| p1; p2 |]
       |> Js.Promise.then_ (fun _ -> Js.Promise.resolve ()));
  ]
