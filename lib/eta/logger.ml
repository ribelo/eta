type level = Capabilities.log_level =
  | Trace
  | Debug
  | Info
  | Warn
  | Error
  | Fatal

type record : immutable_data = Capabilities.log_record = {
  level : level;
  body : string;
  ts_ms : int;
  attrs : (string * string) list;
  trace_id : string;
  span_id : string;
}

type in_memory = { mutex : Mutex.t; mutable records : record list }

let in_memory () = { mutex = Mutex.create (); records = [] }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let push t r = with_lock t (fun () -> t.records <- r :: t.records)
let dump t = with_lock t (fun () -> List.rev t.records)

let as_capability t : Capabilities.logger =
  object
    method log r = push t r
  end

let noop : Capabilities.logger =
  object
    method log _ = ()
  end
