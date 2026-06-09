let all_tests =
  List.concat
    [
      Test_pure.tests;
      Test_runtime.tests;
      Test_queue.tests;
      Test_channel.tests;
      Test_semaphore.tests;
      Test_pubsub.tests;
      Test_pool.tests;
      Test_resource.tests;
      Test_fiber.tests;
      Test_supervisor.tests;
      Test_promise.tests;
      Test_clock.tests;
      Test_uninterruptible.tests;
      Test_cause_effect.tests;
      Test_deferred.tests;
      Test_latch.tests;
      Test_ref.tests;
      Test_synchronized_ref.tests;
      Test_observability.tests;
      Test_stress.tests;
    ]

let () =
  ignore (Eta_js_test.run_all all_tests)
