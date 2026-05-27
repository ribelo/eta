let weather_schema =
  "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}}}"

let expect_ok = function
  | Ok value -> value
  | Error _ -> failwith "unexpected error"

let tool () =
  Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
    ~input_schema_json:weather_schema ~strict:true ()
  |> expect_ok

let request () : Eta_ai.chat_request =
  {
    model = "bench-model";
    prompt = [ System "stay brief"; User [ Text "weather in Warsaw" ] ];
    tools = [ tool () ];
    temperature = Some 0.2;
    max_output_tokens = Some 64;
    stream = false;
  }

let provider () =
  {
    Eta_ai.name = "bench";
    base_url = "https://bench.example";
    chat_path = "/chat";
    auth_headers =
      (fun key ->
        Eta_http.Core.Header.unsafe_of_list
          [ ("authorization", "Bearer " ^ Eta_redacted.value key) ]);
    capabilities =
      {
        streaming = true;
        tools = true;
        tool_choice = true;
        structured_outputs = true;
      };
    encode_chat =
      (fun request ->
        Ok
          (Printf.sprintf "{\"model\":%S,\"messages\":%d}" request.model
             (List.length request.prompt)));
    decode_chat =
      (fun raw ->
        Ok
          {
            id = Some "bench";
            model = Some "bench-model";
            message = Assistant { content = [ Text raw ]; tool_calls = [] };
            finish_reasons = [ Stop ];
            usage = None;
            raw = Some raw;
          });
    decode_stream_event =
      (fun event ->
        if String.equal event.data "[DONE]" then Ok [ Stream_done ]
        else Ok [ Stream_content_delta event.data ]);
    decode_error =
      (fun ~status ~headers:_ raw ->
        Provider_error
          {
            provider = "bench";
            status = Some status;
            code = None;
            message = "bench";
            raw = Some raw;
          });
  }

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let workloads =
  let p = provider () in
  let item name run =
    { Bench_lib.name = "ai." ^ name; run; samples = None }
  in
  [
    item "toolkit.add_find.100k" (fun () ->
        repeat 100_000 (fun () ->
            let toolkit = Eta_ai.make_toolkit [ tool () ] |> expect_ok in
            ignore (Eta_ai.find_tool "weather" toolkit)));
    item "provider.encode_decode.100k" (fun () ->
        repeat 100_000 (fun () ->
            let raw = p.encode_chat (request ()) |> expect_ok in
            ignore (p.decode_chat raw)));
    item "api_key.headers.100k" (fun () ->
        repeat 100_000 (fun () ->
            ignore (p.auth_headers (Eta_ai.api_key "sk-bench"))));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
