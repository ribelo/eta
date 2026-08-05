let weather_tool = Bench_ai_support.weather_tool

let request : Eta_ai.chat_request =
  {
    model = "claude-3-5-sonnet-latest";
    prompt = [ System "stay brief"; User [ Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    reasoning = None;
    max_output_tokens = Some 64;
    replay_items = [];
    stream = false;
  }

let workloads =
  let item name run =
    Bench_lib.workload ("ai_anthropic." ^ name) run
  in
  [
    item "encode_messages.10k" (fun () ->
        let prompt_cache = Eta_ai_anthropic.prompt_cache ~cache_system:true () in
        Bench_lib.repeat 10_000 (fun () ->
            ignore (Eta_ai_anthropic.encode_messages ~prompt_cache request)));
    item "request.messages.10k" (fun () ->
        let provider =
          Eta_ai_anthropic.provider ~base_url:"https://api.anthropic.test"
            ~version:"2023-06-01" ()
        in
        Bench_lib.repeat 10_000 (fun () ->
            ignore
              (Eta_ai_anthropic.messages_request ~provider
                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
