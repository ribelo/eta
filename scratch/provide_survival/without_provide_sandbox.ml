open Effet
open Services

let child db =
  Effect.sync "db.query" (fun _ -> query db "public")

let program db =
  secret_from_env ()
  |> Effect.bind (fun token ->
         child db |> Effect.map (fun value -> (token, value)))

let run () =
  let db = make_db "sandbox" in
  let secret = { token = "parent-secret" } in
  let env = object method secret = secret end in
  run (program db) env |> ok

module type LOCKED = sig
  val child : db -> ('env, 'err, string) Effect.t
  val program : db -> (< secret : secret >, string, string * string) Effect.t
  val run : unit -> string * string
end

module _ : LOCKED = struct
  let child = child
  let program = program
  let run = run
end
