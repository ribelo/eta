(* A real-Effet-shaped one-shot interpreter function. This keeps the effect
   representation small while checking the core typed-failure combinators and
   resource callback ownership. *)

type ('env, 'err, 'a) t = 'env -> ('a, 'err) result

let pure value _env = Ok value
let fail err _env = Error err
let thunk f env = Ok (f env)

let bind (k @ once) (effect @ once) env =
  match effect env with
  | Ok value -> k value env
  | Error err -> Error err

let map (f @ once) (effect @ once) env =
  match effect env with
  | Ok value -> Ok (f value)
  | Error err -> Error err

let catch (handler @ once) (effect @ once) env =
  match effect env with
  | Ok value -> Ok value
  | Error err -> handler err env

let acquire_release ~(acquire @ once) ~(release @ once) env =
  match acquire env with
  | Error err -> Error err
  | Ok resource -> (
      match release resource env with
      | Ok () -> Ok resource
      | Error err -> Error err)

let run (effect @ once) env = effect env

type env = { base : int }

let () =
  let released = ref 0 in
  let (release @ once) value _env =
    released := value;
    Ok ()
  in
  let acquired =
    acquire_release
      ~acquire:(thunk (fun env -> env.base + 1))
      ~release
  in
  let bound = bind (fun value -> pure (value + 1)) acquired in
  let mapped = map (fun value -> value * 2) bound in
  let program = catch (fun (`Recover value) -> pure value) mapped in
  match run program { base = 20 } with
  | Ok 44 when !released = 21 -> ()
  | Ok value -> failwith ("unexpected value " ^ string_of_int value)
  | Error _ -> failwith "unexpected typed failure"
