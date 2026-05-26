let weather_schema =
  "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}}}"

let expect_ok = function
  | Ok value -> value
  | Error _ -> failwith "unexpected error"

let weather_tool () =
  Ai.make_tool ~name:"weather" ~description:"Get current weather"
    ~input_schema_json:weather_schema ~strict:true ()
  |> expect_ok

let chat_request : Ai.chat_request =
  {
    model = "gpt-4o-mini";
    prompt = [ System "stay brief"; User [ Text "weather in Warsaw" ] ];
    tools = [ weather_tool () ];
    temperature = Some 0.2;
    max_output_tokens = Some 64;
    stream = false;
  }

let schema_value _ raw =
  Ai.Json.parse raw
  |> Result.map_error (fun message ->
         Ai.Decode_error { provider = "bench"; message; raw = Some raw })

let repeat n f =
  for _ = 1 to n do
    f ()
  done

let workloads =
  let item name run =
    { Bench_lib.name = "ai_openai_codec." ^ name; run; samples = None }
  in
  [
    item "encode_chat.10k" (fun () ->
        repeat 10_000 (fun () ->
            ignore
              (Ai_openai_codec.encode_chat ~provider:"bench" ~schema_value
                 chat_request)));
    item "encode_responses.10k" (fun () ->
        repeat 10_000 (fun () ->
            ignore
              (Ai_openai_codec.encode_responses ~provider:"bench" ~schema_value
                 chat_request)));
    item "message_item.100k" (fun () ->
        repeat 100_000 (fun () ->
            ignore (Ai_openai_codec.chat_message_json (User [ Text "hello" ]))));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
