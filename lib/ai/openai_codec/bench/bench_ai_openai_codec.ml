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

let schema_value _ raw =
  Eta_ai.Json.parse raw
  |> Result.map_error (fun message ->
         Eta_ai.Decode_error { provider = "bench"; message; raw = Some raw })

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
              (Eta_ai_openai_codec.encode_chat ~provider:"bench" ~schema_value
                 chat_request)));
    item "encode_responses.10k" (fun () ->
        repeat 10_000 (fun () ->
            ignore
              (Eta_ai_openai_codec.encode_responses ~provider:"bench" ~schema_value
                 chat_request)));
    item "message_item.100k" (fun () ->
        repeat 100_000 (fun () ->
            ignore
              (Eta_ai_openai_codec.chat_message_json ~provider:"bench"
                 (User [ Text "hello" ]))));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
