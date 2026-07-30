(** OpenRouter provider.

    Chat requests use OpenRouter's Responses-style envelope plus optional
    routing controls and attribution headers. Prompt capability flags are
    conservative for routing: image and audio parts are encoded, while video
    prompt input is not advertised. Image generation, audio, rerank, and video
    generation use OpenRouter-specific endpoint helpers. *)

type attribution = { referer : string option; title : string option }
(** Optional OpenRouter attribution headers. [referer] is sent as [HTTP-Referer]
    and [title] is sent as [X-Title]. *)

val attribution : ?referer:string -> ?title:string -> unit -> attribution

type routing = {
  order : string list;
  only_providers : string list;
  ignored_providers : string list;
  allow_fallbacks : bool option;
  require_parameters : bool option;
  sort : string option;
}
(** OpenRouter provider routing object.

    [order] models an ordered provider fallback chain. [only_providers] and
    [ignored_providers] map to OpenRouter's [only] and [ignore] provider fields. *)

val routing :
  ?order:string list ->
  ?only_providers:string list ->
  ?ignored_providers:string list ->
  ?allow_fallbacks:bool ->
  ?require_parameters:bool ->
  ?sort:string ->
  unit ->
  (routing, Eta_ai.ai_error) result

type reasoning = { effort : string option }
(** OpenRouter reasoning controls for Responses requests. *)

val reasoning : ?effort:string -> unit -> (reasoning, Eta_ai.ai_error) result

(** {1 Credentials}

    Callers pass resolved API keys; this package owns Authorization and optional
    attribution headers via {!provider}. *)

type credential = Eta_ai.api_key

val credential : string -> credential

val authorization_headers :
  ?attribution:attribution ->
  ?extra_headers:Eta_ai.headers ->
  credential ->
  Eta_ai.headers

val provider :
  ?base_url:string ->
  ?attribution:attribution ->
  ?extra_headers:Eta_ai.headers ->
  unit ->
  Eta_ai.provider
(** OpenRouter Responses API provider value. The default base URL is
    [https://openrouter.ai] and the path is [/api/v1/responses]. *)

val responses_provider :
  ?base_url:string ->
  ?attribution:attribution ->
  ?extra_headers:Eta_ai.headers ->
  unit ->
  Eta_ai.tool Eta_ai.responses_provider

module Chat : sig
  include Eta_ai.Provider.Chat

  val encode_responses :
    ?routing:routing ->
    ?reasoning:reasoning ->
    Eta_ai.tool Eta_ai.Responses.request ->
    (Eta_ai.raw_json, Eta_ai.ai_error) result

  val responses_request :
    ?routing:routing ->
    ?reasoning:reasoning ->
    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.tool Eta_ai.Responses.request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val responses :
    ?routing:routing ->
    ?reasoning:reasoning ->
    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.tool Eta_ai.Responses.request ->
    (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

  val stream_responses :
    ?routing:routing ->
    ?reasoning:reasoning ->
    ?provider:Eta_ai.tool Eta_ai.responses_provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.tool Eta_ai.Responses.request ->
    (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
end

module Embeddings : sig
  include Eta_ai.Provider.Embeddings

  val encode_with_routing :
    ?routing:routing ->
    ?input_type:string ->
    Eta_ai.Embedding.request ->
    (Eta_ai.raw_json, Eta_ai.ai_error) result

  val request_with_routing :
    ?routing:routing ->
    ?input_type:string ->
    ?provider:Eta_ai.provider ->
    api_key:Eta_ai.api_key ->
    Eta_ai.Embedding.request ->
    (Eta_http.Request.t, Eta_ai.ai_error) result

  val run_with_routing :
    ?routing:routing ->
    ?input_type:string ->
    ?provider:Eta_ai.provider ->
    Eta_http.Client.t ->
    api_key:Eta_ai.api_key ->
    Eta_ai.Embedding.request ->
    (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t
end

module Images : Eta_ai.Provider.Images

module Audio : sig
  module Speech_to_text : sig
    type request = {
      model : Eta_ai.model;
      file : Eta_ai.Audio.upload;
      language : string option;
      prompt : string option;
      response_format : string option;
      temperature : float option;
      extra_fields : (string * string) list;
    }

    type result = {
      text : string option;
      usage : Eta_ai.usage option;
      raw : Eta_ai.raw_json option;
    }

    type configuration = {
      model : Eta_ai.model;
      temperature : float option;
    }

    type request_construction

    include
      Eta_ai.Audio.Speech_to_text.Provider
        with type request := request
         and type result := result
         and type error := Eta_ai.ai_error
         and type configuration := configuration
         and type request_construction := request_construction

    val encode : request -> (Eta_ai.raw_json, Eta_ai.ai_error) Stdlib.result
    val decode : Eta_ai.raw_json -> (result, Eta_ai.ai_error) Stdlib.result

    val request :
      ?provider:Eta_ai.provider ->
      api_key:Eta_ai.api_key ->
      request ->
      (Eta_http.Request.t, Eta_ai.ai_error) Stdlib.result

    val create :
      ?provider:Eta_ai.provider ->
      Eta_http.Client.t ->
      api_key:Eta_ai.api_key ->
      request ->
      (result, Eta_ai.ai_error) Eta.Effect.t
  end

  module Text_to_speech : sig
    type request = {
      model : Eta_ai.model;
      input : string;
      voice : string;
      response_format : string option;
      speed : float option;
      instructions : string option;
      extra : (string * Eta_ai.Json.t) list;
    }

    type result = Eta_ai.Audio.Text_to_speech.result = {
      content_type : string option;
      audio : bytes;
    }

    type configuration = {
      model : Eta_ai.model;
      extra : (string * Eta_ai.Json.t) list;
    }

    type request_construction

    include
      Eta_ai.Audio.Text_to_speech.Provider
        with type request := request
         and type result := result
         and type error := Eta_ai.ai_error
         and type configuration := configuration
         and type request_construction := request_construction

    val encode : request -> (Eta_ai.raw_json, Eta_ai.ai_error) Stdlib.result

    val request :
      ?provider:Eta_ai.provider ->
      api_key:Eta_ai.api_key ->
      request ->
      (Eta_http.Request.t, Eta_ai.ai_error) Stdlib.result

    val create :
      ?provider:Eta_ai.provider ->
      Eta_http.Client.t ->
      api_key:Eta_ai.api_key ->
      request ->
      (result, Eta_ai.ai_error) Eta.Effect.t
  end
end

module Rerank : Eta_ai.Provider.Rerank
module Video : Eta_ai.Provider.Video

val encode_responses :
  ?routing:routing ->
  ?reasoning:reasoning ->
  Eta_ai.tool Eta_ai.Responses.request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result
(** Encode eta-ai chat requests as OpenRouter Responses API requests. *)

val decode_responses :
  Eta_ai.raw_json -> (Eta_ai.response, Eta_ai.ai_error) result

val encode_embeddings :
  ?routing:routing ->
  ?input_type:string ->
  Eta_ai.Embedding.request ->
  (Eta_ai.raw_json, Eta_ai.ai_error) result
(** Encode eta-ai embeddings requests as OpenRouter Embeddings API requests. *)

val decode_embeddings :
  Eta_ai.raw_json -> (Eta_ai.Embedding.response, Eta_ai.ai_error) result

val encode_image_generation :
  Eta_ai.Image.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_image_generation :
  Eta_ai.raw_json -> (Eta_ai.Image.response, Eta_ai.ai_error) result

val encode_rerank :
  Eta_ai.Rerank.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_rerank :
  Eta_ai.raw_json -> (Eta_ai.Rerank.response, Eta_ai.ai_error) result

val encode_video :
  Eta_ai.Video.request -> (Eta_ai.raw_json, Eta_ai.ai_error) result

val decode_video :
  Eta_ai.raw_json -> (Eta_ai.Video.response, Eta_ai.ai_error) result

val decode_stream_event :
  Eta_ai.sse_event -> (Eta_ai.stream_event list, Eta_ai.ai_error) result

val decode_error :
  status:int -> headers:Eta_ai.headers -> Eta_ai.raw_json -> Eta_ai.ai_error

(** {1 Native model catalog}

    [GET /api/v1/models] against the configured provider base URL. Bodies are
    bounded to 5 MiB. Non-2xx responses use the provider error decoder (no
    credentials). Empty [data] arrays decode as [Ok []]; callers own empty
    snapshot policy. *)

type pricing = {
  prompt : float option;
  completion : float option;
  input_cache_read : float option;
  input_cache_write : float option;
  request : float option;
}

type model_info = {
  id : string;
  name : string option;
  context_length : int option;
  pricing : pricing option;
}

val models_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  unit ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val decode_models : Eta_ai.raw_json -> (model_info list, Eta_ai.ai_error) result

val list_models :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  (model_info list, Eta_ai.ai_error) Eta.Effect.t

val responses_request :
  ?routing:routing ->
  ?reasoning:reasoning ->
  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.tool Eta_ai.Responses.request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val embeddings_request :
  ?routing:routing ->
  ?input_type:string ->
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Embedding.request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val image_generation_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Image.request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val rerank_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Rerank.request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val video_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Video.request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val video_get_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  job_id:string ->
  unit ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val video_content_request :
  ?provider:Eta_ai.provider ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Video.content_request ->
  (Eta_http.Request.t, Eta_ai.ai_error) result

val responses :
  ?routing:routing ->
  ?reasoning:reasoning ->
  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.tool Eta_ai.Responses.request ->
  (Eta_ai.response, Eta_ai.ai_error) Eta.Effect.t

val embeddings :
  ?routing:routing ->
  ?input_type:string ->
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Embedding.request ->
  (Eta_ai.Embedding.response, Eta_ai.ai_error) Eta.Effect.t

val image_generation :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Image.request ->
  (Eta_ai.Image.response, Eta_ai.ai_error) Eta.Effect.t

val rerank :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Rerank.request ->
  (Eta_ai.Rerank.response, Eta_ai.ai_error) Eta.Effect.t

val video :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Video.request ->
  (Eta_ai.Video.response, Eta_ai.ai_error) Eta.Effect.t

val video_get :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  job_id:string ->
  (Eta_ai.Video.response, Eta_ai.ai_error) Eta.Effect.t

val video_content :
  ?provider:Eta_ai.provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.Video.content_request ->
  (Eta_ai.Video.content, Eta_ai.ai_error) Eta.Effect.t

val stream_responses :
  ?routing:routing ->
  ?reasoning:reasoning ->
  ?provider:Eta_ai.tool Eta_ai.responses_provider ->
  Eta_http.Client.t ->
  api_key:Eta_ai.api_key ->
  Eta_ai.tool Eta_ai.Responses.request ->
  (Eta_ai.stream, Eta_ai.ai_error) Eta.Effect.t
