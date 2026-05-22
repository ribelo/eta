open! Portable

module Island = struct
  let map_pair (f @ portable) left right =
    let scheduler = Parallel_scheduler.create ~max_domains:2 () in
    Fun.protect
      ~finally:(fun () -> Parallel_scheduler.stop scheduler)
      (fun () ->
        Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
            let #(left, right) =
              Parallel.fork_join2 parallel (fun _ -> f left) (fun _ -> f right)
            in
            (left, right)))
end

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Effet.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) ~env:() ()
  in
  ignore
    (Island.map_pair
       (fun n -> Effet.Runtime.run rt (Effet.Effect.pure n))
       1 2)
