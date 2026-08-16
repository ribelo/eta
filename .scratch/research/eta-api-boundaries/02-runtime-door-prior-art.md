# Runtime-door prior art: ZIO and effect-ts

## Scope

This report uses only `.reference/zio` and `.reference/effect-smol`.

Line ranges refer to the current checkout.

## Key findings

1. ZIO uses `ZIOAppDefault` for simple applications and `ZIOApp` for custom environments.  
   Source: `.reference/zio/core/shared/src/main/scala/zio/ZIOApp.scala:23-49`; `.reference/zio/core/shared/src/main/scala/zio/ZIOAppDefault.scala:39-46`.

2. Effect-ts exposes `Effect.run*` functions and platform-specific `runMain` doors.  
   Source: `.reference/effect-smol/packages/effect/src/Effect.ts:8723-8790,8931-8970,9009-9061,9108-9279`; `.reference/effect-smol/packages/platform-node/src/NodeRuntime.ts:15-52`.

3. ZIO documents one top-level runtime and reuse for many effects with one environment.  
   Source: `.reference/zio/docs/reference/core/runtime.md:95-110,362-366`.

4. Effect-ts provides `ManagedRuntime` for lazy layer construction, cached services, and owned resource scope.  
   Source: `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:221-238`.

5. ZIO maps application success and failure to exit codes `0` and `1`.  
   Source: `.reference/zio/core/jvm-native/src/main/scala/zio/ZIOAppPlatformSpecific.scala:51-69`; `.reference/zio/core/shared/src/main/scala/zio/ExitCode.scala:21-25`.

6. Effect-ts maps success to `0`, interrupt-only failure to `130`, and other failure to `1` or a custom code.  
   Source: `.reference/effect-smol/packages/effect/src/Runtime.ts:68-89,117-124`.

7. ZIO uses a shutdown hook that interrupts the application fiber and waits for shutdown.  
   Source: `.reference/zio/core/jvm-native/src/main/scala/zio/ZIOAppPlatformSpecific.scala:17-49`.

8. The Node effect-ts door interrupts its main fiber on `SIGINT` or `SIGTERM`, then runs teardown.  
   Source: `.reference/effect-smol/packages/platform-node-shared/src/NodeRuntime.ts:42-59`.

## App-facing entry points

### ZIO

An application extends `ZIOAppDefault` and supplies its `run` effect.  
Source: `.reference/zio/docs/overview/running-effects.md:10-29`.

`ZIOAppDefault` fixes `Environment` to `Any` and supplies an empty `bootstrap` layer.  
Source: `.reference/zio/core/shared/src/main/scala/zio/ZIOAppDefault.scala:39-46`.

Custom applications use `ZIOApp` with explicit `Environment`, `bootstrap`, and `run` members.  
Source: `.reference/zio/core/shared/src/main/scala/zio/ZIOApp.scala:28-49`.

On the JVM, `main` builds `workflow` and forks a fiber that runs it and calls `exitUnsafe`.  
Source: `.reference/zio/core/jvm-native/src/main/scala/zio/ZIOAppPlatformSpecific.scala:7-29`.

The lower-level ZIO door is `Runtime.default.unsafe.run`.  
The docs place this door at application edges and legacy integration points.  
Source: `.reference/zio/docs/reference/core/runtime.md:44-66`; `.reference/zio/docs/overview/running-effects.md:35-57`.

### Effect-ts

The public `Effect` module exposes `runFork`, `runPromise`, and `runPromiseExit`.  
Source: `.reference/effect-smol/packages/effect/src/Effect.ts:8757-8790,8931-8970,9009-9061`.

`runFork` returns a fiber that callers can observe or interrupt.  
Source: `.reference/effect-smol/packages/effect/src/Effect.ts:8757-8783`.

`runPromise` resolves on success and rejects with an error on failure.  
Source: `.reference/effect-smol/packages/effect/src/Effect.ts:8931-8963`.

`runPromiseExit` returns a promise that preserves the `Exit` and its `Cause`.  
Source: `.reference/effect-smol/packages/effect/src/Effect.ts:9009-9053`.

`runSync` throws `FiberFailure` for failure, defect, interruption, or asynchronous work.  
Source: `.reference/effect-smol/packages/effect/src/Effect.ts:9108-9166`.

`runSyncExit` captures synchronous failure as an `Exit` instead of throwing.  
Source: `.reference/effect-smol/packages/effect/src/Effect.ts:9207-9279`.

`NodeRuntime.runMain` is the Node process door.  
`BunRuntime.runMain` reuses the shared Node-compatible runner.  
Source: `.reference/effect-smol/packages/platform-node/src/NodeRuntime.ts:1-7,15-52`; `.reference/effect-smol/packages/platform-bun/src/BunRuntime.ts:1-7,14-52`.

`Runtime.makeRunMain` is the lower-level adapter for host-specific doors.  
It supplies a fiber and a teardown function to platform code.  
Source: `.reference/effect-smol/packages/effect/src/Runtime.ts:126-151,201-243`.

## Runtime lifecycle and sharing

### ZIO

`Runtime.default` is a `val` built from an empty environment, empty fiber references, and default flags.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Runtime.scala:245-259`.

ZIO describes one top-level runtime for a whole application.  
It describes local runtime configuration as scoped and restorable.  
Source: `.reference/zio/docs/reference/core/runtime.md:95-118`.

A custom `Runtime[R]` combines an environment, fiber references, and runtime flags.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Runtime.scala:244-259`.

ZIO supports additional custom runtime values, while its application model names one top-level runtime.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Runtime.scala:244-259`; `.reference/zio/docs/reference/core/runtime.md:95-103`.

`Runtime.unsafe.fromLayer` allocates layer resources immediately and releases them at shutdown.  
The source calls this bridge useful for small applications and legacy code.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Runtime.scala:313-338`.

ZIO documents a custom runtime for many effects that require the same environment.  
Source: `.reference/zio/docs/reference/core/runtime.md:362-366`.

These ZIO sources give qualitative reuse guidance, not a numeric runtime-per-call cost.  
Source: `.reference/zio/docs/reference/core/runtime.md:95-110,362-366`.

### Effect-ts

`ManagedRuntime.make` creates a reusable runtime for application entry points and integration code.  
Source: `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:86-107,221-227`.

The layer builds lazily on first use, and the service context is cached for later runs.  
Source: `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:228-233`.

The runtime owns layer resources and releases them during disposal.  
It cannot run again after disposal.  
Source: `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:230-238`.

The implementation uses `cachedContext` to choose layer construction or direct service reuse.  
Source: `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:297-367`.

`Layer.MemoMap` prevents duplicate construction of the same layer instance.  
Source: `.reference/effect-smol/packages/effect/src/Layer.ts:182-191`.

`Effect.provide` shares layers between calls by default.  
Source: `.reference/effect-smol/packages/effect/src/Effect.ts:5822-5825`.

These Effect-ts sources give qualitative reuse guidance, not a numeric runtime-per-call cost.  
Source: `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:221-238`; `.reference/effect-smol/packages/effect/src/Layer.ts:182-191`.

`ManagedRuntime.make` creates a fresh scope and memo map unless the caller supplies one.  
Source: `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:273-281`.

Effect-ts can create multiple managed runtimes, each with its own scope by default.  
Source: `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:273-281`.

An optional memo map shares layer memoization with other layer builds.  
Source: `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:228-233`.

## Boundary error rendering

### ZIO

ZIO represents typed failures, defects, and interruptions as `Fail`, `Die`, and `Interrupt`.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Cause.scala:993-1047`.

`workflow` logs the full `Cause`, except when tests or shutdown suppress that log.  
Source: `.reference/zio/core/shared/src/main/scala/zio/ZIOApp.scala:108-118`.

`ZIO.logErrorCause` passes the cause to the logger.  
The default logger writes `cause.prettyPrint` into the `cause` field.  
Source: `.reference/zio/core/shared/src/main/scala/zio/ZIO.scala:4229-4242`; `.reference/zio/core/shared/src/main/scala/zio/ZLogger.scala:110-141`.

`FiberFailure.toString` and both stack-print methods use `Cause.prettyPrint`.  
Source: `.reference/zio/core/shared/src/main/scala/zio/FiberFailure.scala:31-49`.

`prettyPrint` emits each rendered class, message, and trace.  
It groups defects, typed failures, and interruptions in that order.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Cause.scala:502-548`.

For a typed non-Throwable failure, rendering uses its class name and `toString` value.  
For a typed Throwable failure, rendering uses its class and message.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Cause.scala:711-718`.

For a defect, rendering uses the Throwable class, message, and trace.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Cause.scala:693-721`.

For an interruption, rendering uses `InterruptedException` and the interrupting thread name.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Cause.scala:723-727`.

ZIO also provides `Cause.squashWith` for a lossy thrown boundary.  
It selects the first typed failure, then any interruption, then the first defect.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Cause.scala:573-594`.

### Effect-ts

Effect-ts represents typed failures, defects, and interruptions as `Fail`, `Die`, and `Interrupt`.  
Source: `.reference/effect-smol/packages/effect/src/Cause.ts:118-146`.

`runPromise` throws `Cause.squash` when the fiber exits with failure.  
`runSync` applies the same conversion.  
Source: `.reference/effect-smol/packages/effect/src/internal/effect.ts:5303-5355`.

`Cause.squash` selects the first typed failure, then the first defect, then a generic interruption error.  
Source: `.reference/effect-smol/packages/effect/src/Cause.ts:717-734`; `.reference/effect-smol/packages/effect/src/internal/effect.ts:299-308`.

`Cause.pretty` converts each reason to an `Error` and joins its stack traces.  
Nested error causes appear inline with indentation.  
Source: `.reference/effect-smol/packages/effect/src/Cause.ts:1113-1157`; `.reference/effect-smol/packages/effect/src/internal/effect.ts:460-476`.

For objects and Error values, `prettyErrors` keeps the name, message, stack, cause, and extra properties.  
Source: `.reference/effect-smol/packages/effect/src/Cause.ts:1080-1087`.

Strings become Error messages, while other primitive values are wrapped for display.  
Source: `.reference/effect-smol/packages/effect/src/Cause.ts:1080-1087`; `.reference/effect-smol/packages/effect/src/internal/effect.ts:348-377`.

An interrupt-only cause becomes an `InterruptError` with the interrupting fiber IDs.  
Source: `.reference/effect-smol/packages/effect/src/Cause.ts:1089-1093`; `.reference/effect-smol/packages/effect/src/internal/effect.ts:321-341`.

`makeRunMain` logs unreported non-interruption causes through `Effect.logError`.  
Source: `.reference/effect-smol/packages/effect/src/Runtime.ts:223-243`.

Effect's log formatter writes `Cause.pretty(cause)` into the `cause` field.  
Source: `.reference/effect-smol/packages/effect/src/Logger.ts:389-417`.

The Node door documents pretty error output by default.  
Source: `.reference/effect-smol/packages/platform-node/src/NodeRuntime.ts:15-30`.

## Exit codes and interruption

### ZIO

`ExitCode.success` is `0`, and `ExitCode.failure` is `1`.  
Source: `.reference/zio/core/shared/src/main/scala/zio/ExitCode.scala:21-25`.

The JVM door maps every non-success application exit to `ExitCode.failure`.  
Source: `.reference/zio/core/jvm-native/src/main/scala/zio/ZIOAppPlatformSpecific.scala:51-69`.

The JVM shutdown hook interrupts the application fiber and waits for finalizers.  
The wait uses `gracefulShutdownTimeout`.  
Source: `.reference/zio/core/jvm-native/src/main/scala/zio/ZIOAppPlatformSpecific.scala:17-49`; `.reference/zio/core/shared/src/main/scala/zio/ZIOApp.scala:51-57`.

During shutdown, `workflow` skips an interruption-only log.  
Source: `.reference/zio/core/shared/src/main/scala/zio/ZIOApp.scala:111-115`.

On the JVM, `Platform.addShutdownHook` registers a Java shutdown hook.  
Source: `.reference/zio/core/jvm/src/main/scala/zio/internal/PlatformSpecific.scala:23-35`.

On Scala Native, shutdown hooks and signal handlers are no-ops.  
Source: `.reference/zio/core/native/src/main/scala/zio/internal/PlatformSpecific.scala:24-42`.

### Effect-ts

`defaultTeardown` returns `0` for success and `130` for interrupt-only failure.  
It returns a marked error code or `1` for other failures.  
Source: `.reference/effect-smol/packages/effect/src/Runtime.ts:68-89,117-124`.

Mixed causes do not receive `130`; the teardown uses the squashed-error path.  
Source: `.reference/effect-smol/packages/effect/src/Runtime.ts:78-89,117-124`.

The Node door handles `SIGINT` and `SIGTERM` by interrupting the main fiber.  
It removes signal listeners, calls teardown, and exits on a signal or nonzero code.  
Source: `.reference/effect-smol/packages/platform-node-shared/src/NodeRuntime.ts:42-59`.

The generic run options also accept an `AbortSignal`.  
Aborting that signal interrupts the running fiber.  
Source: `.reference/effect-smol/packages/effect/src/Effect.ts:8727-8755`; `.reference/effect-smol/packages/effect/src/internal/effect.ts:5205-5229`.

## Direct comparison

ZIO centers the application door on a trait, while Effect-ts separates effect runners from platform doors.  
Source: `.reference/zio/core/shared/src/main/scala/zio/ZIOApp.scala:23-49`; `.reference/effect-smol/packages/effect/src/Effect.ts:8723-8790`; `.reference/effect-smol/packages/effect/src/Runtime.ts:126-151`.

Both libraries support reusable service environments with scoped resource ownership.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Runtime.scala:313-338`; `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:221-238`.

ZIO's default application codes are coarse, while Effect-ts gives interruption its conventional `130` code.  
Source: `.reference/zio/core/shared/src/main/scala/zio/ExitCode.scala:21-25`; `.reference/effect-smol/packages/effect/src/Runtime.ts:78-89`.

Both libraries expose structured causes and also provide lossy collapse operations.  
Source: `.reference/zio/core/shared/src/main/scala/zio/Cause.scala:573-594`; `.reference/effect-smol/packages/effect/src/Cause.ts:717-756`.

## Worth stealing

1. Give Eta one Eio-based main door that owns the root fiber, cause logging, teardown, and exit mapping.  
   Source: `.reference/zio/core/shared/src/main/scala/zio/ZIOApp.scala:100-118`; `.reference/effect-smol/packages/effect/src/Runtime.ts:126-151,201-243`.

2. Keep the core door host-neutral, and put signal registration in an Eio platform adapter.  
   Source: `.reference/effect-smol/packages/effect/src/Runtime.ts:126-151`; `.reference/effect-smol/packages/platform-node-shared/src/NodeRuntime.ts:42-59`.

3. Keep `Cause` intact for diagnostics, and expose lossy collapse only at explicit exception or text boundaries.  
   Source: `.reference/zio/core/shared/src/main/scala/zio/Cause.scala:502-594`; `.reference/effect-smol/packages/effect/src/Cause.ts:717-756,1113-1157`.

4. Render typed failures, `Die`, and `Interrupt` as separate cause entries before any squash.  
   Source: `.reference/zio/core/shared/src/main/scala/zio/Cause.scala:502-548,711-727`; `.reference/effect-smol/packages/effect/src/Cause.ts:118-146,1113-1157`.

5. Use one application scope for shared Eio resources, build services lazily, cache them, and close them once.  
   Source: `.reference/zio/core/shared/src/main/scala/zio/Runtime.scala:313-338`; `.reference/effect-smol/packages/effect/src/ManagedRuntime.ts:221-238`.

6. Treat process signals as fiber interruption, wait for cleanup, suppress interruption-only logs, and return a conventional interrupt code.  
   Source: `.reference/zio/core/jvm-native/src/main/scala/zio/ZIOAppPlatformSpecific.scala:17-49`; `.reference/zio/core/shared/src/main/scala/zio/ZIOApp.scala:111-115`; `.reference/effect-smol/packages/effect/src/Runtime.ts:117-124`; `.reference/effect-smol/packages/platform-node-shared/src/NodeRuntime.ts:42-59`.

7. Offer a cause-preserving run-to-exit API beside convenience runners that raise or squash failures.  
   Source: `.reference/zio/core/shared/src/main/scala/zio/Runtime.scala:71-90`; `.reference/effect-smol/packages/effect/src/Effect.ts:9009-9061,9207-9279`.

8. Allow selected typed failures to carry explicit process exit codes, while ordinary failures use the default failure code.  
   Source: `.reference/effect-smol/packages/effect/src/Runtime.ts:266-340`.
