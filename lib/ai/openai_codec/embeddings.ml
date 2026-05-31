module A = Eta_ai
module Json = A.Json

open Core

let int_array values = Json.array (List.map Json.int values)

let embedding_input_json ~provider (input : A.Embedding.input) =
  match input with
  | A.Embedding.Text text -> Stdlib.Ok (Json.string text)
  | A.Embedding.Texts texts ->
      non_empty_list ~provider "embedding input" texts
      |> Result.map (fun texts -> Json.array (List.map Json.string texts))
  | A.Embedding.Tokens tokens ->
      non_empty_list ~provider "embedding token input" tokens
      |> Result.map int_array
  | A.Embedding.Token_batches batches ->
      let* batches = non_empty_list ~provider "embedding token batch input" batches in
      let* batches =
        batches
        |> List.map (non_empty_list ~provider "embedding token input")
        |> result_all
      in
      Stdlib.Ok (Json.array (List.map int_array batches))
  | A.Embedding.Raw_json raw -> parse_json ~provider raw

let encode_embeddings_json ~provider (request : A.Embedding.request) =
  let* input = embedding_input_json ~provider request.input in
  let* dimensions =
    positive_int_json ~provider "embedding dimensions" request.dimensions
  in
  let* encoding_format =
    embedding_encoding_format_json ~provider request.encoding_format
  in
  let* user = optional_non_empty ~provider "embedding user" request.user in
  Stdlib.Ok
    (Json.object_
       [
         ("model", Some (Json.string request.model));
         ("input", Some input);
         ("encoding_format", encoding_format);
         ("dimensions", dimensions);
         ("user", Option.map Json.string user);
       ])

let encode_embeddings ~provider request =
  encode_embeddings_json ~provider request |> Result.map Json.to_string

let decode_float ~provider ~raw json =
  match json with
  | `Float value -> Stdlib.Ok value
  | `Int value -> Stdlib.Ok (float_of_int value)
  | `Intlit value -> (
      match float_of_string_opt value with
      | Some value -> Stdlib.Ok value
      | None ->
          decode_error_result ~provider ~raw
            "embedding vector contains invalid number")
  | _ ->
      decode_error_result ~provider ~raw
        "embedding vector contains non-number value"

let decode_embedding_vector ~provider ~raw json =
  match json with
  | `List values ->
      values
      |> List.map (decode_float ~provider ~raw)
      |> result_all
      |> Result.map (fun values -> A.Embedding.Float values)
  | `String value -> Stdlib.Ok (A.Embedding.Base64 value)
  | _ ->
      decode_error_result ~provider ~raw
        "embedding must be a float array or base64 string"

let decode_embedding_item ~provider ~raw json =
  match Json.member "embedding" json with
  | None -> decode_error_result ~provider ~raw "embedding item missing embedding"
  | Some embedding_json ->
      let* embedding = decode_embedding_vector ~provider ~raw embedding_json in
      Stdlib.Ok { A.Embedding.embedding; index = Json.int_member "index" json }

let embedding_usage ?(extra_raw_names = []) json =
  let input_tokens =
    match Json.int_member "prompt_tokens" json with
    | Some _ as value -> value
    | None -> Json.int_member "input_tokens" json
  in
  let total_tokens = Json.int_member "total_tokens" json in
  let raw_value name =
    Json.scalar_string_member name json |> Option.value ~default:""
  in
  {
    A.Embedding.input_tokens;
    total_tokens;
    raw =
      List.map
        (fun name -> (name, raw_value name))
        ([ "prompt_tokens"; "input_tokens"; "total_tokens" ] @ extra_raw_names);
  }

let decode_embeddings ?(usage_extra_raw_names = []) ~provider raw =
  let* json = parse_json ~provider raw in
  match Json.array_member "data" json with
  | None -> decode_error_result ~provider ~raw "embeddings response missing data"
  | Some data ->
      let* embeddings =
        data |> List.map (decode_embedding_item ~provider ~raw) |> result_all
      in
      Stdlib.Ok
        {
          A.Embedding.id = Json.string_member "id" json;
          model = Json.string_member "model" json;
          embeddings;
          usage =
            Option.map
              (embedding_usage ~extra_raw_names:usage_extra_raw_names)
              (Json.object_member "usage" json);
          raw = Some raw;
        }
