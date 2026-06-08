(* Negative: the shipped abstract type [('env,'err,'a) Effet.Effect.t]
   has no portable kind annotation, so OxCaml refuses to ship it across
   a Parallel domain boundary. Mainline OCaml has no compiler-checked
   way to even ask this question; the runtime would silently corrupt
   or crash on cross-domain access.

   Expected: this fixture does NOT compile. The error is the static
   evidence that today's Effet AST is fiber-only, AND that OxCaml is
   the only toolchain that can MAKE it domain-safe. *)

open! Portable

let bad () =
  let scheduler = Parallel_scheduler.create ~max_domains:2 () in
  Fun.protect
    ~finally:(fun () -> Parallel_scheduler.stop scheduler)
    (fun () ->
      let program : (unit, [ `Never ], int) Effet.Effect.t =
        Effet.Effect.pure 42
      in
      Parallel_scheduler.parallel scheduler ~f:(fun parallel ->
          let #(a, b) =
            Parallel.fork_join2
              parallel
              (fun _ -> program)
              (fun _ -> program)
          in
          ignore (a, b)))

let () = bad ()
