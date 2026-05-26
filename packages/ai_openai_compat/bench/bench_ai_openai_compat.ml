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
    model = "mistral-large-latest";
    prompt = [ User [ Text "weather in Warsaw" ] ];
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
    { Bench_lib.name = "ai_openai_compat." ^ name; run; samples = None }
  in
  [
    item "encode_chat.10k" (fun () ->
        let structured_output =
          Ai_openai_compat.structured_output ~name:"weather_answer"
            ~schema_json:weather_schema ~strict:true ()
          |> expect_ok
        in
        repeat 10_000 (fun () ->
            ignore (Ai_openai_compat.encode_chat ~structured_output request)));
    item "request.chat_completions.10k" (fun () ->
        let provider =
          Ai_openai_compat.provider ~name:"mistral"
            ~base_url:"https://api.mistral.test" ()
        in
        repeat 10_000 (fun () ->
            ignore
              (Ai_openai_compat.chat_completions_request ~provider
                 ~api_key:(Ai.api_key "sk-bench") request)));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
