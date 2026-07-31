(** Eio WebSocket transports for the three OpenAI Realtime protocols. *)
(** Every connection serializes outbound sends and immediately rejects a second
    concurrent read. [finish] sends the protocol's graceful completion sequence
    and waits while callers pull through its terminal event; [abort] releases
    immediately and exactly once. [finish_with_timeout] uses only its
    caller-supplied timeout. Message and pending-event state is bounded by
    default and each connect operation accepts explicit overrides. Typed
    provider error events are delivered in-band; the caller decides whether the
    connection continues. *)

type connection_options =
  | Connection_options : {
      base_url : string option;
      safety_identifier : string option;
      max_message_size : int option;
      max_pending_events : int option;
      net : 'a Eio.Net.t;
      api_key : Eta_ai.api_key;
    } -> connection_options

val default_max_message_size : int
val default_max_pending_events : int

module Conversation : sig
  type error =
    | Websocket of Eta_http_eio.Ws.Client.ws_error
    | Openai_error of Eta_ai_openai.Error.t
    | Concurrent_read
    | Already_finished
    | Finished
    | Aborted
    | Timeout
  type t
  val connect : ?base_url:string -> ?safety_identifier:string -> ?max_message_size:int -> ?max_pending_events:int -> sw:Eio.Switch.t -> net:_ Eio.Net.t -> api_key:Eta_ai.api_key -> session:Eta_ai_openai.Audio.Realtime.Conversation.session -> unit -> (t, error) Eta.Effect.t
  val connect_session_on_flow : ?key:string -> ?safety_identifier:string -> ?max_message_size:int -> ?max_pending_events:int -> sw:Eio.Switch.t -> flow:Eta_http_eio.Ws.Client.flow -> api_key:Eta_ai.api_key -> Eta_http.Core.Url.t -> Eta_ai_openai.Audio.Realtime.Conversation.session -> (t, error) Eta.Effect.t
  val send_event : t -> Eta_ai_openai.Audio.Realtime.Conversation.client_event -> (unit, error) Eta.Effect.t
  val events : t -> (Eta_ai_openai.Audio.Realtime.Conversation.server_event, error) Eta_stream.Stream.t
  val read_event : t -> (Eta_ai_openai.Audio.Realtime.Conversation.server_event option, error) Eta.Effect.t
  val finish : t -> (unit, error) Eta.Effect.t
  val finish_with_timeout : timeout:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val abort : t -> (unit, error) Eta.Effect.t
  module Transport : sig
    include Eta_ai.Realtime.Transport
      with type session = Eta_ai_openai.Audio.Realtime.Conversation.session
       and type client_event = Eta_ai_openai.Audio.Realtime.Conversation.client_event
       and type server_event = Eta_ai_openai.Audio.Realtime.Conversation.server_event
       and type error = error and type scope = Eio.Switch.t
       and type connection_options = connection_options and type connection = t
  end
end

module Transcription : sig
  type error =
    | Websocket of Eta_http_eio.Ws.Client.ws_error
    | Openai_error of Eta_ai_openai.Error.t
    | Concurrent_read
    | Already_finished
    | Finished
    | Aborted
    | Timeout
  type t
  val connect : ?base_url:string -> ?safety_identifier:string -> ?max_message_size:int -> ?max_pending_events:int -> sw:Eio.Switch.t -> net:_ Eio.Net.t -> api_key:Eta_ai.api_key -> session:Eta_ai_openai.Audio.Realtime.Transcription.session -> unit -> (t, error) Eta.Effect.t
  val connect_session_on_flow : ?key:string -> ?safety_identifier:string -> ?max_message_size:int -> ?max_pending_events:int -> sw:Eio.Switch.t -> flow:Eta_http_eio.Ws.Client.flow -> api_key:Eta_ai.api_key -> Eta_http.Core.Url.t -> Eta_ai_openai.Audio.Realtime.Transcription.session -> (t, error) Eta.Effect.t
  val send_event : t -> Eta_ai_openai.Audio.Realtime.Transcription.client_event -> (unit, error) Eta.Effect.t
  val events : t -> (Eta_ai_openai.Audio.Realtime.Transcription.server_event, error) Eta_stream.Stream.t
  val read_event : t -> (Eta_ai_openai.Audio.Realtime.Transcription.server_event option, error) Eta.Effect.t
  val finish : t -> (unit, error) Eta.Effect.t
  val finish_with_timeout : timeout:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val abort : t -> (unit, error) Eta.Effect.t
  module Transport : sig
    include Eta_ai.Realtime.Transport
      with type session = Eta_ai_openai.Audio.Realtime.Transcription.session
       and type client_event = Eta_ai_openai.Audio.Realtime.Transcription.client_event
       and type server_event = Eta_ai_openai.Audio.Realtime.Transcription.server_event
       and type error = error and type scope = Eio.Switch.t
       and type connection_options = connection_options and type connection = t
  end
end

module Translation : sig
  type error =
    | Websocket of Eta_http_eio.Ws.Client.ws_error
    | Openai_error of Eta_ai_openai.Error.t
    | Concurrent_read
    | Already_finished
    | Finished
    | Aborted
    | Timeout
  type t
  val connect : ?base_url:string -> ?safety_identifier:string -> ?max_message_size:int -> ?max_pending_events:int -> sw:Eio.Switch.t -> net:_ Eio.Net.t -> api_key:Eta_ai.api_key -> session:Eta_ai_openai.Audio.Realtime.Translation.session -> unit -> (t, error) Eta.Effect.t
  val connect_session_on_flow : ?key:string -> ?safety_identifier:string -> ?max_message_size:int -> ?max_pending_events:int -> sw:Eio.Switch.t -> flow:Eta_http_eio.Ws.Client.flow -> api_key:Eta_ai.api_key -> Eta_http.Core.Url.t -> Eta_ai_openai.Audio.Realtime.Translation.session -> (t, error) Eta.Effect.t
  val send_event : t -> Eta_ai_openai.Audio.Realtime.Translation.client_event -> (unit, error) Eta.Effect.t
  val events : t -> (Eta_ai_openai.Audio.Realtime.Translation.server_event, error) Eta_stream.Stream.t
  val read_event : t -> (Eta_ai_openai.Audio.Realtime.Translation.server_event option, error) Eta.Effect.t
  val finish : t -> (unit, error) Eta.Effect.t
  val finish_with_timeout : timeout:Eta.Duration.t -> t -> (unit, error) Eta.Effect.t
  val abort : t -> (unit, error) Eta.Effect.t
  module Transport : sig
    include Eta_ai.Realtime.Transport
      with type session = Eta_ai_openai.Audio.Realtime.Translation.session
       and type client_event = Eta_ai_openai.Audio.Realtime.Translation.client_event
       and type server_event = Eta_ai_openai.Audio.Realtime.Translation.server_event
       and type error = error and type scope = Eio.Switch.t
       and type connection_options = connection_options and type connection = t
  end
end
