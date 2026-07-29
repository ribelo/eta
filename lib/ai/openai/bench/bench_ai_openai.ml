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

let request : Eta_ai.chat_request =
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
    model = request.model;
    input = Eta_ai.Responses.Messages request.prompt;
    instructions = None;
    previous_response_id = None;
    store = None;
    include_ = [];
    tools = request.tools;
    tool_choice = None;
    parallel_tool_calls = None;
    max_turns = None;
    max_output_tokens = request.max_output_tokens;
    temperature = request.temperature;
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

let output () =
  Eta_ai_openai.structured_output ~name:"weather_answer" ~schema_json:weather_schema
    ~strict:true ()
  |> expect_ok

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let workloads =
  let item name run =
    { Bench_lib.name = "ai_openai." ^ name; run; samples = None }
  in
  [
    item "encode_chat.10k" (fun () ->
        let structured_output = output () in
        repeat 10_000 (fun () ->
            ignore (Eta_ai_openai.encode_chat ~structured_output request)));
    item "encode_responses.10k" (fun () ->
        repeat 10_000 (fun () ->
            ignore (Eta_ai_openai.encode_responses responses_request)));
    item "request.responses.10k" (fun () ->
        repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openai.responses_request
                 ~provider:
                   (Eta_ai_openai.responses_provider
                      ~base_url:"https://api.openai.test" ())
                 ~api_key:(Eta_ai.api_key "sk-bench") responses_request)));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
