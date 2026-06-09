let run_main eff =
  let runtime = Runtime.create () in
  Js.Promise.then_
    (fun exit ->
      match exit with
      | Exit.Ok a -> Js.Promise.resolve a
      | Exit.Error cause -> Js.Promise.reject (Obj.magic cause))
    (Runtime.run_promise runtime eff)
