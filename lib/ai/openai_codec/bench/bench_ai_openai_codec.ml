let weather_tool = Bench_ai_support.weather_tool

let chat_request : Eta_ai.chat_request =
  {
    model = "gpt-4o-mini";
    prompt = [ System "stay brief"; User [ Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    reasoning = None;
    max_output_tokens = Some 64;
    replay_items = [];
    stream = false;
  }

let responses_request : Eta_ai.tool Eta_ai.Responses.request =
  {
    model = chat_request.model;
    input = Eta_ai.Responses.Messages chat_request.prompt;
    instructions = None;
    previous_response_id = None;
    store = None;
    include_ = [];
    tools = chat_request.tools;
    tool_choice = None;
    parallel_tool_calls = None;
    max_turns = None;
    max_output_tokens = chat_request.max_output_tokens;
    temperature = chat_request.temperature;
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

let schema_value _ raw =
  Eta_ai.Json.parse raw
  |> Result.map_error (fun message ->
         Eta_ai.Decode_error { provider = "bench"; message; raw = Some raw })

let encode_tool =
  Eta_ai_openai_codec.tool_json ~schema_value
    ~shape:Eta_ai_openai_codec.Responses_tool

let workloads =
  let item name run =
    Bench_lib.workload ("ai_openai_codec." ^ name) run
  in
  [
    item "encode_chat.10k" (fun () ->
        Bench_lib.repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openai_codec.encode_chat ~provider:"bench" ~schema_value
                 chat_request)));
    item "encode_responses.10k" (fun () ->
        Bench_lib.repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openai_codec.encode_responses ~provider:"bench" ~encode_tool
                 responses_request)));
    item "message_item.100k" (fun () ->
        Bench_lib.repeat 100_000 (fun () ->
            ignore
              (Eta_ai_openai_codec.chat_message_json ~provider:"bench"
                 (User [ Text "hello" ]))));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
