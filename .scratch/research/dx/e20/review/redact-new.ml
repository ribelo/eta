open Eta

let scrub (record : Capabilities.log_record) =
  let attrs =
    List.map
      (fun (key, value) ->
        if String.equal key "password" then (key, "[redacted]")
        else (key, value))
      record.attrs
  in
  Some { record with attrs }

let login ~sink =
  Effect.intercept_log scrub
    (Effect.with_logger sink
       (Effect.log ~attrs:[ ("password", "open-sesame") ] "login"))

(* The policy is scoped independently of the sink. A logger selected anywhere
   inside this subtree still receives the scrubbed record. *)
