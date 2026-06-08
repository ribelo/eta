open Effet
open Services

module Third_party : sig
  val black_box : unit -> (< db : db ; .. >, string, string) Effect.t
  val make : db -> ('env, string, string) Effect.t
end = struct
  let black_box () =
    Effect.named "third.black_box" (Effect.sync (fun env -> query env#db "child"))

  let make db =
    Effect.named "third.make" (Effect.sync (fun _env -> query db "child"))
end

let host_env ~db ~audit ~secret =
  object
    method db = db
    method audit = audit
    method secret = secret
  end

let db_only_env db =
  object
    method db = db
  end

let host_program child =
  Effect.bind
    (fun before ->
       Effect.bind
         (fun child_value ->
            Effect.named "host.after" (Effect.sync (fun env ->
              let after = query env#db "after" in
              write_audit env#audit after;
              String.concat ";"
                [
                  "before=" ^ before;
                  "child=" ^ child_value;
                  "after=" ^ after;
                  "secret=" ^ env#secret.token;
                ])))
         child)
    (Effect.named "host.before" (Effect.sync (fun env ->
       let before = query env#db "before" in
       write_audit env#audit before;
       before)))

let run_black_box_uses_host_db () =
  let real_db = db "real" in
  let audit = audit () in
  let env = host_env ~db:real_db ~audit ~secret:(secret "s3") in
  let result = run_with_env env (host_program (Third_party.black_box ())) in
  result, audit.entries

let run_constructor_can_swap_child_db () =
  let real_db = db "real" in
  let fake_db = db "fake" in
  let audit = audit () in
  let env = host_env ~db:real_db ~audit ~secret:(secret "s3") in
  let result = run_with_env env (host_program (Third_party.make fake_db)) in
  result, audit.entries

let run_separate_boundary_can_swap_but_splits_program () =
  let fake_child =
    run_with_env (db_only_env (db "fake")) (Third_party.black_box ())
  in
  let real_db = db "real" in
  let audit = audit () in
  let env = host_env ~db:real_db ~audit ~secret:(secret "s3") in
  let result = run_with_env env (host_program (Effect.pure fake_child)) in
  result, audit.entries

module Private_eval = struct
  let rec eval : type env err a. env -> (env, err, a) Effect.t -> (a, err) result =
   fun env effect_ ->
    match Effect.Private.view effect_ with
    | Pure value -> Ok value
    | Fail err -> Error err
    | Sync (_name, thunk) -> Ok (thunk env)
    | Map (first, f) -> Result.map f (eval env first)
    | Bind (first, next) -> (
        match eval env first with
        | Ok value -> eval env (next value)
        | Error err -> Error err)
    | _ -> failwith "research-only evaluator supports Pure/Fail/Sync/Bind only"

  let locally env effect_ =
    Effect.named "private_eval.locally" (Effect.sync (fun _parent_env ->
      match eval env effect_ with
      | Ok value -> value
      | Error err -> failwith err))
end

let run_private_eval_can_swap_but_reimplements_runtime_subset () =
  let real_db = db "real" in
  let fake_db = db "fake" in
  let audit = audit () in
  let env = host_env ~db:real_db ~audit ~secret:(secret "s3") in
  let child = Private_eval.locally (db_only_env fake_db) (Third_party.black_box ()) in
  let result = run_with_env env (host_program child) in
  result, audit.entries
