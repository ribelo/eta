open Eta

let fetch id =
  Effect.sleep (Duration.ms 10)
  |> Effect.map (fun () -> id)

let looks_unbounded ids =
  (* Omission is visually easy to misread as unlimited concurrency. *)
  Effect.map_par fetch ids

let explicit_equivalent ids =
  Effect.map_par ~max_concurrent:8 fetch ids

let _proof_types : (int list, string) Effect.t * (int list, string) Effect.t =
  (looks_unbounded (List.init 9 Fun.id),
   explicit_equivalent (List.init 9 Fun.id))
