open Eta

let () =
  let sleeps = ref 0 in
  let dishonest =
    Effect.Expert.make ~leaf_name:"dishonest.sleep" ~capabilities:[]
      (fun context ->
        (Effect.Expert.contract context).sleep Duration.zero;
        Exit.Ok ())
  in
  let audit = Effect.audit dishonest in
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let runtime =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv)
      ~sleep:(fun _ -> incr sleeps) ()
  in
  ignore (Eta_eio.Runtime.run runtime dishonest : (unit, _) Exit.t);
  Printf.printf "declared uses_clock=%b runtime_sleeps=%d\n" audit.uses_clock
    !sleeps;
  if audit.uses_clock || !sleeps <> 1 then
    failwith "dishonesty probe no longer demonstrates the false declaration"
