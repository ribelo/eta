let weather_schema =
  "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}}}"

let expect_ok = function
  | Ok value -> value
  | Error _ -> failwith "unexpected error"

let weather_tool () =
  Ai.make_tool ~name:"weather" ~description:"Get current weather"
    ~input_schema_json:weather_schema ~strict:true ()
  |> expect_ok

let request : Ai.chat_request =
  {
    model = "claude-3-5-sonnet-latest";
    prompt = [ System "stay brief"; User [ Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    max_output_tokens = Some 64;
    stream = false;
  }

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let workloads =
  let item name run =
    { Bench_lib.name = "ai_anthropic." ^ name; run; samples = None }
  in
  [
    item "encode_messages.10k" (fun () ->
        let prompt_cache = Ai_anthropic.prompt_cache ~cache_system:true () in
        repeat 10_000 (fun () ->
            ignore (Ai_anthropic.encode_messages ~prompt_cache request)));
    item "request.messages.10k" (fun () ->
        let provider =
          Ai_anthropic.provider ~base_url:"https://api.anthropic.test"
            ~version:"2023-06-01" ()
        in
        repeat 10_000 (fun () ->
            ignore
              (Ai_anthropic.messages_request ~provider ~api_key:(Ai.api_key "sk-bench")
                 request)));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
