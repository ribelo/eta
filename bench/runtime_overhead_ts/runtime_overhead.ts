// Bun + TypeScript + Effect reference workloads.
//
// Mirrors bench/runtime_overhead/runtime_overhead.ml so each row here maps
// 1:1 to an OCaml row (overhead.ts.X corresponds to overhead.X). Wall time
// is measured *inside* the Bun process via Bun.nanoseconds(), so Bun startup
// cost is excluded.
//
// Output: one JSON-line per workload, matching the schema emitted by
// bench/lib/bench_lib.ml's emit_measurement (consumed by bench/run.sh and
// bench/compare.ml).

import { Effect, Schedule } from "effect"

// ---------------------------------------------------------------------------
// CLI

interface Opts {
  quick: boolean
  filter: RegExp | null
  filterRaw: string | null
  samples: number
  warmupMs: number
}

function parseArgs(argv: string[]): Opts {
  let quick = false
  let filter: RegExp | null = null
  let filterRaw: string | null = null
  let samples: number | null = null
  let warmupMs: number | null = null
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === "--quick") quick = true
    else if (a === "--filter") {
      filterRaw = argv[++i] ?? ""
      filter = new RegExp(filterRaw)
    } else if (a === "--samples") samples = Number.parseInt(argv[++i] ?? "10", 10)
    else if (a === "--warmup-ms") warmupMs = Number.parseInt(argv[++i] ?? "2000", 10)
    else throw new Error(`unknown bench argument: ${a}`)
  }
  return {
    quick,
    filter,
    filterRaw,
    samples: samples ?? (quick ? 1 : 10),
    warmupMs: warmupMs ?? (quick ? 100 : 2000),
  }
}

function shouldRun(opts: Opts, name: string): boolean {
  if (opts.filter === null) return true
  if (opts.filter.test(name)) return true
  // Mirror bench_lib.ml: also accept '|'-separated literal substrings.
  if (opts.filterRaw && opts.filterRaw.includes("|")) {
    for (const part of opts.filterRaw.split("|")) {
      if (part.length > 0 && name.includes(part)) return true
    }
  }
  return false
}

// ---------------------------------------------------------------------------
// JSON emission (matches bench/lib/bench_lib.ml emit_measurement output)

function jsonString(s: string): string {
  return JSON.stringify(s)
}

function fmtFloat(n: number): string {
  if (!Number.isFinite(n)) return "0"
  return n.toFixed(6)
}

function mean(xs: number[]): number {
  if (xs.length === 0) return 0
  let s = 0
  for (const x of xs) s += x
  return s / xs.length
}

function stddev(xs: number[]): number {
  if (xs.length < 2) return 0
  const m = mean(xs)
  let s = 0
  for (const x of xs) {
    const d = x - m
    s += d * d
  }
  return Math.sqrt(s / (xs.length - 1))
}

function emit(name: string, metric: string, unit: string, samples: number[]): void {
  const samplesJson = samples.map(fmtFloat).join(",")
  process.stdout.write(
    `{"name":${jsonString(name)},"metric":${jsonString(metric)},"unit":${jsonString(unit)},`
      + `"samples":[${samplesJson}],"mean":${fmtFloat(mean(samples))},`
      + `"stddev":${fmtFloat(stddev(samples))},"min":${fmtFloat(Math.min(...samples))},`
      + `"max":${fmtFloat(Math.max(...samples))}}\n`,
  )
}

// ---------------------------------------------------------------------------
// Measurement harness

interface Workload {
  name: string
  run: () => void
  samples?: number
}

// Expose a sink so the optimiser cannot drop the work.
let intSink = 0

function gc(): void {
  // Bun.gc(true) is a synchronous full GC. The fallback is a no-op; the
  // important property is that we *try* to clear the heap between samples,
  // mirroring Gc.compact () in bench_lib.ml.
  const bunGc = (globalThis as { Bun?: { gc?: (sync?: boolean) => void } }).Bun?.gc
  if (typeof bunGc === "function") bunGc(true)
}

function measureOnce(run: () => void): number {
  gc()
  const start = Bun.nanoseconds()
  run()
  const stop = Bun.nanoseconds()
  return stop - start
}

function warmup(run: () => void, warmupMs: number): void {
  if (warmupMs <= 0) {
    run()
    return
  }
  const deadline = Bun.nanoseconds() + warmupMs * 1_000_000
  do {
    run()
  } while (Bun.nanoseconds() < deadline)
}

function runWorkload(opts: Opts, w: Workload): void {
  if (!shouldRun(opts, w.name)) return
  const samples = w.samples ?? opts.samples
  warmup(w.run, opts.warmupMs)
  const walls: number[] = []
  for (let i = 0; i < samples; i++) walls.push(measureOnce(w.run))
  emit(w.name, "wall_ns", "ns", walls)
}

// ---------------------------------------------------------------------------
// Workloads
//
// Constants chosen to match runtime_overhead.ml exactly.

const BIND_N = 100_000
const FAIL_N = 100_000
const ONE = 1

// 1. Direct loops -----------------------------------------------------------

function directLoop(n: number): void {
  let acc = 0
  for (let i = 0; i < n; i++) acc = acc + ONE
  intSink = acc
}

function directClosureBind(n: number): void {
  const bind = <A, B>(x: A, f: (a: A) => B): B => f(x)
  const pure = <A>(x: A): A => x
  let acc = 0
  for (let i = 0; i < n; i++) {
    acc = bind(acc, (x) => pure(x + ONE))
  }
  intSink = acc
}

// 2. Mini interpreter -------------------------------------------------------

type Mini<E, A> =
  | { _tag: "Pure"; value: A }
  | { _tag: "Fail"; err: E }
  | { _tag: "Bind"; left: Mini<E, unknown>; k: (x: unknown) => Mini<E, A> }
  | { _tag: "Catch"; body: Mini<E, A>; handler: (err: E) => Mini<E, A> }

const Pure = <A>(value: A): Mini<never, A> => ({ _tag: "Pure", value })
const Fail = <E>(err: E): Mini<E, never> => ({ _tag: "Fail", err })
const Bind = <E, A, B>(left: Mini<E, A>, k: (x: A) => Mini<E, B>): Mini<E, B> => ({
  _tag: "Bind",
  left: left as Mini<E, unknown>,
  k: k as (x: unknown) => Mini<E, B>,
})
const Catch = <E, A>(body: Mini<E, A>, handler: (err: E) => Mini<E, A>): Mini<E, A> => ({
  _tag: "Catch",
  body,
  handler,
})

type MiniResult<E, A> = { ok: true; value: A } | { ok: false; err: E }

// Frame kinds for the explicit-stack interpreter. The OCaml `run_mini` is
// stack-recursive and survives 100k binds because OCaml frames are tiny and
// the runtime stack is large. JS engines blow up around ~10k recursive
// frames, so we walk the AST with a small frame stack instead. The
// semantics are identical; this is still the smallest "how would you do
// this without a library?" baseline.
type Frame<E, A> =
  | { _tag: "BindK"; k: (x: unknown) => Mini<E, unknown> }
  | { _tag: "CatchH"; handler: (err: E) => Mini<E, unknown> }

function runMini<E, A>(start: Mini<E, A>): MiniResult<E, A> {
  const stack: Frame<E, A>[] = []
  let cur: Mini<E, unknown> = start as Mini<E, unknown>

  // Two states: "evaluating cur" and "unwinding with value/error".
  // After producing a value or error, fold through the frame stack.
  for (;;) {
    // Evaluate `cur` until it produces a value or error.
    descend: for (;;) {
      switch (cur._tag) {
        case "Pure": {
          let value: unknown = cur.value
          // Fold value through frames.
          for (;;) {
            const f = stack.pop()
            if (f === undefined) return { ok: true, value: value as A }
            if (f._tag === "BindK") {
              cur = f.k(value)
              continue descend
            }
            // CatchH: body succeeded, discard handler.
          }
        }
        case "Fail": {
          let err = cur.err as E
          for (;;) {
            const f = stack.pop()
            if (f === undefined) return { ok: false, err }
            if (f._tag === "CatchH") {
              cur = f.handler(err)
              continue descend
            }
            // BindK on the error path: skip.
          }
        }
        case "Bind":
          stack.push({ _tag: "BindK", k: cur.k })
          cur = cur.left
          continue
        case "Catch":
          stack.push({
            _tag: "CatchH",
            handler: cur.handler as (err: E) => Mini<E, unknown>,
          })
          cur = cur.body as Mini<E, unknown>
          continue
      }
    }
  }
}

function miniBindChain(n: number, acc: Mini<never, number>): Mini<never, number> {
  let cur = acc
  for (let i = 0; i < n; i++) cur = Bind(cur, (x: number) => Pure(x + 1))
  return cur
}

function miniFailCatchLoop(n: number): Mini<"Boom", number> {
  // OCaml shape: recursive, each step Catch(Fail Boom, _ -> go (n-1) (acc+1)).
  function go(i: number, acc: number): Mini<"Boom", number> {
    if (i === 0) return Pure(acc) as Mini<"Boom", number>
    return Catch(Fail("Boom" as const), () => go(i - 1, acc + 1))
  }
  return go(n, 0)
}

function runMiniInt(p: Mini<unknown, number>): void {
  const r = runMini(p)
  if (!r.ok) throw new Error("unexpected mini failure")
  intSink = r.value
}

// 3. Effect (real) ---------------------------------------------------------

function effectBindChain(n: number, acc: Effect.Effect<number>): Effect.Effect<number> {
  let cur = acc
  for (let i = 0; i < n; i++) cur = Effect.flatMap(cur, (x) => Effect.succeed(x + 1))
  return cur
}

function effectFailCatchLoop(n: number): Effect.Effect<number> {
  // Same recursion shape as eta_fail_catch_loop in OCaml.
  function go(i: number, acc: number): Effect.Effect<number> {
    if (i === 0) return Effect.succeed(acc)
    return Effect.catch(Effect.fail("Boom" as const), () => go(i - 1, acc + 1))
  }
  return go(n, 0)
}

function runEffectInt(p: Effect.Effect<number>): void {
  intSink = Effect.runSync(p)
}

// 4. runSync hot loop (analogue of overhead.eta.pure.reused_rt) ----------
//
// Effect-TS has no externally created runtime; the per-call cost is what a
// caller pays. We loop runSync(succeed) so the per-op cost is observable
// above the timer floor, then compare against overhead.eta.pure.reused_rt
// per-call by dividing on the analysis side.

function effectRunSyncPureLoop(n: number): void {
  const programs = [Effect.succeed(0), Effect.succeed(1)] as const
  let acc = 0
  for (let i = 0; i < n; i++) acc += Effect.runSync(programs[i & 1])
  intSink = acc
}

// 5. Real-use workloads (mirrored 1:1 with bench/runtime_real/runtime_real.ml)
// ---------------------------------------------------------------------------
//
// Each row exercises a slice of the Eta API for which Effect-v4 has a
// fair counterpart. Workloads are synchronous (no real I/O, no real
// timers) so wall time is dominated by the runtime/interpreter, not by
// the kernel.

// A 50-step bind chain reused as per-task work in the fanout rows.
function work50(): Effect.Effect<number> {
  let acc: Effect.Effect<number> = Effect.succeed(0)
  for (let i = 0; i < 50; i++) acc = Effect.flatMap(acc, (x) => Effect.succeed(x + 1))
  return acc
}

function realuseFanoutPar64x50(): Effect.Effect<number> {
  const tasks: Effect.Effect<number>[] = []
  for (let i = 0; i < 64; i++) {
    tasks.push(Effect.flatMap(work50(), () => Effect.succeed(1)))
  }
  return Effect.map(
    Effect.all(tasks, { concurrency: "unbounded" }) as Effect.Effect<number[]>,
    (xs: number[]) => xs.reduce((a: number, b: number) => a + b, 0),
  )
}

function realuseFanoutBounded512x50K8(): Effect.Effect<number> {
  const tasks: Effect.Effect<number>[] = []
  for (let i = 0; i < 512; i++) {
    tasks.push(Effect.flatMap(work50(), () => Effect.succeed(1)))
  }
  return Effect.map(
    Effect.all(tasks, { concurrency: 8 }) as Effect.Effect<number[]>,
    (xs: number[]) => xs.reduce((a: number, b: number) => a + b, 0),
  )
}

function realuseRetryFlaky(): Effect.Effect<number> {
  // Counter is module-local so it is shared across the 100 inner runs,
  // but reset to 0 before each retry block, matching the OCaml shape.
  const state = { counter: 0 }
  const attempt = Effect.sync(() => {
    state.counter += 1
    return state.counter
  })
  const flaky: Effect.Effect<number, "Boom"> = Effect.flatMap(attempt, (n) =>
    n < 5 ? (Effect.fail("Boom" as const) as Effect.Effect<number, "Boom">) : Effect.succeed(n),
  )
  // Schedule.recurs(n) means "retry up to n times". The flaky op needs
  // four retries, so 10 is more than enough; the schedule terminates
  // because the 5th attempt succeeds.
  const oneRun = Effect.retry(flaky, Schedule.recurs(10))
  // Re-build the loop so each iteration resets the counter via the
  // sync side-effect.
  function loop(remaining: number, acc: number): Effect.Effect<number> {
    if (remaining === 0) return Effect.succeed(acc)
    return Effect.flatMap(
      Effect.sync(() => {
        state.counter = 0
      }),
      () =>
        Effect.flatMap(oneRun, (v: number) => loop(remaining - 1, acc + v)),
    )
  }
  return loop(100, 0)
}

function realusePipelineBindCatch1k(): Effect.Effect<number> {
  // 500 binds, then a fail-and-catch boundary, then 500 more binds.
  let prefix: Effect.Effect<number> = Effect.succeed(0)
  for (let i = 0; i < 500; i++) {
    prefix = Effect.flatMap(prefix, (x: number) => Effect.succeed(x + 1))
  }
  const recovered: Effect.Effect<number> = Effect.flatMap(prefix, (acc: number) =>
    Effect.catch(
      Effect.fail("Boom" as const) as Effect.Effect<number, "Boom">,
      () => Effect.succeed(acc),
    ),
  )
  return Effect.flatMap(recovered, (base: number) => {
    let suffix: Effect.Effect<number> = Effect.succeed(base)
    for (let i = 0; i < 500; i++) {
      suffix = Effect.flatMap(suffix, (x: number) => Effect.succeed(x + 1))
    }
    return suffix
  })
}

function realuseScopeAcquireRelease64(): Effect.Effect<number> {
  const state = { counter: 0 }
  const acquireOne = Effect.acquireRelease(
    Effect.sync(() => {
      state.counter += 1
      return state.counter
    }),
    () =>
      Effect.sync(() => {
        state.counter -= 1
      }),
  )
  function build(depth: number): Effect.Effect<number, never, never> {
    if (depth === 0) return Effect.succeed(0)
    return Effect.flatMap(acquireOne, (v: number) =>
      Effect.map(build(depth - 1), (x: number) => x + v),
    )
  }
  return Effect.with_scope(build(64))
}

function runEffectIgnore<A>(p: Effect.Effect<A>): void {
  intSink = (Effect.runSync(p) as unknown as number) | 0
}

// ---------------------------------------------------------------------------
// Workload assembly

const w = (name: string, run: () => void, samples?: number): Workload => ({
  name: `overhead.ts.${name}`,
  run,
  samples,
})

function directAndMiniWorkloads(): Workload[] {
  const miniBind = miniBindChain(BIND_N, Pure(0))
  const miniFail = miniFailCatchLoop(FAIL_N)
  return [
    w("direct.loop.100k", () => directLoop(BIND_N)),
    w("direct.closure_bind.100k", () => directClosureBind(BIND_N)),
    w("mini.bind.100k.prebuilt", () => runMiniInt(miniBind)),
    w("mini.bind.100k.build_run", () => runMiniInt(miniBindChain(BIND_N, Pure(0)))),
    w("mini.fail_catch.100k.prebuilt", () => runMiniInt(miniFail)),
    w("mini.fail_catch.100k.build_run", () => runMiniInt(miniFailCatchLoop(FAIL_N))),
  ]
}

function effectWorkloads(): Workload[] {
  const effectBind = effectBindChain(BIND_N, Effect.succeed(0))
  const effectFail = effectFailCatchLoop(FAIL_N)
  return [
    // The OCaml row times one runSync of a pure value with a pre-created
    // runtime; on Bun the timer floor is in the tens of nanoseconds so a
    // single call is dominated by jitter. Run a 100k loop and divide on the
    // analysis side, mirroring how the other rows are reported.
    w("effect.runSync_pure.100k", () => effectRunSyncPureLoop(BIND_N)),
    w("effect.bind.100k.prebuilt", () => runEffectInt(effectBind)),
    w("effect.bind.100k.build_run", () => runEffectInt(effectBindChain(BIND_N, Effect.succeed(0)))),
    w("effect.fail_catch.100k.prebuilt", () => runEffectInt(effectFail)),
    w("effect.fail_catch.100k.build_run", () => runEffectInt(effectFailCatchLoop(FAIL_N))),
  ]
}

const rw = (name: string, run: () => void, samples?: number): Workload => ({
  name: `realuse.ts.${name}`,
  run,
  samples,
})

function realuseWorkloads(): Workload[] {
  return [
    rw("fanout.par.success.64x50", () => runEffectIgnore(realuseFanoutPar64x50())),
    rw("fanout.bounded.512x50.k=8", () => runEffectIgnore(realuseFanoutBounded512x50K8())),
    rw("retry.flaky.fail4_then_ok", () => runEffectIgnore(realuseRetryFlaky())),
    rw("pipeline.bind_catch.1k", () => runEffectIgnore(realusePipelineBindCatch1k())),
    rw("scope.acquire_release.64", () => runEffectIgnore(realuseScopeAcquireRelease64())),
  ]
}

// ---------------------------------------------------------------------------
// Main

function main(): void {
  const opts = parseArgs(process.argv.slice(2))
  for (const wl of directAndMiniWorkloads()) runWorkload(opts, wl)
  for (const wl of effectWorkloads()) runWorkload(opts, wl)
  for (const wl of realuseWorkloads()) runWorkload(opts, wl)
  // Touch the sink so the JIT cannot eliminate unread work.
  if (intSink === Number.MAX_SAFE_INTEGER) process.stderr.write("sink hit\n")
}

main()
