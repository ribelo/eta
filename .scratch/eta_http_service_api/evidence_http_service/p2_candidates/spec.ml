(* Shared spec for the P2 comparison.

   Every branch (A/B/C/D) must implement [service_under_test] that satisfies the
   SAME behavioral contract, so we compare apples-to-apples on the same
   inn-shaped workload. The workload is a deliberately small slice of `inn`:

     GET  /health            -> 200 "ok"
     GET  /items/{id}        -> 200 {"id":<id>,"name":"widget-<id>"}   (param route)
     POST /items             -> 201 {"id":..,"name":..}                (JSON body decode)
                                 409 conflict if id exists
                                 400 on bad JSON / schema error
     PUT  /items/{id}        -> 405 method-not-allowed (proves 405 path)
     GET  /nope              -> 404 not-found
     *    anything else      -> 404

   Each branch then provides [run_assertions rt] exercising this with a
   handler-only test (no socket). The branch is judged on:
     - call-site LOC to express this contract;
     - how the params / JSON / 405 / 404 are spelled;
     - whether the typed-failure channel is preserved or abandoned;
     - depth: does the module centralize a real invariant, or rename primitives? *)
