type worker_die : immutable_data = {
  kind : string;
  message : string;
  backtrace : string option;
}

type ('a : immutable_data, 'e : immutable_data) settled : immutable_data =
  | Ok of 'a
  | Error of 'e
  | Worker_died of worker_die

type pool = {
  pool : Par.Pool.t;
  mutable stopped : bool;
}

type ('a : immutable_data) map_outcome : immutable_data =
  | Map_ok of 'a
  | Map_worker_died of worker_die

type ('a : immutable_data, 'e : immutable_data) result_outcome :
  immutable_data =
  | Result_ok of 'a
  | Result_error of 'e
  | Result_worker_died of worker_die

let (worker_die_of_exn @ portable) exn =
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

  let create ?(domains = 2) () =
    if domains <= 0 then
      invalid_arg "Effect.Island.Pool.create: domains must be > 0";
    {
      pool = Par.Pool.create ~n_workers:(domains + 1) ();
      stopped = false;
    }

  let shutdown pool =
    if not pool.stopped then (
      pool.stopped <- true;
      Par.Pool.shutdown pool.pool)
end

let ensure_running pool =
  if pool.stopped then invalid_arg "Effect.Island: pool already shut down"

let (capture_map @ portable) (f @ portable) input =
  try Map_ok (f input) with exn -> Map_worker_died (worker_die_of_exn exn)

let (capture_result @ portable) (f @ portable) input =
  try
    match f input with
    | Stdlib.Ok value -> Result_ok value
    | Stdlib.Error error -> Result_error error
  with exn -> Result_worker_died (worker_die_of_exn exn)

let map_outcomes pool (f @ portable) inputs =
  ensure_running pool;
  inputs
  |> List.map (fun input () -> capture_map f input)
  |> Par.Pool.run_many_on_workers pool.pool

let result_outcomes pool (f @ portable) inputs =
  ensure_running pool;
  inputs
  |> List.map (fun input () -> capture_result f input)
  |> Par.Pool.run_many_on_workers pool.pool

let submit name pool (f @ portable) input =
  match map_outcomes pool f [ input ] with
  | [ Map_ok value ] -> value
  | [ Map_worker_died die ] -> raise_worker_die name die
  | outcomes -> unexpected_outcome_count name (List.length outcomes)

let submit_map name pool (f @ portable) inputs =
  map_outcomes pool f inputs
  |> List.map (function
       | Map_ok value -> value
       | Map_worker_died die -> raise_worker_die name die)

let submit_map_result name pool (f @ portable) inputs =
  result_outcomes pool f inputs
  |> List.map (function
       | Result_ok value -> Stdlib.Ok value
       | Result_error error -> Stdlib.Error error
       | Result_worker_died die -> raise_worker_die name die)

let submit_all_settled pool (f @ portable) inputs =
  result_outcomes pool f inputs
  |> List.map (function
       | Result_ok value -> Ok value
       | Result_error error -> Error error
       | Result_worker_died die -> Worker_died die)
