type worker_die = {
  kind : string;
  message : string;
  backtrace : string option;
}

type ('a, 'e) settled =
  | Ok of 'a
  | Error of 'e
  | Worker_died of worker_die

type pool = {
  pool : Par_runtime.Pool.t;
  wait_pool : Eta_blocking.Pool.t;
  stopped : bool Atomic.t;
}

type ('a) map_outcome =
  | Map_ok of 'a
  | Map_worker_died of worker_die

type ('a, 'e) result_outcome =
  | Result_ok of 'a
  | Result_error of 'e
  | Result_worker_died of worker_die

let worker_die_of_exn exn =
  let backtrace =
    Printexc.raw_backtrace_to_string (Printexc.get_raw_backtrace ())
  in
  {
    kind = "worker_died";
    message = Printexc.to_string exn;
    backtrace = Some backtrace;
  }

let raise_worker_die name die =
  failwith
    (Printf.sprintf "%s: worker died (%s): %s" name die.kind die.message)

let unexpected_outcome_count name actual =
  failwith
    (Printf.sprintf "%s: expected one island result, got %d" name actual)

module Pool = struct
  type t = pool

  let wait_config =
    {
      Eta_blocking.Pool.max_threads = 128;
      max_queued = 64;
      queue_policy = Eta_blocking.Pool.Wait;
      shutdown_policy = Eta_blocking.Pool.Detach_started;
    }

  let create ?(domains = 2) () =
    if domains <= 0 then
      invalid_arg "Eta_par.Island.Pool.create: domains must be > 0";
    {
      pool = Par_runtime.Pool.create ~n_workers:(domains + 1) ();
      wait_pool =
        Eta_blocking.Pool.create ~name:"eta_par.island_wait"
          wait_config;
      stopped = Atomic.make false;
    }

  let shutdown pool =
    if Atomic.compare_and_set pool.stopped false true then
      Par_runtime.Pool.shutdown pool.pool
end

let wait_pool pool = pool.wait_pool

let ensure_running pool =
  if Atomic.get pool.stopped then
    invalid_arg "Eta_par.Island: pool already shut down"

let capture_map (f) input =
  try Map_ok (f input) with exn -> Map_worker_died (worker_die_of_exn exn)

let capture_result (f) input =
  try
    match f input with
    | Stdlib.Ok value -> Result_ok value
    | Stdlib.Error error -> Result_error error
  with exn -> Result_worker_died (worker_die_of_exn exn)

let map_outcomes pool (f) inputs =
  ensure_running pool;
  inputs
  |> List.map (fun input () -> capture_map f input)
  |> Par_runtime.Pool.run_many_on_workers pool.pool

let result_outcomes pool (f) inputs =
  ensure_running pool;
  inputs
  |> List.map (fun input () -> capture_result f input)
  |> Par_runtime.Pool.run_many_on_workers pool.pool

let submit name pool (f) input =
  match map_outcomes pool f [ input ] with
  | [ Map_ok value ] -> value
  | [ Map_worker_died die ] -> raise_worker_die name die
  | outcomes -> unexpected_outcome_count name (List.length outcomes)

let submit_map name pool (f) inputs =
  map_outcomes pool f inputs
  |> List.map (function
       | Map_ok value -> value
       | Map_worker_died die -> raise_worker_die name die)

let submit_map_result name pool (f) inputs =
  result_outcomes pool f inputs
  |> List.map (function
       | Result_ok value -> Stdlib.Ok value
       | Result_error error -> Stdlib.Error error
       | Result_worker_died die -> raise_worker_die name die)

let submit_all_settled pool (f) inputs =
  result_outcomes pool f inputs
  |> List.map (function
       | Result_ok value -> Ok value
       | Result_error error -> Error error
       | Result_worker_died die -> Worker_died die)
