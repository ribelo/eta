open Eta

let keep_successes (record : Capabilities.log_record) =
  if record.level = Capabilities.Error then Effect.Drop
  else if String.equal record.body "password=secret" then
    Effect.Replace { record with body = "password=[redacted]" }
  else Effect.Keep

(* [Keep] is the ordinary no-change answer, [Drop] terminates the pipeline, and
   [Replace value] makes substitution explicit at the branch that allocates. *)
