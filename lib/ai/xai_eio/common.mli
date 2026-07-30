type error =
  [ Eta_http_eio.Ws.Client.ws_error
  | `Decode of string
  | `Invalid_request of string
  | `Xai_error of Eta_ai_xai.Error.t
  ]

type t
type sender

val headers : Eta_ai.api_key -> Eta_http.Core.Header.t
val secret_headers : Eta_ai_xai.Realtime.client_secret -> Eta_http.Core.Header.t

val connect :
  ?ca_file:string ->
  ?protocols:string list ->
  ?attrs:(string * string) list ->
  operation:string ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  headers:Eta_http.Core.Header.t ->
  string ->
  (t, error) Eta.Effect.t

val connect_on_flow :
  ?key:string ->
  ?protocols:string list ->
  ?attrs:(string * string) list ->
  operation:string ->
  sw:Eio.Switch.t ->
  flow:Eta_http_eio.Ws.Client.flow ->
  headers:Eta_http.Core.Header.t ->
  Eta_http.Core.Url.t ->
  (t, error) Eta.Effect.t

val send_text : t -> string -> (unit, error) Eta.Effect.t
val send_binary : t -> bytes -> (unit, error) Eta.Effect.t
val with_send :
  t -> (sender -> ('a, error) Eta.Effect.t) -> ('a, error) Eta.Effect.t
val send_text_locked : sender -> string -> (unit, error) Eta.Effect.t
val send_binary_locked : sender -> bytes -> (unit, error) Eta.Effect.t
val read_message :
  t -> (Eta_http_eio.Ws.Client.message option, error) Eta.Effect.t
val close : ?error_type:string -> t -> (unit, error) Eta.Effect.t
val record_attrs : t -> (string * string) list -> unit
val is_closing : t -> bool

val ws_base_url :
  Eta_ai_xai.Endpoint.inference -> (string, [ `Invalid_request of string ]) result
val query_url : string -> string -> (string * string) list -> string
val bool_string : bool -> string
val float_string : float -> string
val xai_error_message : Eta_ai_xai.Error.t -> string
