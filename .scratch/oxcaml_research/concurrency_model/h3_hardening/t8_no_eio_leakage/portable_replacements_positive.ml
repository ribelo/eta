open! Portable

let with_scheduler f =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () -> f scheduler)

let context =
  match
    Effet.Trace_context.make
      ~trace_id:"4bf92f3577b34da6a3ce929d0e0e4736"
      ~span_id:"00f067aa0ba902b7" ()
  with
  | Some context -> context
  | None -> failwith "bad trace context"

let cause : string Effet.Cause.Portable.t =
  Effet.Cause.Portable.Die
    {
      kind = "Failure";
      message = "Failure(\"portable\")";
      backtrace = None;
      span_name = Some "worker";
      annotations = [ ("portable", "true") ];
    }

let cancel = Atomic.make false
let duration = Effet.Duration.seconds 1
let schedule = Effet.Schedule.spaced duration
let sampler = Effet.Sampler.always_on

let () =
  let left, right =
    with_scheduler (fun scheduler ->
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
        let #(left, right) =
          Parallel.fork_join2 parallel
            (fun _ ->
              Atomic.get cancel,
              context,
              cause,
              duration,
              schedule,
              sampler)
            (fun _ ->
              Atomic.set cancel true;
              Atomic.get cancel,
              context,
              cause,
              duration,
              schedule,
              sampler)
        in
        (left, right)))
  in
  let _, returned_context, _, returned_duration, returned_schedule, returned_sampler = left in
  let cancel_seen, _, _, _, _, _ = right in
  let duration_ms = Effet.Duration.to_ms returned_duration in
  let delay = Effet.Schedule.next_delay returned_schedule ~step:0 in
  let sampled =
    Effet.Sampler.sample returned_sampler ~trace_id:returned_context.trace_id
      ~name:"worker" ~attrs:[] ~parent:true
  in
  if returned_context.trace_id <> context.trace_id || duration_ms <> 1000 || delay = None then
    failwith "portable replacements changed";
  if (not sampled) || not cancel_seen then failwith "portable controls failed";
  Printf.printf
    "portable_replacements_positive cause_portable=true trace_context=true atomics=true schedule_duration_sampler=true\n%!"
