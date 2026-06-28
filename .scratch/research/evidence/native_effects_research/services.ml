module Db = struct
  type t = { name : string }

  let make name = { name }
  let query t sql = Printf.sprintf "[%s] %s" t.name sql
end

module Log = struct
  type t = { prefix : string; mutable lines : string list }

  let make prefix = { prefix; lines = [] }

  let info t msg =
    let line = t.prefix ^ msg in
    t.lines <- line :: t.lines

  let lines t = List.rev t.lines
end

class type db = object
  method query : string -> string
end

class type log = object
  method info : string -> unit
end

let db_of (d : Db.t) : db = object
  method query sql = Db.query d sql
end

let log_of (l : Log.t) : log = object
  method info msg = Log.info l msg
end
