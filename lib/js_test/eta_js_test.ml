module Test_clock = Test_clock

type test = string * (unit -> unit Js.Promise.t)

let exn_of_promise_error error =
  Js.Exn.anyToExnInternal (Obj.magic error)

let expect_ok name f =
  Js.Promise.make (fun ~resolve ~reject:_ ->
      let resolve_unit : unit -> unit = Obj.magic resolve in
      try
        f ();
        resolve_unit ()
      with exn ->
        failwith (name ^ ": " ^ Printexc.to_string exn))

let rec run_all tests =
  match tests with
  | [] -> Js.Promise.resolve ()
  | (name, test) :: rest ->
      Js.Promise.then_
        (fun () -> run_all rest)
        (Js.Promise.catch
           (fun error ->
             let exn = exn_of_promise_error error in
             failwith (name ^ ": " ^ Printexc.to_string exn))
           (test ()))
