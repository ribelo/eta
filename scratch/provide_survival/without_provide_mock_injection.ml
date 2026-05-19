open Effet
open Services

let read_user db =
  audit_from_env "before"
  |> Effect.bind (fun () ->
         Effect.sync "db.query" (fun _ -> query db "user:42")
         |> Effect.bind (fun value ->
                audit_from_env ("read:" ^ value)
                |> Effect.map (fun () -> value)))

let program fake_db =
  audit_from_env "outer-real"
  |> Effect.bind (fun () ->
         read_user fake_db
         |> Effect.bind (fun value ->
                audit_from_env "outer-real-again"
                |> Effect.map (fun () -> value)))

let run () =
  let fake_db = make_db "fake" in
  let audit = audit () in
  let env = object method audit = audit end in
  let value = run (program fake_db) env |> ok in
  (value, lines audit)

module type LOCKED = sig
  val read_user : db -> (< audit : audit >, string, string) Effect.t
  val program : db -> (< audit : audit >, string, string) Effect.t
  val run : unit -> string * string list
end

module _ : LOCKED = struct
  let read_user = read_user
  let program = program
  let run = run
end
