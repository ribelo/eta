type db = { name : string }
type log = { mutable lines : string list }

let make_db name = { name }
let make_log () = { lines = [] }
let query db id = String.length db.name + int_of_string id
let info log msg = log.lines <- msg :: log.lines
let lines log = List.rev log.lines
