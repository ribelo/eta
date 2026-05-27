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
    model = "gpt-4o-mini";
    prompt = [ System "stay brief"; User [ Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    max_output_tokens = Some 64;
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
        let structured_output = output () in
        repeat 10_000 (fun () ->
            ignore (Eta_ai_openai.encode_responses ~structured_output request)));
    item "request.responses.10k" (fun () ->
        repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openai.responses_request
                 ~provider:(Eta_ai_openai.provider ~base_url:"https://api.openai.test" ())
                 ~api_key:(Eta_ai.api_key "sk-bench") request)));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
