type worker_die = Island_runtime.worker_die = {
  kind : string;
  message : string;
  backtrace : string option;
}

type ('a, 'e) settled =
  ('a, 'e) Island_runtime.settled =
  | Ok of 'a
  | Error of 'e
  | Worker_died of worker_die

type pool = Island_runtime.pool

module Pool = Island_runtime.Pool

let run ?name f input =
  Effect_erasure.effect_to_public (Effect_island.island ?name f input)

let map ?name ?pool ~f inputs =
  Effect_erasure.effect_to_public (Effect_island.Island.map ?name ?pool ~f inputs)

let map_result ?name ?pool ~f inputs =
  Effect_erasure.effect_to_public
    (Effect_island.Island.map_result ?name ?pool ~f inputs)

let all_settled ?name ?pool ~f inputs =
  Effect_erasure.effect_to_public
    (Effect_island.Island.all_settled ?name ?pool ~f inputs)
