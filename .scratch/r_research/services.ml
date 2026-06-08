(* Shared service definitions. Each variant uses these. *)

module Db = struct
  type t = { name : string }
  let make name = { name }
  let query t sql = Printf.sprintf "[%s] %s" t.name sql
end

module Log = struct
  type t = { prefix : string }
  let make prefix = { prefix }
  let info t msg = Printf.printf "%s%s\n" t.prefix msg
end

(* Object-type traits for the row-polymorphism variants. *)
class type clock = object
  method now : float
end

class type db = object
  method query : string -> string
end

class type log = object
  method info : string -> unit
end

let db_of (d : Db.t) : db = object method query sql = Db.query d sql end
let log_of (l : Log.t) : log = object method info msg = Log.info l msg end
