(* Branch B: keep public detach, but keep its typed error row and report child
   causes to a runtime hook. *)

type 'err cause = Fail of 'err | Die of exn | Interrupt

type ('env, 'err, 'a) t =
  | Pure : 'a -> (_, _, 'a) t
  | Fail : 'err -> (_, 'err, _) t
  | Bind :
      ('env, 'err, 'a) t * ('a -> ('env, 'err, 'b) t)
      -> ('env, 'err, 'b) t
  | Detach : ('env, 'err, unit) t -> ('env, 'err, unit) t

type 'err runtime = { on_detached_failure : 'err cause -> unit }

let pure value = Pure value
let fail err = Fail err
let bind k eff = Bind (eff, k)
let detach eff = Detach eff

let rec run : type env err a. err runtime -> (env, err, a) t -> (a, err cause) result =
 fun runtime -> function
  | Pure value -> Ok value
  | Fail err -> Error (Fail err)
  | Bind (eff, k) -> (
      match run runtime eff with
      | Ok value -> run runtime (k value)
      | Error cause -> Error cause)
  | Detach child -> (
      match run runtime child with
      | Ok () -> Ok ()
      | Error cause ->
          runtime.on_detached_failure cause;
          Ok ())

let parent_survives_and_hook_observes () =
  let observed = ref [] in
  let runtime = { on_detached_failure = (fun cause -> observed := cause :: !observed) } in
  let program =
    detach (fail `Detached_boom)
    |> bind (fun () -> pure "parent-ok")
  in
  match (run runtime program, !observed) with
  | Ok "parent-ok", [ Fail `Detached_boom ] -> true
  | _ -> false

module type BRANCH_B_SIG = sig
  val program : (unit, [ `Detached_boom ], string) t
end

module _ : BRANCH_B_SIG = struct
  let program : (unit, [ `Detached_boom ], string) t =
    detach (fail `Detached_boom)
    |> bind (fun () -> pure "parent-ok")
end
