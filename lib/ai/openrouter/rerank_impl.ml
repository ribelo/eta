(** OpenRouter Rerank API ([POST /api/v1/rerank]). *)

module A = Common.A
module E = Common.E
module Json = Common.Json
module Codec = Common.Codec

let encode (request : A.Rerank.request) =
  match
    Codec.non_empty_list ~provider:"openrouter" "rerank documents"
      request.documents
  with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok documents ->
      Stdlib.Ok
        (Json.object_
           [
             ("model", Some (Json.string request.model));
             ("query", Some (Json.string request.query));
             ("documents", Some (Json.array (List.map Json.string documents)));
             ("top_n", Option.map Json.int request.top_n);
           ]
        |> Json.to_string)

let float_member name json =
  match Json.member name json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some (`Intlit value) -> float_of_string_opt value
  | _ -> None

let result_of_json json =
  let document =
    Option.bind (Json.object_member "document" json)
      (Json.string_member "text")
  in
  match Json.int_member "index" json with
  | Some index ->
      Stdlib.Ok
        {
          A.Rerank.index;
          score = float_member "relevance_score" json;
          document;
        }
  | None -> Common.decode_error_result "rerank result missing index"

let decode raw =
  match Common.parse_json raw with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok json -> (
      match Json.array_member "results" json with
      | None ->
          Common.decode_error_result ~raw "rerank response missing results"
      | Some results -> (
          match Codec.result_all (List.map result_of_json results) with
          | Stdlib.Error _ as error -> error
          | Stdlib.Ok results ->
              Stdlib.Ok
                {
                  A.Rerank.id = Json.string_member "id" json;
                  model = Json.string_member "model" json;
                  provider = Json.string_member "provider" json;
                  results;
                  usage =
                    Option.map Codec.usage (Json.object_member "usage" json);
                  raw = Some raw;
                }))

let request ?provider:custom_provider ~api_key request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match encode request with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok raw ->
      Stdlib.Ok
        (A.provider_post_request provider ~path:"/api/v1/rerank" api_key raw)

let run ?provider:custom_provider client ~api_key rerank_request =
  let provider = Option.value ~default:(Common.provider ()) custom_provider in
  match request ~provider ~api_key rerank_request with
  | Stdlib.Error error -> E.fail error
  | Stdlib.Ok http_request ->
      A.perform_raw provider client http_request
      |> E.bind (fun raw ->
             match decode raw with
             | Stdlib.Ok response -> E.pure response
             | Stdlib.Error error -> E.fail error)

let run_with_provider ~provider client ~api_key request =
  run ~provider client ~api_key request
