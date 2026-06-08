let assert_result label result expected =
  match result with
  | Ok actual when actual = expected -> ()
  | Ok actual -> failwith (Printf.sprintf "%s: expected %d, got %d" label expected actual)
  | Error _ -> failwith (label ^ ": unexpected error")

let assert_close label count =
  if count <> 1 then failwith (Printf.sprintf "%s: expected one close, got %d" label count)

let () =
  Eio_main.run @@ fun _env ->
  assert_result "s-a sum" (Stream_research.S_a_channel_core.Effect.run (object end) Stream_research.S_a_channel_core.program) 30;
  let result, close_count = Stream_research.S_a_channel_core.resource_program () in
  assert_result "s-a resource" result 1;
  assert_close "s-a close" close_count;

  assert_result "s-b sum" (Stream_research.S_b_stream_core.Effect.run (object end) Stream_research.S_b_stream_core.program) 30;
  let result, close_count = Stream_research.S_b_stream_core.resource_program () in
  assert_result "s-b resource" result 1;
  assert_close "s-b close" close_count;

  assert_result "s-c sum" (Stream_research.S_c_eio_pipeline.Effect.run (object end) Stream_research.S_c_eio_pipeline.program) 30;
  let result, close_count = Stream_research.S_c_eio_pipeline.resource_program () in
  assert_result "s-c resource" result 1;
  assert_close "s-c close" close_count;

  assert_result "s-b2 sum" (Stream_research.S_b2_pull_core.Effect.run (object end) Stream_research.S_b2_pull_core.program) 30;
  let result, close_count = Stream_research.S_b2_pull_core.resource_program () in
  assert_result "s-b2 resource" result 1;
  assert_close "s-b2 close" close_count;

  assert_result "s-d sum" (Stream_research.S_d_eio_chunked.Effect.run (object end) Stream_research.S_d_eio_chunked.program) 30;
  let result, close_count = Stream_research.S_d_eio_chunked.resource_program () in
  assert_result "s-d resource" result 1;
  assert_close "s-d close" close_count;

  assert_result "s-e sum" (Stream_research.S_e_channel_transducer.Effect.run (object end) Stream_research.S_e_channel_transducer.program) 30;
  (match Stream_research.S_e_channel_transducer.line_program () with
  | Ok ([ "a"; "b" ], "c") -> ()
  | Ok _ -> failwith "s-e split_lines: unexpected output"
  | Error _ -> failwith "s-e split_lines: unexpected error");

  assert_result "s-f sum" (Stream_research.S_f_seq_pull.Effect.run (object end) Stream_research.S_f_seq_pull.program) 30;
  let result, close_count = Stream_research.S_f_seq_pull.resource_leak_program () in
  assert_result "s-f resource" result 1;
  if close_count <> 0 then
    failwith (Printf.sprintf "s-f leak demonstration changed: expected zero closes, got %d" close_count)
