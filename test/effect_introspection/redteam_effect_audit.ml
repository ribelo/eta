open Eta

let () =
  let sleeps = ref 0 in
  let hidden =
    Effect.unit |> Effect.bind (fun () -> Effect.sleep Duration.zero)
  in
  let wrapped = Effect.uninterruptible (Effect.sleep Duration.zero) in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(fun _ -> incr sleeps) ()
  in
  let hidden_audit = Effect.audit hidden in
  let wrapped_audit = Effect.audit wrapped in
  ignore (Eta_eio.Runtime.run rt hidden : (unit, _) Exit.t);
  Printf.printf "hidden-bind uses_clock=%b runtime_sleeps=%d\n"
    hidden_audit.uses_clock !sleeps;
  Printf.printf "preserve-wrapped uses_clock=%b\n" wrapped_audit.uses_clock;
  (* The contract under test: the hidden bind's sleep is invisible to audit
     (uses_clock=false) while execution sleeps once; the preserve-wrapped
     sleep is visible. Fail loudly on drift. *)
  if hidden_audit.uses_clock || !sleeps <> 1 then
    failwith "redteam: hidden-bind contract drifted";
  if not wrapped_audit.uses_clock then
    failwith "redteam: preserve inheritance drifted"
