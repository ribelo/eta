open Eta

type stats = {
  processed : int;
  bytes : int;
  max_batch : int;
}

type error = [ `Unexpected ] [@@deriving eta_error]

let empty = { processed = 0; bytes = 0; max_batch = 0 }

let record stats batch =
  Effect.sync (fun () ->
      Mutable_ref.update_and_get stats (fun current ->
          {
            processed = current.processed + 1;
            bytes = current.bytes + batch;
            max_batch = max current.max_batch batch;
          }))

let program () =
  let open Syntax in
  let stats = Mutable_ref.make empty in
  let batches = [ 128; 64; 256; 32 ] in
  let* snapshots = Effect.map_par ~max_concurrent:2 (record stats) batches in
  let final = Mutable_ref.get stats in
  let previous = Mutable_ref.get_and_set stats empty in
  let after_reset = Mutable_ref.get stats in
  Effect.pure (snapshots, final, previous, after_reset)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program ()) with
  | Exit.Ok (snapshots, final, previous, after_reset) -> (
      match
        ( final.processed,
          final.bytes,
          final.max_batch,
          previous.processed,
          after_reset.processed,
          List.length snapshots )
      with
      | 4, 480, 256, 4, 0, 4 ->
          Format.printf
            "mutable-ref:processed=%d bytes=%d max=%d reset=%d snapshots=%d@."
            final.processed final.bytes final.max_batch after_reset.processed
            (List.length snapshots)
      | _ ->
          Format.eprintf "mutable ref produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "mutable ref failed: %a@." (Cause.pp pp_error) cause;
      exit 1
