(* Compatibility smoke: a real Effet program built with [Effet.Effect.t]
   runs end-to-end under OxCaml. This is the positive baseline for
   compatibility (mirrors [effet_resource_portable_probe], but minimal). *)

open Effet

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  let program : (unit, [ `Never ], int) Effect.t =
    Effect.pure 21
    |> Effect.map (fun n -> n * 2)
    |> Effect.bind (fun n -> Effect.pure (n + 0))
  in
  match Runtime.run rt program with
  | Exit.Ok 42 -> ()
  | _ -> failwith "real Effet program returned wrong value"
