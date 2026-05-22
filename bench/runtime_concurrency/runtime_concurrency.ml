open Eta

let run_effect program =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  ignore (Runtime.run rt program : (_, _) Exit.t)

let work n =
  let rec go i acc =
    if i = 0 then acc
    else go (i - 1) (Effect.bind (fun x -> Effect.pure (x + 1)) acc)
  in
  go n (Effect.pure 0)

let all n = Effect.all (List.init n (fun _ -> Effect.pure 1))
let all_heavy n = Effect.all (List.init n (fun _ -> work 100))

let supervisor_start_await n ~with_finalizer =
  Supervisor.scoped
    {
      run =
        (fun sup ->
          let open Supervisor.Scope in
          let child_effect =
            if with_finalizer then
              lift
                (Effect.scoped
                   (Effect.acquire_release ~acquire:(Effect.pure 1)
                      ~release:(fun _ -> Effect.unit)))
            else lift (work 10)
          in
          let rec loop i =
            if i = 0 then pure ()
            else
              let* child = start sup child_effect in
              let* _ = await child in
              loop (i - 1)
          in
          loop n);
    }

let workloads =
  let item name run =
    { Bench_lib.name = "effect.concurrency." ^ name; run; samples = None }
  in
  [
    item "par.success.2" (fun () ->
        run_effect (Effect.par (Effect.pure 1) (Effect.pure 2)));
    item "par.success.heavy" (fun () -> run_effect (Effect.par (work 1_000) (work 1_000)));
    item "all.2" (fun () -> run_effect (all 2));
    item "all.8" (fun () -> run_effect (all 8));
    item "all.64" (fun () -> run_effect (all 64));
    item "all.heavy.2" (fun () -> run_effect (all_heavy 2));
    item "all.heavy.8" (fun () -> run_effect (all_heavy 8));
    item "all.heavy.64" (fun () -> run_effect (all_heavy 64));
    item "for_each_par.8" (fun () ->
        run_effect (Effect.for_each_par (List.init 8 Fun.id) (fun _ -> work 100)));
    item "for_each_par.64" (fun () ->
        run_effect (Effect.for_each_par (List.init 64 Fun.id) (fun _ -> work 100)));
    item "for_each_par.512" (fun () ->
        run_effect (Effect.for_each_par (List.init 512 Fun.id) (fun _ -> work 100)));
    item "for_each_par_bounded.512.1" (fun () ->
        run_effect
          (Effect.for_each_par_bounded ~max:1 (List.init 512 Fun.id) (fun _ -> work 100)));
    item "for_each_par_bounded.512.2" (fun () ->
        run_effect
          (Effect.for_each_par_bounded ~max:2 (List.init 512 Fun.id) (fun _ -> work 100)));
    item "for_each_par_bounded.512.4" (fun () ->
        run_effect
          (Effect.for_each_par_bounded ~max:4 (List.init 512 Fun.id) (fun _ -> work 100)));
    item "for_each_par_bounded.512.8" (fun () ->
        run_effect
          (Effect.for_each_par_bounded ~max:8 (List.init 512 Fun.id) (fun _ -> work 100)));
    item "race.success" (fun () ->
        run_effect
          (Effect.race
             [ Effect.sync "race.fast" (fun () -> 1); Effect.sync "race.slow" (fun () -> 2) ]));
    item "race.all_fail" (fun () ->
        run_effect (Effect.race [ Effect.fail `Left; Effect.fail `Right ]));
    item "supervisor.start_await.1" (fun () ->
        run_effect (supervisor_start_await 1 ~with_finalizer:false));
    item "supervisor.start_await.64" (fun () ->
        run_effect (supervisor_start_await 64 ~with_finalizer:false));
    item "supervisor.start_await.64.with_finalizer" (fun () ->
        run_effect (supervisor_start_await 64 ~with_finalizer:true));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
