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
  scheduler : Parallel_scheduler.t;
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

type ('a : immutable_data) batch_state : immutable_data = {
  batch_items : 'a list;
  batch_len : int;
}

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

module Pool = struct
  type t = pool

  let create ?(domains = 2) () =
    if domains <= 0 then
      invalid_arg "Effect.Island.Pool.create: domains must be > 0";
    {
      scheduler = Parallel_scheduler.create ~max_domains:domains ();
      stopped = false;
    }

  let shutdown pool =
    if not pool.stopped then (
      pool.stopped <- true;
      Parallel_scheduler.stop pool.scheduler)
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

let rec (split_batch_items @ portable) n acc items =
  if n = 0 then (List.rev acc, items)
  else
    match items with
    | [] -> (List.rev acc, [])
    | item :: rest -> split_batch_items (n - 1) (item :: acc) rest

let map_outcomes_with_parallel parallel (f @ portable) inputs =
  let sequence =
    Parallel.Sequence.With_length.unfold
      ~init:{ batch_items = inputs; batch_len = List.length inputs }
      ~next:(fun _ state ->
        match state.batch_items with
        | item :: rest ->
            #(item, { batch_items = rest; batch_len = state.batch_len - 1 })
        | [] -> assert false)
      ~split_at:(fun _ state ~n ->
        let left, right = split_batch_items n [] state.batch_items in
        #( { batch_items = left; batch_len = n },
           { batch_items = right; batch_len = state.batch_len - n } ))
      ~length:(fun state -> state.batch_len)
  in
  let mapped =
    Parallel.Sequence.With_length.map sequence ~f:(fun _ input ->
        capture_map f input)
  in
  let result = Parallel.Sequence.With_length.to_list parallel mapped in
  match result with [] -> [] | _ -> result

let result_outcomes_with_parallel parallel (f @ portable) inputs =
  let sequence =
    Parallel.Sequence.With_length.unfold
      ~init:{ batch_items = inputs; batch_len = List.length inputs }
      ~next:(fun _ state ->
        match state.batch_items with
        | item :: rest ->
            #(item, { batch_items = rest; batch_len = state.batch_len - 1 })
        | [] -> assert false)
      ~split_at:(fun _ state ~n ->
        let left, right = split_batch_items n [] state.batch_items in
        #( { batch_items = left; batch_len = n },
           { batch_items = right; batch_len = state.batch_len - n } ))
      ~length:(fun state -> state.batch_len)
  in
  let mapped =
    Parallel.Sequence.With_length.map sequence ~f:(fun _ input ->
        capture_result f input)
  in
  let result = Parallel.Sequence.With_length.to_list parallel mapped in
  match result with [] -> [] | _ -> result

let map_outcomes pool (f @ portable) inputs =
  ensure_running pool;
  Parallel_scheduler.parallel pool.scheduler ~f:(fun parallel ->
      map_outcomes_with_parallel parallel f inputs)

let result_outcomes pool (f @ portable) inputs =
  ensure_running pool;
  Parallel_scheduler.parallel pool.scheduler ~f:(fun parallel ->
      result_outcomes_with_parallel parallel f inputs)

let submit name pool (f @ portable) input =
  match map_outcomes pool f [ input ] with
  | [ Map_ok value ] -> value
  | [ Map_worker_died die ] -> raise_worker_die name die
  | _ -> assert false

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
