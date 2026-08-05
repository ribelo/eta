let expect_ok = Bench_ai_support.expect_ok
let weather_tool = Bench_ai_support.weather_tool

let request : Eta_ai.tool Eta_ai.Responses.request =
  {
    model = "openai/gpt-4o-mini";
    input = Eta_ai.Responses.Messages [ User [ Text "weather in Warsaw" ] ];
    instructions = None;
    previous_response_id = None;
    store = None;
    include_ = [];
    tools = [ weather_tool () ];
    tool_choice = None;
    parallel_tool_calls = None;
    max_turns = None;
    max_output_tokens = Some 64;
    temperature = Some 0.2;
    top_p = None;
    top_k = None;
    min_p = None;
    text = None;
    reasoning = None;
    reasoning_effort = None;
    service_tier = None;
    user = None;
    prompt_cache_key = None;
    replay_items = [];
    stream = false;
  }

let routing () =
  Eta_ai_openrouter.routing ~order:[ "anthropic"; "openai" ]
    ~ignored_providers:[ "bad" ] ~allow_fallbacks:true
    ~require_parameters:true ~sort:"throughput" ()
  |> expect_ok

let workloads =
  let item name run =
    Bench_lib.workload ("ai_openrouter." ^ name) run
  in
  [
    item "encode_responses.10k" (fun () ->
        let routing = routing () in
        Bench_lib.repeat 10_000 (fun () ->
            ignore (Eta_ai_openrouter.encode_responses ~routing request)));
    item "request.responses.10k" (fun () ->
        let provider =
          Eta_ai_openrouter.responses_provider
            ~attribution:
              (Eta_ai_openrouter.attribution ~referer:"https://eta.example"
                 ~title:"Eta" ())
            ()
        in
        let routing = routing () in
        Bench_lib.repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openrouter.responses_request ~routing ~provider
                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
