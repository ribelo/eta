let weather_schema =
  Eta_ai.Json.to_string
    (Eta_ai.Json.object_
       [
         ("type", Some (Eta_ai.Json.string "object"));
         ( "properties",
           Some
             (Eta_ai.Json.object_
                [
                  ( "location",
                    Some
                      (Eta_ai.Json.object_
                         [ ("type", Some (Eta_ai.Json.string "string")) ]) );
                ]) );
       ])

let expect_ok = function
  | Ok value -> value
  | Error _ -> failwith "unexpected error"

let weather_tool () =
  Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
    ~input_schema_json:weather_schema ~strict:true ()
  |> expect_ok

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

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let workloads =
  let item name run =
    { Bench_lib.name = "ai_openrouter." ^ name; run; samples = None }
  in
  [
    item "encode_responses.10k" (fun () ->
        let routing = routing () in
        repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openrouter.encode_responses ~routing request)));
    item "request.responses.10k" (fun () ->
        let provider =
          Eta_ai_openrouter.responses_provider
            ~attribution:
              (Eta_ai_openrouter.attribution ~referer:"https://eta.example"
                 ~title:"Eta" ())
            ()
        in
        let routing = routing () in
        repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openrouter.responses_request ~routing ~provider
                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
