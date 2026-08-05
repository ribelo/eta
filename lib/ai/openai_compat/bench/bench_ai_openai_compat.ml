let weather_schema = Bench_ai_support.weather_schema
let expect_ok = Bench_ai_support.expect_ok
let weather_tool = Bench_ai_support.weather_tool

let request : Eta_ai.chat_request =
  {
    model = "mistral-large-latest";
    prompt = [ User [ Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    reasoning = None;
    max_output_tokens = Some 64;
    replay_items = [];
    stream = false;
  }

let workloads =
  let item name run =
    Bench_lib.workload ("ai_openai_compat." ^ name) run
  in
  [
    item "encode_chat.10k" (fun () ->
        let structured_output =
          Eta_ai_openai_compat.structured_output ~name:"weather_answer"
            ~schema_json:weather_schema ~strict:true ()
          |> expect_ok
        in
        Bench_lib.repeat 10_000 (fun () ->
            ignore (Eta_ai_openai_compat.encode_chat ~structured_output request)));
    item "request.chat_completions.10k" (fun () ->
        let provider =
          Eta_ai_openai_compat.provider ~name:"mistral"
            ~base_url:"https://api.mistral.test" ()
        in
        Bench_lib.repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openai_compat.chat_completions_request ~provider
                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
