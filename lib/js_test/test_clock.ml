type sleeper = {
  deadline_ms : int;
  seq : int;
  scheduler : Eta_js.Scheduler.t option;
  callback : unit -> unit;
  mutable active : bool;
}

type t = {
  mutable now_ms : int;
  mutable next_seq : int;
  mutable sleepers : sleeper list;
}

let create () = { now_ms = 0; next_seq = 0; sleepers = [] }
let now_ms t = t.now_ms
let sleeper_count t = List.length t.sleepers

let sleeper_before left right =
  left.deadline_ms < right.deadline_ms
  || (left.deadline_ms = right.deadline_ms && left.seq < right.seq)

let insert_sleeper sleeper sleepers =
  let rec loop prefix = function
    | [] -> List.rev_append prefix [ sleeper ]
    | current :: rest as suffix ->
        if sleeper_before sleeper current then
          List.rev_append prefix (sleeper :: suffix)
        else loop (current :: prefix) rest
  in
  loop [] sleepers

let remove_sleeper t sleeper =
  sleeper.active <- false;
  t.sleepers <- List.filter (fun current -> current != sleeper) t.sleepers

let wake_due t =
  let rec collect_due due = function
    | sleeper :: rest when sleeper.deadline_ms <= t.now_ms ->
        collect_due (sleeper :: due) rest
    | pending -> (List.rev due, pending)
  in
  let due, pending = collect_due [] t.sleepers in
  t.sleepers <- pending;
  List.iter
    (fun sleeper ->
      if sleeper.active then begin
        sleeper.active <- false;
        sleeper.callback ()
      end)
    due;
  let schedulers = ref [] in
  List.iter
    (fun sleeper ->
      match sleeper.scheduler with
      | Some s when not (List.memq s !schedulers) ->
          schedulers := s :: !schedulers;
          Eta_js.Scheduler.drain_ready s
      | _ -> ())
    due

let clock t : Eta_js.Runtime_core.clock =
  {
    now_ms = (fun () -> t.now_ms);
    sleep =
      (fun duration callback ->
        let deadline_ms = t.now_ms + Eta_js.Duration.to_ms duration in
        let sleeper =
          {
            deadline_ms;
            seq = t.next_seq;
            scheduler = None;
            callback;
            active = true;
          }
        in
        t.next_seq <- t.next_seq + 1;
        if deadline_ms <= t.now_ms then callback ()
        else t.sleepers <- insert_sleeper sleeper t.sleepers;
        fun () -> remove_sleeper t sleeper);
  }

let runtime ?scheduler t =
  let scheduler =
    match scheduler with
    | Some s -> s
    | None -> Eta_js.Scheduler.create ()
  in
  Eta_js.Runtime.create ~scheduler ~clock:(clock t) ()

let sleep t duration =
  Eta_js.Effect.Expert.async_leaf (fun context ~resume ~on_cancel ->
      let deadline_ms = t.now_ms + Eta_js.Duration.to_ms duration in
      let sleeper =
        {
          deadline_ms;
          seq = t.next_seq;
          scheduler = Some (Eta_js.Effect.Expert.scheduler context);
          callback = (fun () -> resume (Eta_js.Exit.ok ()));
          active = true;
        }
      in
      t.next_seq <- t.next_seq + 1;
      on_cancel (fun () -> remove_sleeper t sleeper);
      if deadline_ms <= t.now_ms then
        Eta_js.Scheduler.enqueue (Eta_js.Effect.Expert.scheduler context) sleeper.callback
      else t.sleepers <- insert_sleeper sleeper t.sleepers)

let adjust t duration =
  Eta_js.Effect.sync (fun () ->
      t.now_ms <- t.now_ms + Eta_js.Duration.to_ms duration;
      wake_due t)

let set_time t now_ms =
  Eta_js.Effect.sync (fun () ->
      t.now_ms <- now_ms;
      wake_due t)
