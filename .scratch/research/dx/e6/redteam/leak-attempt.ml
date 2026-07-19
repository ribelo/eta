open Eta

(* A careless reader predicts that [release1] will not run because [acquire2]
   fails before the body begins. *)
let program releases =
  Effect.Scoped.with_2
    ~acquire1:(Effect.pure "open-pool")
    ~release1:(fun _ ->
      Effect.sync (fun () -> releases := !releases + 1))
    ~acquire2:(Effect.fail `Cache_unavailable)
    ~release2:(fun _ -> Effect.unit)
    (fun _pool _cache -> Effect.unit)

(* VERDICT: the leak attempt fails. The exit is [Fail `Cache_unavailable], the
   body does not run, and [release1] runs exactly once as the enclosing scope
   closes. The deterministic executable proof is
   [test_scoped_with_2_partial_acquire_failure_releases_once] in
   [test/core_common/effect_resource_timeout_common_suites.ml]. *)
