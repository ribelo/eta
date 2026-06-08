module Native = Stdlib.Effect
module Deep = Stdlib.Effect.Deep

type level = Info | Warn | Error
type path = Handler | Fiber_local_fallback | Domain_local_fallback

type record = {
  level : level;
  body : string;
  path : path;
  domain_id : int;
}

type sink = {
  mutex : Mutex.t;
  mutable records : record list;
}

exception Not_configured

type _ Native.t += Emit : level * string -> unit Native.t

let create_sink () = { mutex = Mutex.create (); records = [] }

let with_lock t f =
  Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.mutex) f

let dump t = with_lock t (fun () -> List.rev t.records)
let clear t = with_lock t (fun () -> t.records <- [])

let domain_id () = (Domain.self () :> int)

let push t path level body =
  with_lock t @@ fun () ->
  t.records <- { level; body; path; domain_id = domain_id () } :: t.records

let none_key =
  (Domain.DLS.new_key [@alert "-unsafe_multidomain"])
    ~split_from_parent:(fun value -> value)
    (fun () -> None)

let fiber_key : sink Eio.Fiber.key = Eio.Fiber.create_key ()

let current_fiber_sink () =
  try Eio.Fiber.get fiber_key with Native.Unhandled _ -> None

let current_domain_sink () =
  (Domain.DLS.get [@alert "-unsafe_multidomain"]) none_key

let current_sink () =
  match current_fiber_sink () with
  | Some sink -> Some (sink, Fiber_local_fallback)
  | None -> (
      match current_domain_sink () with
      | Some sink -> Some (sink, Domain_local_fallback)
      | None -> None)

let emit level body =
  try Native.perform (Emit (level, body)) with
  | Native.Unhandled _ -> (
      match current_sink () with
      | Some (sink, path) -> push sink path level body
      | None -> raise Not_configured)

let info body = emit Info body

let install sink f =
  Deep.try_with f ()
    {
      effc =
        (fun (type a) (eff : a Native.t) ->
          match eff with
          | Emit (level, body) ->
              Some
                (fun (k : (a, _) Deep.continuation) ->
                  push sink Handler level body;
                  Deep.continue k ())
          | _ -> None);
    }

module Runtime = struct
  let with_domain_sink sink f =
    let previous =
      (Domain.DLS.get [@alert "-unsafe_multidomain"]) none_key
    in
    (Domain.DLS.set [@alert "-unsafe_multidomain"]) none_key (Some sink);
    Fun.protect
      ~finally:(fun () ->
        (Domain.DLS.set [@alert "-unsafe_multidomain"]) none_key previous)
      f

  let run sink f =
    with_domain_sink sink @@ fun () ->
    Eio.Fiber.with_binding fiber_key sink @@ fun () -> install sink f

  let run_no_eio sink f =
    with_domain_sink sink @@ fun () -> install sink f

  let configured_sink () =
    match current_sink () with
    | Some (sink, _) -> sink
    | None -> raise Not_configured

  let both left right =
    let sink = configured_sink () in
    Eio.Fiber.both
      (fun () -> run sink left)
      (fun () -> run sink right)

  let spawn_domain f =
    let sink = configured_sink () in
    (Domain.spawn
       [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      (fun () -> run_no_eio sink f)
end
