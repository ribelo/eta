open Effet
open Services

let child db =
  Effect.sync "db.query" (fun _ -> query db "select 1")

let program =
  Effect.scoped
    (scoped_db "scoped"
    |> Effect.bind (fun db ->
           child db |> Effect.map (fun result -> (result, db.closed))))

let run () =
  let result, closed_during_scope = run program (object end) |> ok in
  (result, closed_during_scope)

module type LOCKED = sig
  val child : db -> ('env, 'err, string) Effect.t
  val program : (<  >, string, string * bool) Effect.t
  val run : unit -> string * bool
end

module _ : LOCKED = struct
  let child = child
  let program = program
  let run = run
end
