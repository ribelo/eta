# ZIO Invariants

Each invariant is a single-line checkbox statement. No ordering — removing or reordering entries must not break the file. Invariants may be expressed as code assertions or as prose descriptions.

Format: `- [ ] <invariant description>`

Examples:
- [ ] ZIO.fail(e).fold(_ => None, _ => Some(())) must return None
- [ ] every fiber has exactly one interruption cause
- [ ] scope closure runs in LIFO order

---


# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZIO.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/ZStream.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Chunk.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed/shared/src/main/scala/zio/managed/ZManaged.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/ZPipeline.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZLayer.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/ZChannel.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/ZSTM.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Schedule.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/ZSink.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/FiberRuntime.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Cause.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Fiber.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/internal/ChannelExecutor.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/jvm/src/main/scala/zio/stream/platform.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TMap.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/metrics/Metric.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/FiberRef.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZEnvironment.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Differ.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Queue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Hub.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/ConcurrentWeakHashSet.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/native/src/main/scala/zio/stream/platform.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/FiberRefs.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/THub.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Ref.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/NonEmptyChunk.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/STM.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Zippable.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TArray.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/macros/LayerBuilder.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed/shared/src/main/scala/zio/managed/package.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZPool.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Unzippable.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Scope.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Runtime.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Promise.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Supervisor.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/UpdateOrderLinkedMap.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TReentrantLock.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TQueue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TSemaphore.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZLogger.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/RuntimeFlags.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZIOAspect.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TPriorityQueue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/compression/Gunzipper.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Semaphore.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/js/src/main/scala/zio/stream/platform.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TSet.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/WeakConcurrentBag.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Duration.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TRef.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZIOApp.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/metrics/MetricKey.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZKeyedPool.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/FiberId.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/RuntimeFlag.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/Stack.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/MutableConcurrentQueue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/metrics/ConcurrentMetricRegistry.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/impls/PartitionedRingBuffer.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/metrics/PollingMetric.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/Take.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/benchmarks/src/main/scala/zio/stm/TReentrantLockBenchmark.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/FiberScope.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TDequeue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Executor.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/Hub.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/FastList.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/IsFatal.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Dequeue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/internal/ZInputStream.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/internal/ZReader.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/ZStreamAspect.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/PinchableArray.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/SingleThreadedRingBuffer.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/OneElementConcurrentQueue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZLayerAspect.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ScopedRef.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/impls/PartitionedLinkedQueue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/compression/Gzipper.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Enqueue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/metrics/MetricKeyType.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/benchmarks/src/main/scala/zio/stm/TArrayOpsBenchmarks.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed/jvm/src/main/scala/zio/managed/ZManagedCompatPlatformSpecific.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/impls/LinkedQueue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/macros/RenderedGraph.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/Inflate.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed/jvm/src/main/scala/zio/managed/ZManagedPlatformSpecific.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/LogLevel.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TEnqueue.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Trace.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/StackTrace.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Cached.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/macros/Graph.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/FiberRenderer.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/jvm-native/src/main/scala-3/zio/stm/ZSTMLockSupport.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/jvm-native/src/main/scala-2/zio/stm/ZSTMLockSupport.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/compression/Deflate.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZInputStream.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZIOAppDefault.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Scheduler.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/SubscriptionRef.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/Deflate.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/package.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/benchmarks/src/main/scala/zio/stm/TMapOpsBenchmarks.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/benchmarks/src/main/scala/zio/stm/TMapContentionBenchmarks.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed/shared/src/main/scala/zio/managed/ZManagedAspect.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/benchmarks/src/main/scala/zio/stm/SemaphoreBenchmark.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/metrics/MetricState.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/compression/CompressionParameters.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/FiberFailure.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/metrics/MetricClient.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/TPromise.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/InterruptStatus.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/CancelableFuture.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ExecutionStrategy.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/benchmarks/src/main/scala/zio/stm/STMFlatMapBenchmark.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/benchmarks/src/main/scala/zio/stm/SingleRefBenchmark.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/macros/LayerTree.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/DefaultServices.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/metrics/MetricPair.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/LogSpan.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/package.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/Unsafe.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/StackTraceBuilder.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/Gzip.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed/js/src/main/scala/zio/managed/ZManagedCompatPlatformSpecific.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/Gunzip.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed/native/src/main/scala/zio/managed/ZManagedCompatPlatformSpecific.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/FiberMessage.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/benchmarks/src/main/scala/zio/stm/STMRetryBenchmark.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZOutputStream.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/metrics/MetricHook.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ZIOAppArgs.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/RingBufferPow2.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/metrics/package.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/macros/StringUtils.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/RingBufferArb.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/FutureTransformCompat.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/benchmarks/src/main/scala/zio/stm/TSetOpsBenchmarks.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/IsSubtype.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/UniqueKey.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/encoding/EncodingException.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/compression/CompressionException.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/stm/package.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/NonEmptyOps.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/metrics/MetricLabel.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/ExitCode.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/metrics/MetricEventType.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/js/src/main/scala/zio/stm/ZSTMLockSupport.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/LogAnnotation.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/Platform.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed/native/src/main/scala/zio/managed/ZManagedPlatformSpecific.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed/js/src/main/scala/zio/managed/ZManagedPlatformSpecific.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/EitherCompat.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams/shared/src/main/scala/zio/stream/internal/CharacterSet.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/macros/GraphError.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/metrics/ConcurrentMetricHooks.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala-2.12/zio/stm/ZSTMUtils.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala-2.13+/zio/stm/ZSTMUtils.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/metrics/MetricListener.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/macros/DummyK.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/HasNoScope.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/NonEmptySeq.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/FiberRunnable.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/SpecializationHelpers.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/internal/macros/Node.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core/shared/src/main/scala/zio/UpdateRuntimeFlagsWithinPlatformSpecific.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/ZStreamSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZIOSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed-tests/shared/src/test/scala/zio/managed/ZManagedSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/ZSTMSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/ZSinkSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/ZChannelSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/QueueSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ChunkSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/TArraySpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/HubSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ScheduleSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZLayerSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/RuntimeBootstrapTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/TextCodecPipelineSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/FiberRefSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/TMapSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/THubSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/HubSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/ZPipelineSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/DurationSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ChunkBufferSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/CauseSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm/src/test/scala/zio/stream/ZStreamPlatformSpecificSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/RingBufferPow2ConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/RingBufferArbConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/RefSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZIOLazinessSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/IsReloadableSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZLayerDerivationSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/TSetSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/SerializableSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/StreamLazinessSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/js/src/test/scala/zio/stream/ZStreamPlatformSpecificSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/ZChannelSimulatedChecks.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/BlockingSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/interop/JavaSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/TSemaphoreSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/BitChunkByteSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZPoolSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/SupervisorSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ConfigSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/OneElementConcurrentQueueConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/PromiseSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/FiberRefsSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/FiberRuntimeSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/TagCorrectnessSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/RefSynchronizedSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/FiberSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ChunkBuilderSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed-tests/jvm/src/test/scala/zio/managed/ZManagedPlatformSpecificSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm-native/src/test/scala/zio/stream/ZStreamPlatformSpecific2Spec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/TQueueSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/RTSSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm/src/test/scala/zio/stream/GunzipSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/stm/ZSTMConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm/src/test/scala/zio/stream/compression/TestData.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/ZStreamAspectSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/RuntimeFlagsSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/TPriorityQueueSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZEnvironmentSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/TReentrantLockSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ScopeSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/CancelableFutureSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/metrics/MetricListenerSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ThreadLocalBridgeSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/NonEmptyChunkSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ChunkPackedBooleanSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm/src/test/scala/zio/stream/InflateSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ExecutorSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/RuntimeSpecJVM.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/ConcurrentWeakHashSetSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/internal/OneShotSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm/src/test/scala/zio/stream/ZPipelinePlatformSpecificSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/js/src/test/scala/zio/interop/JSSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/SemaphoreSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/StackSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ConfigProviderAppArgsSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/LoggingSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZIOAppSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ScopedRefSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/metrics/ConcurrentSummarySpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/BitChunkLongSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/BitChunkIntSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/ZIOSpecJVM.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/PinchableArraySpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/PartitionedRingBufferSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/HubConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/ZStreamGen.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/RandomSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/BitChunkApplyBugSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZKeyedPoolSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/TRandomSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/WeakConcurrentBagSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ConfigProviderEnvSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/UnboundedHubConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/BoundedHubPow2ConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/BoundedHubArbConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/DifferSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ClockSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/UpdateOrderLinkedMapSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm/src/test/scala/zio/stream/DeflateSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/FastListSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm/src/test/scala/zio/stream/GzipSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ChunkAsStringSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/metrics/MetricsSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/MutableConcurrentQueueSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/SubscriptionRefSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/ConcurrentWeakHashSetSpecJVM.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/SinkUtils.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm/src/test/scala/zio/stream/ZSinkPlatformSpecificSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/managed-tests/shared/src/test/scala/zio/managed/ZIOBaseSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/SystemSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZIOBaseSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/ZIOBaseSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/MutableConcurrentQueueSpecJVM.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/IsFatalSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/interop/JavaSpecJVM.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ReloadableSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/UpdateOrderLinkedMapConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/js/src/test/scala/zio/internal/OneShotSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/RuntimeSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm/src/test/scala/zio/stream/RechunkSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/internal/BoundedHubSingleConcurrencyTests.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/FiberRefSpecJvm.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/CancelableFutureSpecJVM.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/zio/stream/ZStreamParallelErrorsIssuesSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/ClockSpecJVM.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/stacktracer/TracerUtilsSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/jvm-native/src/test/scala/zio/stream/ZSinkPlatformSpecific2Spec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZEnvironmentIssuesSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/CanFailSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/CachedSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/stm/ZSTMJvmSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/internal/PartitionedLinkedQueueSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/FiberIdSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/TaggedSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/stm/STMLazinessSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/repl/REPLSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm/src/test/scala/zio/MetricsSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/jvm-native/src/test/scala/zio/internal/SingleThreadedRingBufferSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/streams-tests/shared/src/test/scala/StreamREPLSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/UnsafeSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/PackageSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/BracketTypeInferrenceSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZStateSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ZIOAspectSpec.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/LatchOps.scala





# /home/ribelo/projects/ribelo/ocaml/Eta/.reference/zio/core-tests/shared/src/test/scala/zio/ImportlessSpec.scala






# Invariants extracted from ZIO.scala

- [x] ZIO.succeed(v).map(f) must return ZIO.succeed(f(v))
- [x] ZIO.fail(e).map(f) must still fail with e
- [x] ZIO.succeed(v).flatMap(f) must be equivalent to f(v)
- [x] ZIO.fail(e).flatMap(f) must still fail with e without calling f
- [x] ZIO.fail(e).catchAll(h) must call h(e)
- [x] ZIO.succeed(v).catchAll(h) must return v without calling h
- [x] effect.catchSome(pf) must only recover from errors matching pf
- [x] effect.catchAllCause(k) must recover from failures, defects, and interruptions
- [x] effect.catchSomeCause(pf) must only recover from causes matching pf
- [x] effect.orElse(that) must run that if effect fails
- [x] effect.orElse(that) must not run that if effect succeeds
- [x] effect.orElseSucceed(a1) must succeed with a1 if effect fails
- [x] effect.orElseFail(e1) must fail with e1 if effect fails
- [x] effect.either must convert failure to Left and success to Right
- [x] effect.absolve on Left must fail, on Right must succeed
- [x] effect.flip must swap error and success channels
- [x] effect.flipWith(f) must apply f with swapped channels then swap back
- [x] effect.fold(failure, success) must handle both cases producing non-effectful value
- [x] effect.foldCause(failure, success) must handle full Cause including defects
- [x] effect.foldZIO(failure, success) must handle both cases producing effectful value
- [x] effect.foldCauseZIO(failure, success) must handle full Cause including defects effectfully
- [x] effect.exit must convert to Exit value without failing
- [x] effect.sandbox must expose full Cause in error channel
- [x] effect.unsandbox must submerge Cause back into typed error
- [x] effect.uninterruptible must prevent external interruption
- [x] effect.interruptible must restore interruptibility inside uninterruptible region
- [x] effect.uninterruptibleMask(restore) must allow restoring interruptibility via restore
- [ ] effect.disconnect must allow interruption to return immediately while cleanup runs in background
- [ ] effect.fork must create child fiber attached to parent scope
- [ ] effect.forkDaemon must create fiber in global scope surviving parent termination
- [ ] effect.forkIn(scope) must interrupt fiber when scope closes
- [ ] effect.forkScoped must interrupt fiber when enclosing scope closes
- [ ] fiber.join must resume with the fiber's Exit value
- [ ] fiber.interrupt must terminate the fiber and return its Exit
- [ ] fiber.interruptAs(fiberId) must terminate with interruption cause from fiberId
- [x] effect.ensuring(finalizer) must run finalizer whether effect succeeds, fails, or is interrupted
- [x] effect.onExit(cleanup) must run cleanup with Exit value on success, failure, or interruption
- [x] effect.onInterrupt(cleanup) must run cleanup only when effect is interrupted
- [x] effect.onTermination(cleanup) must run cleanup on defects and interruptions but not typed failures
- [x] effect.onError(cleanup) must run cleanup on failure but not interrupt cleanup
- [x] effect.race(that) must return first successful result, interrupt loser
- [x] effect.race(that) must fail if both fail, combining causes
- [ ] effect.raceWith(that)(leftDone, rightDone) must call appropriate callback with winner and loser fiber
- [x] effect.raceFirst(that) must return first result (success or failure), interrupt other
- [x] effect.raceAll(ios) must return first success, interrupt all losers
- [x] effect.zipWithPar(that)(f) must run both in parallel, combine results
- [x] effect.zipWithPar(that)(f) must interrupt other side if one fails
- [x] effect.zipWithPar(that)(f) must combine causes if both fail
- [x] effect.validate(that) must combine causes if both fail (unlike zipWithPar)
- [x] effect.validatePar(that) must run in parallel and combine causes if both fail
- [x] effect.timeout(d) must return None if d elapses before effect completes
- [x] effect.timeout(d) must return Some(a) if effect completes within d
- [x] effect.timeout(d) must interrupt effect if timeout elapses
- [x] effect.timeoutTo(default)(f)(d) must return default on timeout, f(a) on success
- [x] effect.delay(duration) must wait before executing
- [x] effect.forever must repeat effect indefinitely until failure
- [x] effect.repeat(schedule) must repeat according to schedule until first failure
- [x] effect.repeatN(n) must repeat exactly n additional times on success
- [x] effect.repeatUntil(p) must repeat until predicate is satisfied
- [x] effect.repeatWhile(p) must repeat while predicate is satisfied
- [x] effect.retry(policy) must retry on failure according to schedule
- [x] effect.retryN(n) must retry up to n times on failure
- [x] effect.retryUntil(f) must retry until error satisfies predicate
- [x] effect.retryWhile(f) must retry while error satisfies predicate
- [x] effect.eventually must retry indefinitely until success
- [x] effect.absorb must convert defects into typed errors
- [x] effect.absorbWith(f) must convert defects using f
- [x] effect.orDie must convert typed errors into defects
- [x] effect.orDieWith(f) must convert typed errors using f
- [x] effect.resurrect must convert defects back into typed errors
- [x] effect.refineOrDie(pf) must refine matching errors, die on non-matching
- [x] effect.unrefine(pf) must convert matching defects into typed errors
- [x] effect.unrefineWith(pf)(f) must convert matching defects using pf, others using f
- [x] effect.debug must print success value to stdout
- [x] effect.debug(prefix) must print prefixed success or failure to stdout
- [x] effect.tap(f) must run f on success value, then return original value
- [x] effect.tapError(f) must run f on error, then fail with original error
- [x] effect.tapBoth(f, g) must run f on error or g on success, preserve original result
- [x] effect.tapErrorCause(f) must run f on cause, then fail with original cause
- [x] effect.tapDefect(f) must run f on defects only, preserve original result
- [x] effect.tapEither(f) must run f with Either result, preserve original result
- [x] effect.tapSome(pf) must run pf on success if defined, preserve original result
- [x] effect.accumulateErrors must collect all errors from parallel operations
- [x] effect.parallelErrors must lift all parallel errors into a single error value
- [x] effect.supervised(supervisor) must report child fibers to supervisor
- [x] effect.daemonChildren must detach child fibers from parent scope
- [x] effect.awaitAllChildren must wait for all child fibers before succeeding
- [x] effect.interruptAllChildren must interrupt all child fibers before succeeding
- [x] effect.ensuringChildren(f) must call f with all child fibers on completion
- [x] effect.memoize must cache result and return same value on subsequent evaluations
- [x] effect.cached(ttl) must cache result and invalidate after ttl
- [x] effect.once must execute effect at most once even if evaluated multiple times
- [x] effect.ignore must convert any result to unit
- [x] effect.ignoreLogged must log failures at Debug level then return unit
- [x] effect.isFailure must return true if effect fails, false if succeeds
- [x] effect.isSuccess must return true if effect succeeds, false if fails
- [x] effect.negate must negate boolean success value
- [x] effect.none must fail if success value is Some, succeed if None
- [x] effect.some must fail with None if success value is None, succeed with value if Some
- [x] effect.someOrFail(e) must fail with e if success value is None
- [x] effect.head must fail with None if sequence is empty, succeed with head if non-empty
- [x] effect.filterOrFail(p)(e) must fail with e if predicate is not satisfied
- [x] effect.filterOrDie(p)(t) must die with t if predicate is not satisfied
- [x] effect.filterOrElse(p)(zio) must run zio if predicate is not satisfied
- [x] effect.collect(e)(pf) must fail with e if pf is not defined
- [x] effect.collectZIO(e)(pf) must fail with e if pf is not defined
- [x] effect.reject(pf) must fail if pf matches success value
- [x] effect.rejectZIO(pf) must fail if pf matches success value
- [x] effect.unless(p) must return Some(a) if p is false, None if true
- [x] effect.when(p) must return Some(a) if p is true, None if false
- [x] effect.unlessZIO(p) must evaluate p then return Some(a) if false, None if true
- [x] effect.whenZIO(p) must evaluate p then return Some(a) if true, None if false
- [ ] effect.provideEnvironment(r) must supply environment r to effect
- [ ] effect.provideLayer(layer) must build layer and supply its output to effect
- [ ] effect.provideSomeEnvironment(f) must transform part of environment
- [ ] effect.updateService must modify a service in the environment
- [x] effect.withClock(clock) must use specified clock implementation
- [x] effect.withRandom(random) must use specified random implementation
- [x] effect.withConsole(console) must use specified console implementation
- [x] effect.withSystem(system) must use specified system implementation
- [x] effect.withConfigProvider(provider) must use specified config provider
- [x] effect.withLogger(logger) must use specified logger
- [x] effect.withParallelism(n) must limit parallel operations to n fibers
- [x] effect.withParallelismUnbounded must remove parallelism limit
- [x] effect.withRuntimeFlags(patch) must update runtime flags within scope
- [x] effect.logSpan(label) must add logging span with label
- [x] effect.logAnnotate(key, value) must add log annotation
- [x] effect.onExecutor(executor) must run effect on specified executor
- [x] effect.shift(executor) must shift execution to specified executor
- [x] ZIO.acquireRelease(acquire)(release) must run acquire uninterruptibly
- [x] ZIO.acquireRelease(acquire)(release) must run release when scope closes
- [x] ZIO.acquireReleaseExit(acquire)(release) must pass Exit to release
- [ ] ZIO.acquireReleaseInterruptible(acquire)(release) must allow acquire to be interrupted
- [ ] ZIO.acquireReleaseWith(acquire)(release)(use) must run acquire uninterruptibly, release on scope close, use in between
- [ ] ZIO.acquireReleaseExitWith(acquire)(release)(use) must pass Exit to release
- [x] ZIO.addFinalizer(finalizer) must run finalizer when scope closes
- [x] ZIO.addFinalizerExit(finalizer) must pass Exit to finalizer when scope closes
- [x] ZIO.scopeWith(f) must provide a Scope to f
- [x] ZIO.scoped(effect) must run effect with a new Scope, close scope on completion
- [x] effect.withFinalizer(finalizer) must add finalizer to current scope
- [x] effect.withFinalizerExit(finalizer) must add finalizer with Exit to current scope
- [x] effect.withEarlyRelease must return (close, a) where close closes scope early
- [x] effect.parallelFinalizers must run finalizers in parallel when scope closes
- [x] effect.sequentialFinalizers must run finalizers sequentially in reverse order
- [x] effect.diffFiberRefs must capture FiberRef changes during execution
- [x] effect.summarized(f)(g) must compute summary before and after execution
- [x] effect.timed must measure execution duration
- [x] effect.timedWith(nanoTime) must measure duration using custom time source
- [x] effect.toFuture must convert to CancelableFuture
- [ ] effect.toFutureWith(f) must convert to CancelableFuture mapping errors with f
- [x] ZIO.fromEither(Left(e)) must fail with e
- [x] ZIO.fromEither(Right(a)) must succeed with a
- [x] ZIO.fromOption(None) must fail with None
- [x] ZIO.fromOption(Some(a)) must succeed with a
- [x] ZIO.fromTry(Failure(t)) must fail with t
- [x] ZIO.fromTry(Success(a)) must succeed with a
- [ ] ZIO.fromFuture(make) must convert Future to ZIO effect
- [ ] ZIO.fromFutureInterrupt(make) must interrupt Future on ZIO interruption
- [x] ZIO.cond(true, a, e) must succeed with a
- [x] ZIO.cond(false, a, e) must fail with e
- [ ] ZIO.absolve(zio) on Left must fail, on Right must succeed
- [ ] ZIO.unsandbox(zio) must submerge Cause into typed error
- [ ] ZIO.firstSuccessOf(zio, rest) must try effects in order until one succeeds
- [ ] ZIO.firstSuccessOf(zio, rest) must fail with last error if all fail
- [x] ZIO.collectAll(effects) must evaluate effects sequentially collecting results
- [x] ZIO.collectAllPar(effects) must evaluate effects in parallel collecting results
- [x] ZIO.collectAllDiscard(effects) must evaluate effects sequentially discarding results
- [x] ZIO.collectAllParDiscard(effects) must evaluate effects in parallel discarding results
- [x] ZIO.foreach(as)(f) must apply f to each element sequentially
- [x] ZIO.foreachPar(as)(f) must apply f to each element in parallel
- [x] ZIO.foreachDiscard(as)(f) must apply f to each element sequentially discarding results
- [x] ZIO.foreachParDiscard(as)(f) must apply f to each element in parallel discarding results
- [ ] ZIO.foreachExec(as)(strategy)(f) must apply f according to execution strategy
- [x] ZIO.filter(as)(f) must keep elements where f returns true
- [x] ZIO.filterPar(as)(f) must keep elements where f returns true in parallel
- [x] ZIO.filterNot(as)(f) must remove elements where f returns true
- [x] ZIO.filterNotPar(as)(f) must remove elements where f returns true in parallel
- [x] ZIO.exists(as)(f) must return true if any element satisfies f
- [x] ZIO.forall(as)(f) must return true if all elements satisfy f
- [x] ZIO.foldLeft(as)(zero)(f) must fold from left to right
- [x] ZIO.foldRight(as)(zero)(f) must fold from right to left
- [x] ZIO.replicateZIO(n)(effect) must execute effect n times collecting results
- [x] ZIO.replicateZIODiscard(n)(effect) must execute effect n times discarding results
- [ ] ZIO.forkAll(effects) must fork all effects returning composite fiber
- [ ] ZIO.forkAllDiscard(effects) must fork all effects returning unit fiber
- [x] ZIO.collectAllSuccesses(effects) must collect results discarding failures
- [x] ZIO.collectAllSuccessesPar(effects) must collect results in parallel discarding failures
- [ ] ZIO.collectAllWith(effects)(pf) must collect results matching pf
- [ ] ZIO.collectAllWithPar(effects)(pf) must collect results matching pf in parallel
- [x] ZIO.collectFirst(as)(f) must return first Some result from f
- [x] ZIO.mergeAll(effects)(zero)(f) must merge results using f in parallel
- [x] ZIO.reduceAll(effects)(f) must reduce results using f in parallel
- [x] ZIO.validateAll(as)(f) must validate all accumulating errors
- [x] ZIO.validateAllPar(as)(f) must validate all in parallel accumulating errors
- [x] ZIO.partitionMap(as)(f) must partition results into failures and successes
- [x] ZIO.partitionMapPar(as)(f) must partition results in parallel
- [x] ZIO.forEachExec(as)(exec)(f) must execute according to strategy
- [ ] ZIO.yieldNow must yield control to allow other fibers to execute
- [x] ZIO.never must never complete (used for testing)
- [x] ZIO.unit must succeed with unit value
- [x] ZIO.none must succeed with None value
- [x] ZIO.fail(e) must fail with typed error e
- [x] ZIO.failCause(cause) must fail with full cause
- [x] ZIO.die(t) must terminate fiber with defect t
- [x] ZIO.dieMessage(msg) must terminate fiber with RuntimeException
- [x] ZIO.interrupt must interrupt current fiber
- [x] ZIO.interruptAs(fiberId) must interrupt as if by fiberId
- [x] ZIO.succeed(v) must succeed with value v
- [x] ZIO.succeedWith(f) must succeed with lazily evaluated value
- [x] ZIO.attempt(e) must catch thrown exceptions as typed errors
- [x] ZIO.attemptBlockingIO(e) must catch IOExceptions as typed errors
- [x] ZIO.suspend(effect) must suspend effect creation
- [x] ZIO.suspendSucceed(effect) must suspend effect creation without catching exceptions
- [x] ZIO.async(register) must register callback for async completion
- [x] ZIO.asyncZIO(register) must register callback effectfully
- [x] ZIO.asyncInterrupt(register) must register callback returning cancellation effect
- [x] ZIO.blocking(zio) must run zio on blocking executor
- [x] ZIO.shift(executor) must shift execution to executor
- [x] ZIO.checkInterruptible(f) must provide current interrupt status to f
- [x] ZIO.descriptor must provide current fiber descriptor
- [x] ZIO.descriptorWith(f) must provide current fiber descriptor to f
- [ ] ZIO.fiberId must return current fiber's FiberId
- [x] ZIO.fiberIdWith(f) must provide current fiber FiberId to f
- [ ] ZIO.inheritFiberRefs(refs) must inherit FiberRef values from child fiber
- [ ] ZIO.getFiberRefs must return all current FiberRef values
- [ ] ZIO.updateFiberRefs(f) must update FiberRef values using f
- [ ] ZIO.clock must provide Clock service
- [ ] ZIO.clockWith(f) must provide Clock service to f
- [ ] ZIO.console must provide Console service
- [ ] ZIO.consoleWith(f) must provide Console service to f
- [ ] ZIO.random must provide Random service
- [ ] ZIO.randomWith(f) must provide Random service to f
- [ ] ZIO.system must provide System service
- [ ] ZIO.systemWith(f) must provide System service to f
- [ ] ZIO.config(config) must load config from current provider
- [ ] ZIO.configProviderWith(f) must provide ConfigProvider to f
- [ ] ZIO.environment must provide current environment
- [ ] ZIO.environmentWith(f) must provide current environment to f
- [ ] ZIO.environmentWithZIO(f) must provide current environment effectfully to f
- [ ] ZIO.executor must provide current executor
- [ ] ZIO.executorWith(f) must provide current executor to f
- [ ] ZIO.loggers must provide current loggers
- [ ] ZIO.loggersWith(f) must provide current loggers to f
- [ ] ZIO.iterate(initial)(cont)(body) must loop while cont is true
- [ ] ZIO.whileLoop(check)(body)(process) must loop while check is true
- [ ] ZIO.loop(initial)(cont)(inc)(body) must loop collecting results
- [x] ZIO.ifZIO(b)(onTrue, onFalse) must evaluate b then branch
- [x] ZIO.unless(p)(effect) must run effect if p is false
- [x] ZIO.when(p)(effect) must run effect if p is true
- [x] ZIO.unlessZIO(p)(effect) must evaluate p then run effect if false
- [x] ZIO.whenZIO(p)(effect) must evaluate p then run effect if true
- [x] ZIO.unlessDiscard(p)(effect) must run effect if p is false discarding result
- [x] ZIO.whenDiscard(p)(effect) must run effect if p is true discarding result
- [x] ZIO.unlessZIODiscard(p)(effect) must evaluate p then run effect if false discarding result
- [x] ZIO.whenZIODiscard(p)(effect) must evaluate p then run effect if true discarding result
- [ ] ZIO.allowInterrupt must self-interrupt if fiber has interrupters
- [x] ZIO.sleep(duration) must delay for specified duration
- [x] ZIO.sleep(Duration.Infinity) must never complete
- [ ] effect.transplant(graft) must transplant fiber to new scope
- [ ] ZIO.parallelism must provide current parallelism level
- [ ] ZIO.parallelismWith(f) must provide current parallelism level to f
- [ ] ZIO.withParallelism(n)(effect) must run effect with parallelism n
- [ ] ZIO.withParallelismUnbounded(effect) must run effect with unbounded parallelism
- [ ] effect.withEarlyRelease must return (UIO[Unit], A) where UIO[Unit] closes scope
- [ ] ZIO.fromAutoCloseable(zio) must acquire and auto-release on scope close
- [x] effect.supervised(supervisor) must report child fibers to supervisor
- [ ] effect.daemonChildren must detach child fibers from parent supervision

# Invariants extracted from Cause.scala

- [x] Cause.empty must represent absence of failure
- [x] Cause.fail(e) must represent typed failure with error e
- [x] Cause.die(t) must represent defect with throwable t
- [x] Cause.interrupt(fiberId) must represent interruption by fiberId
- [x] cause.- [ ] cause.&&(that) must combine causes in parallel (Both)- [ ] cause.&&(that) must combine causes in parallel (Both)(that) must combine causes in parallel (Both)
- [x] cause.++(that) must combine causes sequentially (Then)
- [x] cause.isEmpty must return true only if cause contains no Fail, Die, or Interrupt
- [x] cause.nonEmpty must return true if cause contains any Fail, Die, or Interrupt
- [x] cause.isFailure must return true if cause contains at least one Fail
- [x] cause.isDie must return true if cause contains at least one Die
- [x] cause.isInterrupted must return true if cause contains at least one Interrupt
- [x] cause.isInterruptedOnly must return true if cause contains only Interrupt (no Fail or Die)
- [x] cause.failures must return list of all typed errors in cause
- [x] cause.defects must return list of all throwables in cause
- [ ] cause.interruptors must return set of all FiberIds that interrupted
- [x] cause.failureOption must return first typed error if present
- [x] cause.dieOption must return first throwable if present
- [ ] cause.interruptOption must return first FiberId if present
- [x] cause.failureOrCause must return Left(error) if Fail exists, Right(cause) otherwise
- [ ] cause.failureTraceOrCause must return Left((error, trace)) if Fail exists, Right(cause) otherwise
- [x] cause.find(pf) must return first cause matching partial function
- [x] cause.contains(that) must return true if that is contained in cause
- [x] cause.flatMap(f) must transform each Fail using f and flatten
- [ ] cause.flatten must flatten nested Cause[Cause[E]] to Cause[E]
- [x] cause.map(f) must transform each Fail error using f
- [ ] cause.as(e) must replace all Fail errors with constant e
- [x] cause.linearize must convert parallel causes into set of sequential causes
- [x] cause.keepDefects must return Some(cause) with only Die nodes, None if no Die
- [x] cause.stripFailures must remove all Fail nodes keeping Die and Interrupt
- [ ] cause.stripSomeDefects(pf) must remove Die nodes matching pf
- [ ] cause.filter(p) must keep only causes satisfying predicate p
- [x] cause.size must return total number of Fail, Die, and Interrupt nodes
- [ ] cause.traced(trace) must add trace information to cause
- [ ] cause.untraced must remove all trace information from cause
- [x] cause.trace must return combined StackTrace from all nodes
- [ ] cause.traces must return list of all StackTraces
- [ ] cause.spanned(spans) must add log spans to cause
- [ ] cause.spans must return combined log spans
- [ ] cause.annotated(anns) must add annotations to cause
- [ ] cause.annotations must return combined annotations
- [x] cause.squash must convert cause to single Throwable
- [ ] cause.squashWith(f) must convert cause to Throwable using f for typed errors
- [ ] cause.unified must return homogenized list of failures for stack traces
- [ ] cause.prettyPrint must return human-readable string representation
- [ ] Cause.flipCauseOption must convert Cause[Option[E]] to Option[Cause[E]] stripping None failures
- [x] Cause.Both(left, right) must represent parallel composition
- [x] Cause.Then(left, right) must represent sequential composition
- [ ] Cause.Stackless(cause, stackless) must represent cause with stack trace control
- [ ] cause.equals(other) must compare causes structurally (parallel sets then sequential)
- [x] cause.hashCode must be consistent with structural equality

# Invariants extracted from FiberRuntime.scala

- [ ] fiber.isAlive must return true if exitValue is null
- [ ] fiber.isDone must return true if exitValue is not null
- [ ] fiber.await must return UIO[Exit[E, A]] that completes when fiber exits
- [ ] fiber.poll must return UIO[Option[Exit[E, A]]] with current exit value
- [ ] fiber.interruptAs(fiberId) must send interrupt signal and await exit
- [ ] fiber.interruptAsFork(fiberId) must send interrupt signal without awaiting
- [ ] fiber.children must return chunk of alive child fibers
- [ ] fiber.fiberRefs must return current FiberRef values
- [ ] fiber.runtimeFlags must return current RuntimeFlags
- [ ] fiber.status must return Done, Running, or Suspended
- [ ] fiber.trace must return current stack trace
- [ ] fiber.inheritAll must join child FiberRefs into parent and update runtime flags
- [ ] fiber.inheritAll must not inherit WindDown or Interruption flags
- [ ] fiber.addChild must add child to children set and interrupt if parent should interrupt
- [ ] fiber.addChildren must add multiple children and interrupt if parent should interrupt
- [ ] fiber.removeChild must remove child from children set
- [ ] fiber.transferChildren must transfer children to specified scope
- [ ] fiber.addObserver must add observer notified on exit
- [ ] fiber.removeObserver must remove observer
- [ ] fiber.setExitValue must set exit value, update metrics, and notify observers
- [ ] fiber.setExitValue must notify observers in reverse subscription order
- [ ] fiber.isInterrupted must return true if fiber has been interrupted
- [ ] fiber.isInterruptible must return true if interruption is enabled in runtime flags
- [ ] fiber.shouldInterrupt must return true if interruptible and interrupted
- [ ] fiber.addInterruptedCause must set interrupted flag and accumulate cause
- [ ] fiber.processNewInterruptSignal must add cause, interrupt children, and handle async
- [ ] fiber.processNewInterruptSignal must complete async callback if fiber is interruptible
- [ ] fiber.tell must add message to inbox and start drain if not running
- [ ] fiber.tellInterrupt must send interrupt signal message
- [ ] fiber.start must begin synchronous execution on current thread
- [ ] fiber.startConcurrently must begin asynchronous execution on executor
- [ ] fiber.drainQueueOnCurrentThread must process all inbox messages
- [ ] fiber.drainQueueOnCurrentThread must restart if inbox not empty after drain
- [ ] fiber.drainQueueWhileRunning must process messages and return modified effect
- [ ] fiber.drainQueueAfterAsync must process messages and return resumption effect
- [ ] fiber.evaluateEffect must run effect to completion, handling interruption
- [ ] fiber.evaluateEffect must interrupt all children before completing
- [ ] fiber.evaluateEffect must set WindDown flag before completing
- [ ] fiber.evaluateEffect must notify supervisor on start, suspend, and end
- [ ] fiber.runLoop must execute effect using continuation stack
- [ ] fiber.runLoop must trampoline if depth exceeds MaxDepthBeforeTrampoline
- [ ] fiber.runLoop must yield if operations exceed MaxOperationsBeforeYield
- [ ] fiber.runLoop must check for interruption at trampoline boundaries
- [ ] fiber.runLoop must handle FlatMap by pushing continuation and running first
- [ ] fiber.runLoop must handle FoldZIO by pushing continuation and running first
- [ ] fiber.runLoop must handle Mapped by pushing continuation and running first
- [ ] fiber.runLoop must handle Success by popping continuations and applying
- [ ] fiber.runLoop must handle Failure by popping continuations until FoldZIO found
- [ ] fiber.runLoop must handle Failure by stripping failures if should interrupt
- [ ] fiber.runLoop must handle Async by initiating async and draining queue
- [ ] fiber.runLoop must handle UpdateRuntimeFlagsWithin by patching flags and pushing revert
- [ ] fiber.runLoop must handle WhileLoop by executing body repeatedly
- [ ] fiber.runLoop must handle YieldNow by adding Resume to inbox
- [ ] fiber.runLoop must catch InterruptedException and convert to interrupt+die cause
- [ ] fiber.runLoop must ignore flags update if next frame disables interruption
- [ ] fiber.initiateAsync must register callback and handle sync/async resumption
- [ ] fiber.initiateAsync must handle onInterrupt effect
- [ ] fiber.generateStackTrace must build stack trace from continuation stack
- [ ] fiber.getCurrentExecutor must return overridden executor or default
- [ ] fiber.getSupervisor must return current supervisor from FiberRef
- [ ] fiber.getLoggers must return current loggers from FiberRef
- [ ] fiber.log must call all loggers with message, cause, level, spans, annotations
- [ ] fiber.handleFatalError must report fatal error and set catastrophic failure flag
- [ ] fiber.patchRuntimeFlags must update flags and check for interruption
- [ ] fiber.patchRuntimeFlagsOnly must update flags without interruption check
- [ ] fiber.shouldYieldBeforeFork must return true if forks since yield exceeds threshold
- [ ] fiber.scope must return FiberScope for this fiber
- [ ] fiber.gcStack must clean up continuation stack for garbage collection
- [ ] fiber.popStackFrame must null out stack entry above threshold for GC
- [ ] FiberRuntime.MaxForksBeforeYield must be 128
- [ ] FiberRuntime.MaxOperationsBeforeYield must be 10240
- [ ] FiberRuntime.MaxDepthBeforeTrampoline must be 300
- [ ] FiberRuntime.InitialStackSize must be 16
- [ ] FiberRuntime.StackIdxGcThreshold must be 128
- [ ] fiber.running must be atomic boolean preventing concurrent execution
- [ ] fiber.inbox must be ConcurrentLinkedQueue for thread-safe message passing
- [ ] fiber._exitValue must be volatile for visibility across threads

# Invariants extracted from Scope.scala

- [x] scope.addFinalizer(finalizer) must run finalizer when scope closes
- [x] scope.addFinalizerExit(finalizer) must run finalizer with Exit when scope closes
- [x] scope.fork must create child scope with same execution strategy
- [x] scope.forkWith(strategy) must create child scope with specified execution strategy
- [x] child scope must close automatically when parent scope closes
- [x] scope.close(exit) must run all finalizers with given exit value
- [x] scope.close(exit) must run finalizers in reverse order for Sequential
- [ ] scope.close(exit) must run finalizers in parallel for Parallel strategy
- [ ] scope.close(exit) must run finalizers with bounded parallelism for ParallelN strategy
- [x] scope.close(exit) on already closed scope must be no-op
- [x] adding finalizer to already closed scope must run finalizer immediately
- [x] scope.extend(zio) must provide scope to zio without closing on completion
- [x] scope.use(zio) must provide scope and close it on completion
- [x] scope.size must return number of finalizers not yet run
- [x] scope.size must return 0 for closed scope
- [x] Scope.global.addFinalizer must discard finalizer (never runs)
- [x] Scope.global.close must be no-op
- [x] Scope.global.size must be 0
- [x] Scope.make must create new Closeable scope
- [x] Scope.makeWith(strategy) must create scope with specified execution strategy
- [x] Scope.parallel must create scope with Parallel execution strategy
- [x] Scope.default layer must create scope and close it on completion
- [ ] ReleaseMap.add must return finalizer that removes and runs original finalizer
- [ ] ReleaseMap.addDiscard must add finalizer without returning removal function
- [ ] ReleaseMap.add on Exited state must run finalizer immediately
- [ ] ReleaseMap.release(key, exit) must run and remove finalizer for key
- [ ] ReleaseMap.release on Exited state must be no-op
- [ ] ReleaseMap.releaseAll(exit, Sequential) must run all finalizers sequentially
- [ ] ReleaseMap.releaseAll(exit, Parallel) must run all finalizers in parallel
- [ ] ReleaseMap.releaseAll(exit, ParallelN) must run all finalizers with bounded parallelism
- [ ] ReleaseMap.releaseAll must accumulate errors from all finalizers
- [ ] ReleaseMap.releaseAll must transition to Exited state
- [ ] ReleaseMap.size must return count of remaining finalizers
- [ ] ReleaseMap.size must return 0 for Exited state

# Invariants extracted from Fiber.scala

- [ ] fiber.await must return UIO[Exit[E, A]] that completes when fiber exits
- [ ] fiber.join must await and inherit all FiberRefs from child
- [ ] fiber.join on failed fiber must produce catchable error
- [ ] fiber.join on interrupted fiber must produce inner interruption (catchable)
- [ ] fiber.interrupt must interrupt from calling fiber and await exit
- [ ] fiber.interruptAs(fiberId) must interrupt as if by specified fiber
- [ ] fiber.interruptAsFork(fiberId) must send interrupt signal without awaiting
- [ ] fiber.interruptFork must interrupt in daemon fiber, return immediately
- [ ] fiber.poll must return UIO[Option[Exit[E, A]]] with current exit value
- [ ] fiber.id must return fiber's unique identifier
- [ ] fiber.inheritAll must inherit FiberRef values into calling fiber
- [ ] fiber.map(f) must transform success value
- [ ] fiber.mapZIO(f) must effectfully transform success value
- [ ] fiber.as(b) must replace success value with constant
- [ ] fiber.unit must map success to ()
- [ ] fiber.zipWith(that)(f) must combine two fibers sequentially
- [ ] fiber.zipWith(that)(f) must combine causes if both fail (using &&)
- [ ] fiber.<*>(that) must zip producing tuple
- [ ] fiber.<*(that) must zip keeping left result
- [ ] fiber.*>(that) must zip keeping right result
- [ ] fiber.orElse(that) must prefer this if success, fall back to that on failure
- [ ] fiber.orElse(that) must interrupt both fibers sequentially on interrupt
- [ ] fiber.orElseEither(that) must wrap results in Either
- [ ] fiber.toFuture must convert to CancelableFuture
- [ ] fiber.toFutureWith(f) must convert to Future mapping errors with f
- [ ] fiber.scoped must interrupt fiber when scope closes
- [ ] Fiber.done(exit) must create fiber from exit value
- [ ] Fiber.done(exit).await must return exit immediately
- [ ] Fiber.done(exit).poll must return Some(exit) immediately
- [ ] Fiber.fail(e) must create fiber that has already failed
- [ ] Fiber.failCause(cause) must create fiber that has already failed with cause
- [ ] Fiber.succeed(a) must create fiber that has already succeeded
- [ ] Fiber.unit must create fiber that has already succeeded with ()
- [ ] Fiber.never must create fiber that never completes
- [ ] Fiber.never must be interruptible
- [ ] Fiber.interruptAs(id) must create fiber that has already been interrupted
- [ ] Fiber.fromZIO(io) must create synthetic fiber from effect
- [ ] Fiber.fromFuture(future) must create fiber backed by Future
- [ ] Fiber.collectAll(fibers) must create fiber that collects all results
- [ ] Fiber.collectAll(fibers).await must await all fibers and combine results
- [ ] Fiber.collectAll(fibers).interruptAsFork must interrupt all fibers
- [ ] Fiber.collectAll(fibers).inheritAll must inherit from all fibers
- [ ] Fiber.collectAllDiscard(fibers) must create fiber that awaits all discarding results
- [ ] Fiber.awaitAll(fibers) must await all fibers discarding results
- [ ] Fiber.interruptAll(fibers) must interrupt all fibers and await
- [ ] Fiber.interruptAllAs(fiberId)(fibers) must interrupt all as fiberId and await
- [ ] Fiber.joinAll(fibers) must join all fibers and fail on first error
- [ ] Fiber.roots must return all root fibers
- [ ] Fiber.currentFiber must return fiber executing on current thread
- [ ] Fiber.Status.Done must indicate fiber has completed
- [ ] Fiber.Status.Running must indicate fiber is currently executing
- [ ] Fiber.Status.Suspended must indicate fiber is waiting (async, blocking)
- [ ] Fiber.Status.isDone must return true for Done
- [ ] Fiber.Status.isRunning must return true for Running
- [ ] Fiber.Status.isSuspended must return true for Suspended
- [ ] Fiber.Descriptor must contain id, status, interrupters, executor, isLocked
- [ ] Fiber.Descriptor.interruptStatus must derive from runtime flags
- [ ] Fiber.Dump must contain fiberId, status, trace

# Invariants extracted from Schedule.scala

- [x] schedule.step(now, in, state) must return (State, Out, Decision)
- [x] schedule.step returning Done must stop the schedule
- [x] schedule.step returning Continue(interval) must continue with next interval
- [x] schedule.- [ ] schedule.&&(that) must intersect intervals of both schedules- [ ] schedule.&&(that) must intersect intervals of both schedules(that) must intersect intervals of both schedules
- [ ] schedule.&&(that) must continue only if both schedules continue
- [x] schedule.||(that) must union intervals of both schedules
- [ ] schedule.||(that) must continue if either schedule continues
- [x] schedule.++(that) must run this to completion then that
- [ ] schedule.++(that) must switch to that when this returns Done
- [ ] schedule.>>>(that) must pipe output of this into input of that
- [ ] schedule.<<<(that) must compose by piping that's output into this's input
- [ ] schedule.+++(that) must choose between schedules based on Either input
- [ ] schedule.|||(that) must merge outputs of both schedules
- [ ] schedule.***(that) must pair inputs and outputs of both schedules
- [ ] schedule.first must pair this schedule's I/O with passed-through X
- [ ] schedule.second must pair passed-through X with this schedule's I/O
- [ ] schedule.left must put this schedule on Left side of Either
- [ ] schedule.right must put this schedule on Right side of Either
- [ ] schedule.map(f) must transform output values
- [ ] schedule.mapZIO(f) must effectfully transform output values
- [ ] schedule.contramap(f) must transform input values
- [ ] schedule.contramapZIO(f) must effectfully transform input values
- [ ] schedule.dimap(f, g) must contramap input and map output
- [ ] schedule.dimapZIO(f, g) must effectfully contramap and map
- [ ] schedule.as(out) must replace output with constant
- [ ] schedule.unit must map output to ()
- [ ] schedule.check(test) must continue only if test(in, out) is true
- [ ] schedule.checkZIO(test) must continue only if effectful test returns true
- [ ] schedule.untilInput(f) must continue until f(in) is true
- [ ] schedule.untilInputZIO(f) must continue until effectful f(in) is true
- [ ] schedule.untilOutput(f) must continue until f(out) is true
- [ ] schedule.untilOutputZIO(f) must continue until effectful f(out) is true
- [ ] schedule.whileInput(f) must continue while f(in) is true
- [ ] schedule.whileInputZIO(f) must continue while effectful f(in) is true
- [ ] schedule.whileOutput(f) must continue while f(out) is true
- [ ] schedule.whileOutputZIO(f) must continue while effectful f(out) is true
- [ ] schedule.collectAll must collect all outputs into Chunk
- [ ] schedule.collectWhile(f) must collect outputs while f holds
- [ ] schedule.collectWhileZIO(f) must collect outputs while effectful f holds
- [ ] schedule.collectUntil(f) must collect outputs until f holds
- [ ] schedule.collectUntilZIO(f) must collect outputs until effectful f holds
- [ ] schedule.fold(z)(f) must fold over outputs accumulating state
- [ ] schedule.foldZIO(z)(f) must effectfully fold over outputs
- [ ] schedule.repetitions must count number of recurrences starting from 0
- [x] schedule.forever must loop schedule continuously resetting state on Done
- [ ] schedule.addDelay(f) must add delay to every interval
- [ ] schedule.addDelayZIO(f) must effectfully add delay to every interval
- [ ] schedule.delayed(f) must transform existing delay
- [ ] schedule.delayedZIO(f) must effectfully transform existing delay
- [ ] schedule.modifyDelay(f) must modify delay using function
- [ ] schedule.modifyDelayZIO(f) must modify delay using effectful function
- [ ] schedule.delays must output the delay between occurrences
- [ ] schedule.jittered must randomize interval sizes between 0.8 and 1.2
- [x] schedule.jittered(min, max) must randomize interval sizes between min and max
- [ ] schedule.passthrough must pass through input values as output
- [ ] schedule.ensuring(finalizer) must run finalizer when schedule Done
- [ ] schedule.onDecision(f) must run f for every decision
- [ ] schedule.tapInput(f) must run f on every input
- [ ] schedule.tapOutput(f) must run f on every output
- [ ] schedule.reconsider(f) must allow modifying interval and output on each step
- [ ] schedule.reconsiderZIO(f) must allow effectfully modifying interval and output
- [ ] schedule.resetAfter(duration) must reset to initial state after inactivity
- [ ] schedule.resetWhen(f) must reset to initial state when f(out) is true
- [ ] schedule.upTo(duration) must continue for at most specified duration
- [ ] schedule.intersectWith(that)(f) must combine intervals using f
- [ ] schedule.unionWith(that)(f) must combine intervals using f
- [ ] schedule.provideEnvironment(env) must supply environment removing dependency
- [ ] schedule.provideSomeEnvironment(f) must transform part of environment
- [ ] schedule.run(now, inputs) must run schedule collecting all outputs
- [x] schedule.driver must return Driver with next, last, reset, state
- [x] Driver.next(in) must step schedule returning Out or None error
- [ ] Driver.last must return last output or NoSuchElementException
- [x] Driver.reset must reset schedule to initial state
- [ ] Driver.state must return current schedule state
- [x] Schedule.collectAll must collect all inputs into Chunk
- [x] Schedule.collectWhile(f) must collect while predicate holds
- [x] Schedule.collectUntil(f) must collect until predicate holds
- [x] Schedule.recurWhile(f) must recur while predicate holds
- [x] Schedule.recurUntil(f) must recur until predicate holds
- [x] Schedule.recurWhileEquals(a) must recur while input equals a
- [x] Schedule.recurUntilEquals(a) must recur until input equals a
- [x] Schedule.recurUntil(pf) must recur until partial function matches then map
- [x] Schedule.recurs(n) must recur exactly n times
- [x] Schedule.recurs(0) must not recur
- [ ] Schedule.once must recur exactly one time
- [x] Schedule.stop must not recur
- [x] Schedule.forever must recur indefinitely producing count 0, 1, 2, ...
- [x] Schedule.count must recur indefinitely producing count 0, 1, 2, ...
- [x] Schedule.succeed(a) must recur indefinitely producing constant a
- [x] Schedule.identity must recur indefinitely passing through inputs
- [x] Schedule.fromFunction(f) must recur indefinitely applying f to inputs
- [x] Schedule.spaced(duration) must recur with fixed delay between repetitions
- [x] Schedule.fixed(interval) must recur on fixed interval boundaries
- [x] Schedule.fixed(interval) must not pile up if action takes longer than interval
- [x] Schedule.windowed(interval) must divide timeline into interval-length windows
- [x] Schedule.exponential(base) must produce delays: base, base*2, base*4, ...
- [x] Schedule.exponential(base, factor) must produce delays: base, base*factor, base*factor^2, ...
- [x] Schedule.fibonacci(one) must produce delays: one, one, 2*one, 3*one, 5*one, ...
- [x] Schedule.linear(base) must produce delays: base, 2*base, 3*base, ...
- [x] Schedule.duration(duration) must recur once after specified duration
- [x] Schedule.fromDuration(duration) must recur once after specified duration
- [x] Schedule.fromDurations(durations) must recur once for each duration
- [x] Schedule.unfold(a)(f) must produce sequence a, f(a), f(f(a)), ...
- [x] Schedule.elapsed must output total elapsed duration since first step
- [x] Schedule.delayed(schedule) must use schedule output as delay
- [ ] Schedule.secondOfMinute(s) must recur at specified second of each minute
- [ ] Schedule.minuteOfHour(m) must recur at specified minute of each hour
- [ ] Schedule.hourOfDay(h) must recur at specified hour of each day
- [ ] Schedule.dayOfWeek(d) must recur at specified day of each week
- [ ] Schedule.dayOfMonth(d) must recur at specified day of each month
- [ ] Schedule.secondOfMinute must die if second not in 0...59
- [ ] Schedule.minuteOfHour must die if minute not in 0...59
- [ ] Schedule.hourOfDay must die if hour not in 0...23
- [ ] Schedule.dayOfWeek must die if day not in 1...7
- [ ] Schedule.dayOfMonth must die if day not in 1...31
- [ ] Interval.apply(start, end) must return empty if start after end
- [ ] Interval.after(start) must create interval from start to MAX
- [ ] Interval.before(end) must create interval from MIN to end
- [ ] Interval.empty must have MIN for both start and end
- [ ] Interval.isEmpty must return true if start >= end
- [ ] Interval.nonEmpty must return true if start < end
- [ ] Interval.size must return duration between start and end
- [ ] Interval.intersect(that) must return overlapping portion
- [ ] Interval.union(that) must return merged interval
- [ ] Interval.max(that) must return interval that starts later
- [ ] Interval.min(that) must return interval that starts earlier
- [ ] Intervals.union(that) must merge overlapping intervals
- [ ] Intervals.intersect(that) must find overlapping portions
- [ ] Intervals.nonEmpty must return true if list is not empty
- [x] Decision.Continue(interval) must signal schedule should continue
- [x] Decision.Done must signal schedule should stop

# Invariants extracted from Chunk.scala

- [ ] Chunk.empty must have length 0
- [ ] Chunk.single(a) must have length 1 and element a at index 0
- [ ] chunk.isEmpty must return true if length is 0
- [ ] chunk.length must return number of elements
- [ ] chunk.apply(i) must return element at index i
- [ ] chunk.apply(i) must throw IndexOutOfBoundsException if i < 0 or i >= length
- [ ] chunk.++(that) must concatenate two chunks
- [ ] chunk.++(that) must maintain balanced tree depth
- [ ] chunk.take(n) must return first n elements
- [ ] chunk.take(n) must return full chunk if n >= length
- [ ] chunk.take(n) must return empty if n <= 0
- [ ] chunk.drop(n) must return chunk without first n elements
- [ ] chunk.drop(n) must return empty if n >= length
- [ ] chunk.drop(n) must return full chunk if n <= 0
- [ ] chunk.takeRight(n) must return last n elements
- [ ] chunk.dropRight(n) must return chunk without last n elements
- [ ] chunk.takeWhile(f) must take elements while predicate holds
- [ ] chunk.dropWhile(f) must drop elements while predicate holds
- [ ] chunk.takeWhileZIO(f) must effectfully take while predicate holds
- [ ] chunk.dropWhileZIO(f) must effectfully drop while predicate holds
- [ ] chunk.dropUntil(f) must drop until predicate is true
- [ ] chunk.dropUntilZIO(f) must effectfully drop until predicate is true
- [ ] chunk.splitAt(n) must return (take(n), drop(n))
- [ ] chunk.split(n) must split into n equally sized chunks
- [ ] chunk.splitWhere(f) must split at first element matching predicate
- [ ] chunk.span(f) must split at first element not matching predicate
- [ ] chunk.slice(from, until) must return elements from index from until until
- [ ] chunk.filter(f) must keep elements satisfying predicate
- [ ] chunk.filterZIO(f) must effectfully keep elements satisfying predicate
- [ ] chunk.find(f) must return first element satisfying predicate
- [ ] chunk.findZIO(f) must effectfully return first element satisfying predicate
- [ ] chunk.exists(f) must return true if any element satisfies predicate
- [ ] chunk.forall(f) must return true if all elements satisfy predicate
- [ ] chunk.head must return first element (throws if empty)
- [ ] chunk.headOption must return Some(first) or None if empty
- [ ] chunk.lastOption must return Some(last) or None if empty
- [ ] chunk.indexWhere(f) must return index of first element satisfying predicate
- [ ] chunk.indexWhere(f, from) must start search from index from
- [ ] chunk.foldLeft(s)(f) must fold from left to right
- [ ] chunk.foldRight(s)(f) must fold from right to left
- [ ] chunk.foldZIO(s)(f) must effectfully fold from left to right
- [ ] chunk.foldWhile(s)(pred)(f) must fold while predicate holds
- [ ] chunk.foldWhileZIO(z)(pred)(f) must effectfully fold while predicate holds
- [ ] chunk.collectWhile(pf) must collect while partial function is defined
- [ ] chunk.collectWhileZIO(pf) must effectfully collect while partial function is defined
- [ ] chunk.collectZIO(pf) must effectfully collect elements matching partial function
- [ ] chunk.map(f) must transform all elements
- [ ] chunk.mapZIO(f) must effectfully transform all elements
- [ ] chunk.mapZIOPar(f) must effectfully transform all elements in parallel
- [ ] chunk.mapZIODiscard(f) must effectfully transform discarding results
- [ ] chunk.mapZIOParDiscard(f) must effectfully transform in parallel discarding results
- [ ] chunk.mapAccum(s)(f) must statefully map elements
- [ ] chunk.mapAccumZIO(s)(f) must effectfully statefully map elements
- [ ] chunk.zip(that) must produce pairs of corresponding elements
- [ ] chunk.zip(that) must have length of shorter chunk
- [ ] chunk.zipWith(that)(f) must combine elements using function
- [ ] chunk.zipWith(that)(f) must have length of shorter chunk
- [ ] chunk.zipAll(that) must produce pairs filling missing with None
- [ ] chunk.zipAll(that) must have length of longer chunk
- [ ] chunk.zipAllWith(that)(left, right, both) must handle different lengths
- [ ] chunk.zipWithIndexFrom(offset) must pair elements with indices starting at offset
- [ ] chunk.partitionMap(f) must split into lefts and rights
- [ ] chunk.materialize must convert to array-backed chunk
- [ ] chunk.toArray must convert to Array
- [ ] chunk.toList must convert to List
- [ ] chunk.toVector must convert to Vector
- [ ] chunk.dedupe must remove adjacent identical elements
- [ ] chunk.corresponds(that)(f) must check element-wise correspondence
- [ ] chunk.nonEmptyOrElse(ifEmpty)(fn) must apply fn if non-empty, else ifEmpty
- [ ] chunk.asString must convert to string (for text chunks)
- [ ] chunk.hashCode must be consistent with equals
- [ ] chunk.equals(that) must compare element-wise
- [ ] Chunk.fromArray(array) must create chunk from array
- [ ] Chunk.fromArray(array) must not copy array
- [ ] Chunk.fromIterable(it) must create chunk from iterable
- [ ] Chunk.fromIterable(it) must use existing chunk if input is Chunk
- [ ] Chunk.fromIterable(it) must use VectorChunk if input is Vector
- [ ] Chunk.fromIterator(iterator) must create chunk from iterator
- [ ] Chunk.fill(n)(elem) must create chunk with n copies of elem
- [ ] Chunk.iterate(start, len)(f) must create chunk by applying f repeatedly
- [ ] Chunk.unfold(s)(f) must create chunk by unfolding state
- [ ] Chunk.unfoldZIO(s)(f) must effectfully unfold state
- [ ] Chunk.Concat(left, right) must represent concatenation
- [ ] Chunk.Slice(chunk, offset, length) must represent a slice
- [ ] Chunk.AppendN(start, buffer, bufferUsed, chain) must represent buffered append
- [ ] Chunk.PrependN(end, buffer, bufferUsed, chain) must represent buffered prepend
- [ ] Chunk.BufferSize must be 64
- [ ] Chunk.MaxDepthBeforeMaterialize must be 128
- [ ] Chunk.UpdateBufferSize must be 256
- [ ] Chunk.empty must be singleton empty chunk
- [ ] Chunk.unit must be Chunk(())

# Invariants extracted from ZSTM.scala

- [ ] STM transactions must be atomic - all or nothing
- [ ] STM transactions must be isolated - no intermediate states visible
- [ ] STM transactions must retry automatically on conflict
- [ ] stm.flatMap(f) must sequence two STM effects
- [ ] stm.map(f) must transform success value
- [ ] stm.catchAll(h) must recover from all errors
- [ ] stm.catchSome(pf) must recover from matching errors
- [ ] stm.orElse(that) must try this first, then that on failure or retry
- [ ] stm.orTry(that) must try this first, then that on retry only
- [ ] stm.orElseEither(that) must wrap results in Either
- [ ] stm.orElseFail(e) must fail with e on failure or retry
- [ ] stm.orElseSucceed(a) must succeed with a on failure or retry
- [ ] stm.either must convert failure to Left and success to Right
- [ ] stm.absolve on Left must fail, on Right must succeed
- [ ] stm.fold(f, g) must handle both failure and success
- [ ] stm.foldSTM(f, g) must effectfully handle both failure and success
- [ ] stm.flip must swap error and success channels
- [ ] stm.flipWith(f) must apply f with swapped channels then swap back
- [ ] stm.ensuring(finalizer) must run finalizer on success or failure
- [ ] stm.eventually must retry until success
- [ ] stm.retryUntil(f) must retry until predicate holds
- [ ] stm.retryWhile(f) must retry while predicate holds
- [ ] stm.repeatUntil(f) must repeat until predicate holds (busy loop)
- [ ] stm.repeatWhile(f) must repeat while predicate holds (busy loop)
- [ ] stm.filterOrDie(p)(t) must die if predicate fails
- [ ] stm.filterOrDieMessage(p)(msg) must die with message if predicate fails
- [ ] stm.filterOrElse(p)(zstm) must run zstm if predicate fails
- [ ] stm.filterOrFail(p)(e) must fail with e if predicate fails
- [ ] stm.collect(pf) must filter and map using partial function
- [ ] stm.collectSTM(pf) must filter and flatMap using partial function
- [ ] stm.reject(pf) must fail if partial function matches
- [ ] stm.rejectSTM(pf) must fail if partial function matches
- [ ] stm.some must extract value from Option, fail with None if empty
- [ ] stm.someOrElse(default) must extract or use default
- [ ] stm.someOrElseSTM(default) must extract or use effectful default
- [ ] stm.someOrFail(e) must extract or fail with e
- [ ] stm.none must fail if Some, succeed if None
- [ ] stm.head must extract head from list, fail with None if empty
- [ ] stm.ignore must convert any result to unit
- [ ] stm.isFailure must return true if effect fails
- [ ] stm.isSuccess must return true if effect succeeds
- [ ] stm.left must zoom in on Left of Either
- [ ] stm.right must zoom in on Right of Either
- [ ] stm.unleft must reverse left operation
- [ ] stm.unright must reverse right operation
- [ ] stm.unsome must convert Option[E] error to E value
- [ ] stm.merge must merge error into success channel
- [ ] stm.option must convert failure to None
- [ ] stm.orDie must convert typed errors to defects
- [ ] stm.orDieWith(f) must convert typed errors using f
- [ ] stm.refineOrDie(pf) must refine matching errors, die on non-matching
- [ ] stm.refineOrDieWith(pf)(f) must refine or die using f
- [ ] stm.as(b) must replace success with constant
- [ ] stm.asSome must wrap success in Some
- [ ] stm.asSomeError must wrap error in Some
- [ ] stm.unit must map success to ()
- [ ] stm.tap(f) must run f on success, return original value
- [ ] stm.tapBoth(f, g) must run f on error or g on success
- [ ] stm.tapError(f) must run f on error
- [ ] stm.summarized(summary)(f) must compute summary before and after
- [ ] stm.unless(b) must return Some(a) if b is false, None if true
- [ ] stm.when(b) must return Some(a) if b is true, None if false
- [ ] stm.unlessSTM(b) must evaluate b then return Some(a) if false
- [ ] stm.whenSTM(b) must evaluate b then return Some(a) if true
- [ ] stm.provideEnvironment(r) must supply environment
- [ ] stm.provideSomeEnvironment(f) must transform part of environment
- [ ] stm.updateService must modify service in environment
- [ ] stm.zip(that) must produce tuple of both results
- [ ] stm.zipLeft(that) must keep left result
- [ ] stm.zipRight(that) must keep right result
- [ ] stm.zipWith(that)(f) must combine using function
- [ ] stm.commit must atomically execute STM as ZIO effect
- [ ] stm.commitEither must commit and absorb errors
- [ ] STM.succeed(a) must succeed with value a
- [ ] STM.succeedNow(a) must succeed immediately without suspension
- [ ] STM.fail(e) must fail with error e
- [ ] STM.die(t) must die with throwable t
- [ ] STM.dieMessage(msg) must die with RuntimeException
- [ ] STM.retry must abort and retry transaction
- [ ] STM.check(p) must succeed if p is true, retry if false
- [ ] STM.unit must succeed with ()
- [ ] STM.none must succeed with None
- [ ] STM.some(a) must succeed with Some(a)
- [ ] STM.left(a) must succeed with Left(a)
- [ ] STM.right(a) must succeed with Right(a)
- [ ] STM.cond(true, a, e) must succeed with a
- [ ] STM.cond(false, a, e) must fail with e
- [ ] STM.attempt(a) must catch thrown exceptions as typed errors
- [ ] STM.fromEither(Left(e)) must fail with e
- [ ] STM.fromEither(Right(a)) must succeed with a
- [ ] STM.fromOption(None) must fail with None
- [ ] STM.fromOption(Some(a)) must succeed with a
- [ ] STM.fromTry(Failure(t)) must fail with t
- [ ] STM.fromTry(Success(a)) must succeed with a
- [ ] STM.environment must provide current environment
- [ ] STM.environmentWith(f) must provide environment to f
- [ ] STM.environmentWithSTM(f) must effectfully provide environment to f
- [ ] STM.service must provide service from environment
- [ ] STM.serviceWith(f) must provide service mapped by f
- [ ] STM.serviceWithSTM(f) must provide service effectfully mapped by f
- [ ] STM.serviceAt(key) must provide service at key from environment
- [ ] STM.fiberId must return current fiber id
- [ ] STM.interrupt must interrupt current fiber
- [ ] STM.interruptAs(fiberId) must interrupt as specified fiber
- [ ] STM.collectAll(stms) must sequence STM effects collecting results
- [ ] STM.collectAllDiscard(stms) must sequence STM effects discarding results
- [ ] STM.foreach(as)(f) must apply f to each element collecting results
- [ ] STM.foreachDiscard(as)(f) must apply f to each element discarding results
- [ ] STM.filter(as)(f) must keep elements where f returns true
- [ ] STM.filterNot(as)(f) must remove elements where f returns true
- [ ] STM.collect(as)(f) must collect elements matching partial function
- [ ] STM.collectFirst(as)(f) must return first Some result
- [ ] STM.exists(as)(f) must return true if any element satisfies f
- [ ] STM.forall(as)(f) must return true if all elements satisfy f
- [ ] STM.foldLeft(as)(zero)(f) must fold from left to right
- [ ] STM.foldRight(as)(zero)(f) must fold from right to left
- [ ] STM.partition(as)(f) must split into errors and successes
- [ ] STM.validate(as)(f) must validate all accumulating errors
- [ ] STM.validateFirst(as)(f) must return first success or all errors
- [ ] STM.mergeAll(as)(zero)(f) must merge results using f
- [ ] STM.reduceAll(a)(as)(f) must reduce using f
- [ ] STM.replicate(n)(tx) must create n copies of tx
- [ ] STM.replicateSTM(n)(tx) must execute n times collecting results
- [ ] STM.replicateSTMDiscard(n)(tx) must execute n times discarding results
- [ ] STM.iterate(initial)(cont)(body) must loop while cont is true
- [ ] STM.loop(initial)(cont)(inc)(body) must loop collecting results
- [ ] STM.loopDiscard(initial)(cont)(inc)(body) must loop discarding results
- [ ] STM.unless(b)(stm) must run stm if b is false
- [ ] STM.when(b)(stm) must run stm if b is true
- [ ] STM.unlessSTM(b)(stm) must evaluate b then run stm if false
- [ ] STM.whenSTM(b)(stm) must evaluate b then run stm if true
- [ ] STM.whenCase(a)(pf) must run pf if defined
- [ ] STM.whenCaseSTM(a)(pf) must evaluate a then run pf if defined
- [ ] STM.onCommit(zio) must run zio when transaction commits
- [ ] STM.flatten(tx) must flatten nested STM
- [ ] STM.absolve(z) must submerge Either error
- [ ] ZSTM.acquireReleaseWith(acquire)(release)(use) must acquire, use, release
- [ ] ZSTM.atomically(stm) must run STM as atomic ZIO effect
- [ ] Journal must track all TRef accesses during transaction
- [ ] Journal must be valid if all TRef versions match expected
- [ ] Journal must be invalid if any TRef version changed
- [ ] Journal must commit all changes atomically
- [ ] Journal must complete todos on commit
- [ ] Entry must track expected and new values for TRef
- [ ] Entry must be valid if TRef version matches expected
- [ ] Entry must be changed if newValue differs from expected
- [ ] Entry.attemptCommit must CAS TRef from expected to newValue
- [ ] TExit.Succeed(value, onCommit) must represent success
- [ ] TExit.Fail(error, onCommit) must represent failure
- [ ] TExit.Die(throwable, onCommit) must represent defect
- [ ] TExit.Interrupt(fiberId, onCommit) must represent interruption
- [ ] TExit.Retry must represent retry
- [ ] ZSTM.MaxRetries must be 10
- [ ] ZSTM.YieldOpCount must be 2048
- [ ] ZSTM.LockTimeoutMinMicros must be 1
- [ ] ZSTM.LockTimeoutMaxMicros must be 10
- [ ] ZSTM.tryCommitSync must attempt synchronous commit
- [ ] ZSTM.tryCommitAsync must set up async retry on conflict
- [ ] ZSTM.unsafeAtomically must handle sync and async commit paths

# Invariants extracted from FiberRef.scala

- [ ] FiberRef is ZIO's equivalent of ThreadLocal
- [ ] FiberRef value is automatically propagated to child fibers on fork
- [ ] FiberRef value is merged back to parent fiber on join
- [ ] fiberRef.initial must return initial value
- [ ] fiberRef.get must return current fiber's value
- [ ] fiberRef.get must return initial value if never set
- [ ] fiberRef.set(value) must set value for current fiber
- [ ] fiberRef.update(f) must modify current value using f
- [ ] fiberRef.modify(f) must atomically modify and return result
- [ ] fiberRef.modifySome(default)(pf) must modify with partial function or use default
- [ ] fiberRef.getAndSet(newValue) must set new value and return old
- [ ] fiberRef.getAndUpdate(f) must update and return old value
- [ ] fiberRef.getAndUpdateSome(pf) must partial update and return old
- [ ] fiberRef.updateAndGet(f) must update and return new value
- [ ] fiberRef.updateSome(pf) must partial update
- [ ] fiberRef.updateSomeAndGet(pf) must partial update and return new
- [ ] fiberRef.reset must set value back to initial
- [ ] fiberRef.getWith(f) must provide current value to f
- [ ] fiberRef.locally(newValue)(zio) must run zio with temporarily set value
- [ ] fiberRef.locally(newValue)(zio) must restore original value after zio
- [ ] fiberRef.locallyWith(f)(zio) must run zio with f applied to current value
- [ ] fiberRef.locallyWith(f)(zio) must restore original value after zio
- [ ] fiberRef.locallyScoped(value) must set value and restore on scope close
- [ ] fiberRef.locallyScopedWith(f) must update value and restore on scope close
- [ ] fiberRef.diff(old, new) must compute patch describing changes
- [ ] fiberRef.combine(first, second) must combine two patches associatively
- [ ] fiberRef.patch(patch)(old) must apply patch to old value
- [ ] fiberRef.fork must return patch applied on fork
- [ ] fiberRef.join(old, new) must combine parent and child values on join
- [ ] fiberRef.delete must remove value from current fiber
- [ ] fiberRef.asThreadLocal must return ThreadLocal backed by FiberRef
- [ ] FiberRef.make(initial) must create FiberRef with default fork (identity) and join (second)
- [ ] FiberRef.make(initial, fork, join) must create FiberRef with custom fork and join
- [ ] FiberRef.makeEnvironment(initial) must create FiberRef for ZEnvironment
- [ ] FiberRef.makePatch(initial, differ) must create FiberRef with patch-based diffing
- [ ] FiberRef.makeSet(initial) must create FiberRef for Set with SetPatch
- [ ] FiberRef.makeRuntimeFlags(initial) must create FiberRef for RuntimeFlags
- [ ] FiberRef.Proxy must delegate all operations to wrapped FiberRef
- [ ] FiberRef.currentLogLevel must default to LogLevel.Info
- [ ] FiberRef.currentLogSpan must default to Nil
- [ ] FiberRef.currentLogAnnotations must default to Map.empty
- [ ] FiberRef.currentTags must default to Set.empty
- [ ] FiberRef.currentEnvironment must default to ZEnvironment.empty
- [ ] FiberRef.interruptedCause must default to Cause.empty
- [ ] FiberRef.interruptedCause fork must use identity (empty for child)
- [ ] FiberRef.interruptedCause join must keep parent's value
- [ ] FiberRef.forkScopeOverride must default to None
- [ ] FiberRef.forkScopeOverride fork must use None
- [ ] FiberRef.forkScopeOverride join must keep parent's value
- [ ] FiberRef.overrideExecutor must default to None
- [ ] FiberRef.currentBlockingExecutor must default to Runtime.defaultBlockingExecutor
- [ ] FiberRef.currentLoggers must default to Runtime.defaultLoggers
- [ ] FiberRef.currentReportFatal must default to Runtime.defaultReportFatal
- [ ] FiberRef.currentRuntimeFlags must default to RuntimeFlags.none
- [ ] FiberRef.currentSupervisor must default to Runtime.defaultSupervisor
- [ ] FiberRef.parallelism must default to None
- [ ] FiberRef.unhandledErrorLogLevel must default to Some(LogLevel.Debug)
- [ ] FiberRef.currentFiberIdGenerator must default to FiberId.Gen.Live

# Invariants extracted from Queue.scala

- [ ] Queue.bounded(capacity) must create queue with backpressure strategy
- [ ] Queue.dropping(capacity) must create queue that drops new elements when full
- [ ] Queue.sliding(capacity) must create queue that drops old elements when full
- [ ] Queue.unbounded must create queue with unlimited capacity
- [ ] queue.capacity must return maximum number of elements
- [ ] queue.offer(a) must add element to queue returning true
- [ ] queue.offer(a) must suspend if queue is full (BackPressure)
- [ ] queue.offer(a) must drop if queue is full (Dropping)
- [ ] queue.offer(a) must slide if queue is full (Sliding)
- [ ] queue.offerAll(as) must add all elements returning remaining
- [ ] queue.offerAll(as) must suspend for remaining if backpressured
- [ ] queue.take must remove and return element from queue
- [ ] queue.take must suspend if queue is empty until element available
- [ ] queue.takeAll must remove and return all elements
- [ ] queue.takeUpTo(max) must remove and return up to max elements
- [ ] queue.poll must return Some(element) or None if empty (non-blocking)
- [ ] queue.size must return current number of elements
- [ ] queue.isEmpty must return true if size is 0
- [ ] queue.isFull must return true if size equals capacity
- [ ] queue.shutdown must complete shutdown hook and interrupt all takers
- [ ] queue.shutdown must interrupt all pending putters (BackPressure)
- [ ] queue.isShutdown must return true if queue has been shut down
- [ ] queue.awaitShutdown must complete when queue is shut down
- [ ] queue.offer on shutdown queue must interrupt
- [ ] queue.take on shutdown queue must interrupt
- [ ] queue.offerAll on shutdown queue must interrupt
- [ ] queue.takeAll on shutdown queue must interrupt
- [ ] queue.takeUpTo on shutdown queue must interrupt
- [ ] queue.poll on shutdown queue must interrupt
- [ ] queue.size on shutdown queue must interrupt
- [ ] BackPressure strategy must suspend offerer when queue is full
- [ ] BackPressure strategy must resume offerer when space available
- [ ] BackPressure strategy must complete promise when last item offered
- [ ] BackPressure strategy must interrupt putters on shutdown
- [ ] Dropping strategy must return false when queue is full
- [ ] Dropping strategy must not suspend offerer
- [ ] Sliding strategy must remove oldest element when full
- [ ] Sliding strategy must always return true
- [ ] takers must be notified when element becomes available
- [ ] multiple takers must be satisfied in FIFO order
- [ ] queue.offer must complete waiting taker directly if any
- [ ] queue.offer must add to queue if no takers waiting
- [ ] unsafeCompleteTakers must match takers with available elements
- [ ] unsafeCompleteTakers must handle concurrent access safely

# Invariants extracted from Promise.scala

- [ ] Promise.make must create promise pending initially
- [ ] Promise.makeAs(fiberId) must create promise with specified blocking fiber
- [ ] promise.succeed(a) must complete promise with success value
- [ ] promise.succeed(a) must return true if first completion
- [ ] promise.succeed(a) must return false if already completed
- [ ] promise.fail(e) must complete promise with failure
- [ ] promise.fail(e) must return true if first completion
- [ ] promise.fail(e) must return false if already completed
- [ ] promise.die(t) must complete promise with defect
- [ ] promise.die(t) must return true if first completion
- [ ] promise.die(t) must return false if already completed
- [ ] promise.interruptAs(fiberId) must complete promise with interruption
- [ ] promise.interruptAs(fiberId) must return true if first completion
- [ ] promise.interruptAs(fiberId) must return false if already completed
- [ ] promise.done(exit) must complete promise with exit value
- [ ] promise.done(exit) must return true if first completion
- [ ] promise.done(exit) must return false if already completed
- [ ] promise.completeWith(io) must complete promise with effect
- [ ] promise.completeWith(io) must return true if first completion
- [ ] promise.completeWith(io) must return false if already completed
- [ ] promise.complete(io) must evaluate io and complete with result
- [ ] promise.complete(io) must return true if first completion
- [ ] promise.complete(io) must return false if already completed
- [ ] promise.refailCause(cause) must complete with cause without adding trace
- [ ] promise.await must suspend until promise is completed
- [ ] promise.await must resume with result when completed
- [ ] promise.await on completed promise must return immediately
- [ ] promise.await must be interruptible
- [ ] promise.isDone must return true if completed
- [ ] promise.isDone must return false if pending
- [ ] promise.poll must return Some(io) if completed
- [ ] promise.poll must return None if pending
- [ ] promise can only be completed once
- [ ] multiple fibers awaiting same promise must all resume on completion
- [ ] promise completion must notify all waiters
- [ ] promise interruption must propagate to all waiters
- [ ] promise failure must propagate to all waiters
- [ ] promise defect must propagate to all waiters
- [ ] promise.addWaiter must register callback for completion
- [ ] promise.removeWaiter must unregister callback
- [ ] Pending state must track list of waiters
- [ ] Done state must store completed IO effect

# Invariants extracted from Ref.scala

- [ ] Ref.make(a) must create Ref with initial value a
- [ ] ref.get must return current value
- [ ] ref.set(a) must set value to a with immediate consistency
- [ ] ref.setAsync(a) must set value to a without immediate consistency guarantee
- [ ] ref.modify(f) must atomically modify and return result
- [ ] ref.modify(f) must retry on concurrent modification (CAS loop)
- [ ] ref.update(f) must atomically modify value using f
- [ ] ref.updateAndGet(f) must modify and return new value
- [ ] ref.getAndSet(a) must set new value and return old
- [ ] ref.getAndUpdate(f) must update and return old value
- [ ] ref.getAndUpdateSome(pf) must partial update and return old value
- [ ] ref.updateSome(pf) must partial update value
- [ ] ref.updateSomeAndGet(pf) must partial update and return new value
- [ ] ref.modifySome(default)(pf) must modify with partial function or use default
- [ ] ref.getAndIncrement must increment and return old value
- [ ] ref.getAndDecrement must decrement and return old value
- [ ] ref.getAndAdd(delta) must add delta and return old value
- [ ] ref.incrementAndGet must increment and return new value
- [ ] ref.decrementAndGet must decrement and return new value
- [ ] ref.addAndGet(delta) must add delta and return new value
- [ ] Ref.Synchronized must support effectful update operations
- [ ] Ref.Synchronized.modifyZIO(f) must effectfully modify and return result
- [ ] Ref.Synchronized.updateZIO(f) must effectfully modify value
- [ ] Ref.Synchronized.updateAndGetZIO(f) must effectfully modify and return new
- [ ] Ref.Synchronized.getAndUpdateZIO(f) must effectfully update and return old
- [ ] Ref.Synchronized.getAndUpdateSomeZIO(pf) must effectfully partial update and return old
- [ ] Ref.Synchronized.updateSomeZIO(pf) must effectfully partial update
- [ ] Ref.Synchronized.updateSomeAndGetZIO(pf) must effectfully partial update and return new
- [ ] Ref.Synchronized.modifySomeZIO(default)(pf) must effectfully modify with partial function
- [ ] Ref.Synchronized.set must acquire semaphore before setting
- [ ] Ref.Synchronized.modifyZIO must acquire semaphore before modifying
- [ ] Ref.Atomic must use AtomicReference for CAS-based updates
- [ ] Ref.Atomic.modify must use compareAndSet loop for atomicity
- [ ] Ref.Atomic.get must read from AtomicReference
- [ ] Ref.Atomic.set must write to AtomicReference
- [ ] Ref.Atomic.setAsync must use lazySet on AtomicReference

# Invariants extracted from Semaphore.scala

- [x] Semaphore.make(permits) must create semaphore with specified permits
- [x] semaphore.available must return number of available permits
- [x] semaphore.awaiting must return number of waiting fibers
- [x] semaphore.withPermit(zio) must acquire 1 permit before zio and release after
- [x] semaphore.withPermit(zio) must release permit on success, failure, or interruption
- [x] semaphore.withPermits(n)(zio) must acquire n permits before zio and release after
- [x] semaphore.withPermits(n)(zio) must release permits on success, failure, or interruption
- [x] semaphore.withPermitScoped must acquire permit and release on scope close
- [x] semaphore.withPermitsScoped(n) must acquire n permits and release on scope close
- [x] semaphore.tryWithPermit(zio) must return Some(a) if permit available
- [x] semaphore.tryWithPermit(zio) must return None if no permits available
- [x] semaphore.tryWithPermits(n)(zio) must return Some(a) if n permits available
- [x] semaphore.tryWithPermits(n)(zio) must return None if n permits not available
- [x] semaphore.withPermit must suspend if no permits available
- [x] semaphore.withPermit must resume when permit becomes available
- [x] semaphore.withPermits(n) must suspend if fewer than n permits available
- [x] semaphore.withPermits(n) must resume when n permits become available
- [ ] reserve(n) with n < 0 must die with IllegalArgumentException
- [ ] reserve(0) must succeed immediately without acquiring permits
- [ ] tryReserve(n) with n < 0 must die with IllegalArgumentException
- [ ] tryReserve(0) must return Some(Reservation.zero) immediately
- [ ] releaseN(n) must add n permits back to available count
- [ ] releaseN(n) must complete waiting promises if permits become available
- [ ] releaseN(n) must satisfy waiting fibers in FIFO order
- [x] semaphore with 1 permit must behave as mutex
- [ ] semaphore state tracks either available permits or queue of waiters
- [ ] reservation.acquire must complete when permits are available
- [ ] reservation.release must return permits to semaphore

# Invariants extracted from Hub.scala

- [ ] Hub.bounded(capacity) must create hub with backpressure strategy
- [ ] Hub.dropping(capacity) must create hub that drops new messages when full
- [ ] Hub.sliding(capacity) must create hub that drops old messages when full
- [ ] Hub.unbounded must create hub with unlimited capacity
- [ ] hub.capacity must return maximum number of messages
- [ ] hub.publish(a) must publish message to all subscribers
- [ ] hub.publish(a) must return true if published
- [ ] hub.publish(a) must suspend if hub is full (BackPressure)
- [ ] hub.publish(a) must drop if hub is full (Dropping)
- [ ] hub.publish(a) must slide if hub is full (Sliding)
- [ ] hub.publishAll(as) must publish all messages returning remaining
- [ ] hub.subscribe must create Dequeue for receiving messages
- [ ] hub.subscribe must create subscription that receives all future messages
- [ ] hub.subscribe on shutdown hub must interrupt
- [ ] hub.size must return current number of messages
- [ ] hub.isEmpty must return true if no messages
- [ ] hub.isFull must return true if at capacity
- [ ] hub.shutdown must complete shutdown hook and close scope
- [ ] hub.shutdown must interrupt all subscribers
- [ ] hub.isShutdown must return true if hub has been shut down
- [ ] hub.awaitShutdown must complete when hub is shut down
- [ ] hub.publish on shutdown hub must interrupt
- [ ] hub.publishAll on shutdown hub must interrupt
- [ ] subscription.take must remove and return message
- [ ] subscription.take must suspend if no messages available
- [ ] subscription.take must resume when message published
- [ ] subscription.takeAll must remove and return all available messages
- [ ] subscription.takeUpTo(max) must remove and return up to max messages
- [ ] subscription.poll must return Some(message) or None if empty
- [ ] subscription.size must return current number of available messages
- [ ] subscription.shutdown must unsubscribe from hub
- [ ] subscription.shutdown must interrupt all pollers
- [ ] subscription.isEmpty must return true if no messages
- [ ] subscription.isFull must return true if at capacity
- [ ] BackPressure strategy must suspend publisher when hub is full
- [ ] BackPressure strategy must resume publisher when space available
- [ ] BackPressure strategy must guarantee all subscribers receive all messages
- [ ] Dropping strategy must return false when hub is full
- [ ] Dropping strategy must not suspend publisher
- [ ] Dropping strategy may cause subscribers to miss messages
- [ ] Sliding strategy must remove oldest message when full
- [ ] Sliding strategy must always return true
- [ ] Sliding strategy may cause slow subscribers to miss messages
- [ ] unsafeCompleteSubscribers must notify all subscribers of new messages
- [ ] unsafeCompletePollers must match pollers with available messages
- [ ] unsafeOnHubEmptySpace must signal publishers waiting for space
- [ ] hub.subscribe must fork child scope for subscription lifecycle
- [ ] hub.subscribe must add finalizer to child scope for cleanup

# Invariants extracted from ZPool.scala

- [ ] ZPool.fromIterable(iterable) must create pool from fixed items
- [ ] ZPool.fromIterable must use ZIO.never if iterable is empty
- [ ] ZPool.make(get, size) must create pool with fixed size
- [ ] ZPool.make(get, range, timeToLive) must create pool with min/max and TTL
- [ ] pool.get must retrieve item from pool in scoped effect
- [ ] pool.get must suspend if no items available and at max size
- [ ] pool.get must allocate new item if below max size
- [ ] pool.get must fail if acquisition fails
- [ ] pool.get must retry acquisition on retry
- [ ] pool.get must release item back to pool on scope close
- [ ] pool.get must not release invalidated items
- [ ] pool.invalidate(item) must mark item for reallocation
- [ ] pool.invalidate must cause pool to eventually replace item
- [ ] pool.initialize must pre-allocate items up to minimum size
- [ ] pool.shrink must reduce pool size but never below minimum
- [ ] pool.shutdown must release all items and await shutdown
- [ ] pool.getAndShutdown must drain pool during shutdown
- [ ] State must track size and free count
- [ ] allocate must create new item in pool
- [ ] allocate must update allocated set
- [ ] allocate must offer item to queue
- [ ] allocate must track allocation result
- [ ] release must return item to pool if still valid
- [ ] release must finalize item if invalidated
- [ ] release must update free count
- [ ] finalizeInvalid must run finalizer and potentially reallocate
- [ ] Strategy.None must not shrink excess items
- [ ] Strategy.TimeToLive must shrink after duration of non-use
- [ ] Strategy.TimeToLive must track last use time
- [ ] Strategy.TimeToLive must sleep for timeToLive duration
- [ ] Strategy.TimeToLive must shrink if excess items and idle for timeToLive
- [ ] pool must maintain items between min and max size
- [ ] pool must reallocate items that fail
- [ ] pool must handle concurrent get/release safely
- [ ] pool must release items in some order on shutdown
- [ ] pool.get must disconnect to allow interruption during acquire
- [ ] Attempted must track result and finalizer
- [ ] Attempted.isFailure must return true if result is failure
- [ ] Attempted.forEach must apply f only if success
- [ ] Attempted.toZIO must convert to ZIO effect

# Invariants extracted from ZLayer.scala

- [ ] ZLayer describes how to build one or more services
- [ ] ZLayer services can be injected via ZIO.provide
- [ ] ZLayer construction can be effectful and resourceful
- [ ] ZLayer is shared by default - same layer allocated only once
- [ ] ZLayer.fresh must create unshared version of layer
- [ ] layer.<*>(that) must combine layers sequentially with union output
- [ ] layer.++(that) must combine layers in parallel with union output
- [ ] layer.+!+(that) must combine layers in parallel with unionAll output
- [ ] layer.>>>(that) must feed output of this into input of that
- [ ] layer.>+>(that) must feed output into that and combine outputs
- [ ] layer.<>(that) must try this first, fall back to that on failure
- [ ] layer.map(f) must transform output environment
- [ ] layer.flatMap(f) must construct layer dynamically from output
- [ ] layer.catchAll(handler) must recover from all errors
- [ ] layer.catchAllCause(handler) must recover from all causes
- [ ] layer.mapError(f) must transform error channel
- [ ] layer.mapErrorCause(h) must transform full cause
- [ ] layer.orDie must convert typed errors to defects
- [ ] layer.orElse(that) must fall back to that on failure
- [ ] layer.retry(schedule) must retry construction according to schedule
- [ ] layer.tap(f) must run f on success output
- [ ] layer.tapError(f) must run f on error
- [ ] layer.tapErrorCause(f) must run f on cause
- [ ] layer.foldLayer(failure, success) must handle both cases
- [ ] layer.foldCauseLayer(failure, success) must handle full cause
- [ ] layer.fresh must create version that won't be shared
- [ ] layer.memoize must cache layer result in scope
- [ ] layer.extendScope must extend scope lifetime
- [ ] layer.build must build layer into scoped ZEnvironment
- [ ] layer.build(scope) must build layer into specified scope
- [ ] layer.launch must build and run layer until interrupted
- [ ] layer.toRuntime must convert layer to scoped Runtime
- [ ] layer.unit must replace output with ()
- [ ] layer.update must modify service in output
- [ ] layer.debug must print output on success
- [ ] layer.debug(prefix) must print prefixed output
- [ ] layer.@@(aspect) must apply aspect to layer
- [ ] layer.passthrough must pass through inputs along with outputs
- [ ] layer.project(f) must project part of output
- [ ] layer.reloadableAuto(schedule) must create reloadable service
- [ ] layer.reloadableManual must create manually reloadable service
- [ ] ZLayer.succeed(a) must create layer from value
- [ ] ZLayer.succeedEnvironment(a) must create layer from ZEnvironment
- [ ] ZLayer.fail(e) must create failing layer
- [ ] ZLayer.failCause(cause) must create layer failing with cause
- [ ] ZLayer.die(t) must create layer that dies with throwable
- [ ] ZLayer.fromZIO(zio) must create layer from effect
- [ ] ZLayer.fromZIOEnvironment(zio) must create layer from effect returning environment
- [ ] ZLayer.fromFunction(f) must create layer from function
- [ ] ZLayer.environment must pass through environment
- [ ] ZLayer.service must access service from environment
- [ ] ZLayer.scoped(zio) must create layer from scoped effect
- [ ] ZLayer.scopedEnvironment(zio) must create layer from scoped effect returning environment
- [ ] ZLayer.suspend(layer) must lazily construct layer
- [ ] ZLayer.empty must produce empty environment
- [ ] ZLayer.unit must produce unit environment
- [ ] ZLayer.collectAll(layers) must combine collection of layers
- [ ] ZLayer.foreach(as)(f) must apply f to each element creating layers
- [ ] ZLayer.Derive.Scoped must attach resourceful behavior to derived layer
- [ ] ZLayer.Derive.AcquireRelease must attach acquire/release lifecycle
- [ ] ZLayer.Derive.Default must provide default service instance
- [ ] ZLayer.Derive.Default.succeed must create default from value
- [ ] ZLayer.Derive.Default.fromZIO must create default from effect
- [ ] ZLayer.Derive.Default.fromLayer must create default from layer
- [ ] ZLayer.Derive.Default.service must use service from environment
- [ ] ZLayer.Debug.tree must display layer graph as tree
- [ ] ZLayer.Debug.mermaid must display layer graph as Mermaid chart
- [ ] MemoMap.getOrElseMemoize must check memo map first
- [ ] MemoMap.getOrElseMemoize must build and store layer if not memoized
- [ ] MemoMap.getOrElseMemoize must add finalizer to scope
- [ ] MemoMap.getOrElseMemoize must handle fresh layers without memoizing
- [ ] MemoMap must use reference counting for shared layers
- [ ] MemoMap must close inner scope when last observer exits
- [ ] ZipWith must combine layers sequentially
- [ ] ZipWithPar must combine layers in parallel using forked scopes
- [ ] Fold must handle success and failure cases
- [ ] Apply must wrap ZIO effect as layer
- [ ] ExtendScope must use outer scope for building
- [ ] To must compose layers piping output to input
- [ ] Fresh must build layer without memoization
- [ ] Scoped must extend scope for resource management
- [ ] Suspend must lazily evaluate layer construction
- [ ] FunctionConstructor must support up to 22 parameters
