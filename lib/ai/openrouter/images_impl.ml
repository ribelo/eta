(** OpenRouter Image Generation API ([POST /api/v1/chat/completions] with
    image modality). Unlike OpenAI's [/v1/images/generations], OpenRouter
    threads image generation through the chat completions envelope. *)

module A = Common.A
module E = Common.E
module Json = Common.Json
module Codec = Common.Codec

let encode (request : A.Image.request) =
  match request.model with
  | None -> Common.invalid_routing "image generation model is required"
  | Some model ->
      if String.equal (String.trim request.prompt) "" then
        Common.invalid_routing "image generation prompt must not be empty"
      else if Option.is_some request.n then
        Common.invalid_routing "image generation n"
      else if Option.is_some request.quality then
        Common.invalid_routing "image generation quality"
      else if Option.is_some request.response_format then
        Common.invalid_routing "image generation response_format"
      else if Option.is_some request.user then
        Common.invalid_routing "image generation user"
      else
        let image_config =
          match request.size with
          | None -> None
          | Some size ->
              Some (Json.object_ [ ("image_size", Some (Json.string size)) ])
        in
        Stdlib.Ok
          (Common.with_json_fields request.extra
             [
               ("model", Some (Json.string model));
               ( "messages",
                 Some
                   (Json.array
                      [
                        Json.object_
                          [
                            ("role", Some (Json.string "user"));
                            ("content", Some (Json.string request.prompt));
                          ];
                      ]) );
               ( "modalities",
                 Some (Json.array [ Json.string "image"; Json.string "text" ]) );
               ("image_config", image_config);
             ]
          |> Json.to_string)

let decode raw =
  match Common.parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "choices" json with
      | Some (choice :: _) -> (
          match Json.object_member "message" choice with
          | None ->
              Common.decode_error_result ~raw
                "image generation choice missing message"
          | Some message ->
              let images =
                Json.array_member "images" message |> Option.value ~default:[]
                |> List.filter_map (fun item ->
                       let image_json = Json.object_member "image_url" item in
                       let url =
                         Option.bind image_json (Json.string_member "url")
                       in
                       Option.map
                         (fun url ->
                           {
                             A.Image.url = Some url;
                             base64 = None;
                             revised_prompt = None;
                           })
                         url)
              in
              Stdlib.Ok
                {
                  A.Image.created = Json.int_member "created" json;
                  images;
                  usage =
                    Option.map Codec.usage (Json.object_member "usage" json);
                  raw = Some raw;
                })
      | _ ->
          Common.decode_error_result ~raw
            "image generation response missing choices")

let request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match encode request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok
        (A.provider_post_request provider ~path:"/api/v1/chat/completions"
           api_key raw)

let run ?provider:custom_provider client ~api_key image_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match request ~provider ~api_key image_request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)
