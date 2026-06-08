module Switch_local = struct
  type t = { raw : Eio.Switch.t }

  let run (body : t @ local -> 'a) =
    Eio.Switch.run (fun sw -> body { raw = sw })

  let fail t exn =
    Eio.Switch.fail t.raw exn
end

let bad () =
  Eio_main.run @@ fun _env ->
  let leaked = ref None in
  Switch_local.run (fun sw -> leaked := Some sw);
  match !leaked with
  | None -> ()
  | Some sw -> Switch_local.fail sw (Failure "use after free")

let () = bad ()
