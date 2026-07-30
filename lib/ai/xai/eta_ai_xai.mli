(** Transport-neutral xAI provider.

    This package intentionally exposes no Live Translation operation, custom
    voice mutation, phone provisioning, call control, or Eio WebSocket
    connection. Applications own state and tool execution. *)

val provider_name : string
val default_base_url : string
val default_management_base_url : string

type credential = private Eta_ai.api_key
val credential : string -> credential
val api_key : credential -> Eta_ai.api_key

val authorization_headers : credential -> Eta_ai.headers

val provider : ?endpoint:Endpoint.inference -> unit -> Eta_ai.provider
val responses_provider :
  ?endpoint:Endpoint.inference -> unit -> Responses.tool Eta_ai.responses_provider

val decode_error :
  status:int ->
  headers:Eta_ai.headers ->
  Eta_ai.raw_json ->
  Xai_error.t

module Error = Xai_error
module Endpoint = Endpoint
module Capabilities = Capabilities
module Responses = Responses
module Files = Files
module Collections = Collections
module Models = Models

module Audio : sig
  module Speech_to_text = Speech_to_text
  module Text_to_speech = Text_to_speech
  module Voices = Voices
  module Realtime = Realtime
end
