type tracer = {
  begin_span : string -> int;
  end_span : int -> unit;
}

let noop_tracer =
  { begin_span = (fun _ -> 0); end_span = (fun _ -> ()) }

type dynamic_runtime = {
  tracer : tracer;
  tracing_enabled : bool;
}

let[@inline never] dynamic_named runtime name k =
  if runtime.tracing_enabled then
    let span = runtime.tracer.begin_span name in
    match k () with
    | value ->
        runtime.tracer.end_span span;
        value
    | exception exn ->
        runtime.tracer.end_span span;
        raise exn
  else k ()

module Generated_no_observer = struct
  let[@inline never] named _name k = k ()
end

module Generated_observed = struct
  let[@inline never] named tracer name k =
    let span = tracer.begin_span name in
    match k () with
    | value ->
        tracer.end_span span;
        value
    | exception exn ->
        tracer.end_span span;
        raise exn
end

let[@inline never] payload x = x + 1

let () =
  let runtime =
    Sys.opaque_identity { tracer = noop_tracer; tracing_enabled = false }
  in
  let a = dynamic_named runtime "dynamic" (fun () -> payload 1) in
  let b = Generated_no_observer.named "static-noop" (fun () -> payload 2) in
  let c = Generated_observed.named noop_tracer "static-observed" (fun () -> payload 3) in
  Printf.printf "dynamic=%d static_noop=%d static_observed=%d\n" a b c
