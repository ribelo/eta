# Deferred Fanout Optimization Ideas

- Specialize `Effect.for_each_par_bounded` to launch only `max` worker fibers
  instead of forking every input and gating on `Eio.Semaphore`.
- Replace `par_collect`'s `Array.make n None` + `Some` per child +
  `Array.to_list |> List.map Option.get` with a lower-allocation ordered result
  collector, while preserving failure semantics.
- Profile `frame.runtime.tracer#with_fiber_context` in child fibers and add a
  no-op tracer fast path only if it is visible in fanout benchmarks.
- Consider direct implementations of `for_each_par` and `for_each_par_bounded`
  instead of routing both through `all`, if that removes list/task allocation in
  the real fanout rows.
