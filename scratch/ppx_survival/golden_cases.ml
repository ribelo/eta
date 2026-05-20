open Effet

module Auth = struct
  type t = { user : string }
end

let top_level () = [%effet.fn (Effect.pure 1)]

let nested_function () =
  let inner () = [%effet.fn (Effect.pure 2)] in
  inner ()

let anonymous_lambda () =
  List.map (fun x -> [%effet.fn (Effect.pure (x + 1))]) [ 1; 2 ]

let partial_application prefix =
  let apply = ( ^ ) prefix in
  [%effet.fn (Effect.pure (apply "x"))]

let local_module () =
  let module Local = struct
    let value = 4
  end in
  [%effet.fn (Effect.pure Local.value)]

let thunk_leaf () =
  [%effet.thunk "auth.current" (auth : Auth.t) auth.user]

let env_builder auth = [%effet.env { auth = (auth : Auth.t) }]
