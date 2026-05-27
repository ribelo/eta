let weather_schema =
  "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}}}"

let expect_ok = function
  | Ok value -> value
  | Error _ -> failwith "unexpected error"

let weather_tool () =
  Eta_ai.make_tool ~name:"weather" ~description:"Get current weather"
    ~input_schema_json:weather_schema ~strict:true ()
  |> expect_ok

let request : Eta_ai.chat_request =
  {
    model = "openai/gpt-4o-mini";
    prompt = [ User [ Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    max_output_tokens = Some 64;
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
        let structured_output =
          Eta_ai_openrouter.structured_output ~name:"weather_answer"
            ~schema_json:weather_schema ~strict:true ()
          |> expect_ok
        in
        let routing = routing () in
        repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openrouter.encode_responses ~structured_output ~routing request)));
    item "request.responses.10k" (fun () ->
        let provider =
          Eta_ai_openrouter.provider
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
