open Effet

module Auth = struct
  type t = { user : string }

  let current_user auth = auth.user
end

module Db = struct
  type t = { label : string }

  let query db key = db.label ^ ":" ^ key
end

module Log = struct
  type t = { mutable lines : string list }

  let create () = { lines = [] }

  let info log line =
    log.lines <- log.lines @ [ line ]
end

let auth user = { Auth.user = user }
let db label = { Db.label = label }

let unwrap_exit = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      failwith (Format.asprintf "%a" (Cause.pp Format.pp_print_string) cause)

let run env effect_ =
  Eio_main.run @@ fun std ->
  Eio.Switch.run @@ fun sw ->
  let runtime = Runtime.create ~sw ~clock:(Eio.Stdenv.clock std) ~env () in
  Runtime.run runtime effect_ |> unwrap_exit
