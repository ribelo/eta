open Eta

type error = [ `Fetch_failed of int ]

let fetch id =
  if id < 0 then Effect.fail (`Fetch_failed id)
  else Effect.pure (string_of_int id)

let fetch_all ids : (string list, error) Effect.t =
  Effect.map_par ~max_concurrent:4 fetch ids
