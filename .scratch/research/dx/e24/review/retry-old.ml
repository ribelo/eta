open Eta

type source_error = [ `Unavailable ]
type final_error = [ `Gave_up of int option ]

let policy = Schedule.recurs 3

let retryable = function
  | `Unavailable -> true

let load () : (string, source_error) Effect.t = Effect.fail `Unavailable

let program : (string, final_error) Effect.t =
  Effect.retry_or_else policy retryable
    ~or_else:(fun `Unavailable output -> Effect.fail (`Gave_up output))
    (load ())
