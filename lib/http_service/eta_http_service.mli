(** Composable HTTP service helpers over {!Eta_http.Server.handler}.

    This package deliberately keeps {!Eta_http.Server.handler} as the only
    service seam. Routers compile to handlers, middleware wraps handlers, and
    extractors pull typed values from routed requests. *)

module Req : sig
  type t

  val raw : t -> Eta_http.Server.Request.t
  val params : t -> Eta_router.Params.t
  val route_pattern : t -> string
  val param : t -> string -> string option
  val path : t -> string
  val target : t -> string
  val query : t -> string option
  val method_ : t -> string
  val header : t -> string -> string option
  val body : t -> Eta_http.Server.Body.t
end

module Router : sig
  type route =
    Req.t ->
    (Eta_http.Server.Response.t, Eta_http.Server.Error.t) Eta.Effect.t

  type registration_error =
    | Empty_method_set of { pattern : string }
    | Invalid_method of { pattern : string; method_ : string }
    | Duplicate_route of { pattern : string; method_ : string option }
    | Ambiguous_any_route of { pattern : string }
    | Invalid_pattern of {
        pattern : string;
        reason : Eta_router.Error.insert;
      }

  type t

  val pp_registration_error : Format.formatter -> registration_error -> unit
  val create : unit -> t

  val add :
    t ->
    methods:string list ->
    string ->
    route ->
    (unit, registration_error) result
  (** [add t ~methods pattern route] registers [route] for an explicit,
      non-empty method set. Methods are matched exactly. *)

  val add_exn : t -> methods:string list -> string -> route -> unit

  val add_any :
    t ->
    string ->
    route ->
    (unit, registration_error) result
  (** [add_any t pattern route] registers a method-agnostic route. It is an
      error to combine an any-method route and method-specific routes for the
      same pattern. *)

  val add_any_exn : t -> string -> route -> unit

  val compile :
    ?not_found:Eta_http.Server.handler ->
    ?method_not_allowed:
      (allowed:string list -> Eta_http.Server.handler) ->
    t ->
    Eta_http.Server.handler
end

module Extractors : sig
  module Param : sig
    val string :
      string -> Req.t -> (string, Eta_http.Server.Error.t) Eta.Effect.t

    val int : string -> Req.t -> (int, Eta_http.Server.Error.t) Eta.Effect.t
  end

  module Query : sig
    type t = (string * string) list

    val all : Req.t -> (t, Eta_http.Server.Error.t) Eta.Effect.t
    val get : string -> t -> string option
    val get_all : string -> t -> string list

    val single :
      string -> Req.t -> (string option, Eta_http.Server.Error.t) Eta.Effect.t

    val required :
      string -> Req.t -> (string, Eta_http.Server.Error.t) Eta.Effect.t

    val int :
      string -> Req.t -> (int option, Eta_http.Server.Error.t) Eta.Effect.t
  end

  val header :
    string -> Req.t -> (string option, Eta_http.Server.Error.t) Eta.Effect.t

  val body_text :
    max_bytes:int ->
    Req.t ->
    (string, Eta_http.Server.Error.t) Eta.Effect.t

  val json_body :
    max_bytes:int ->
    (Yojson.Safe.t -> ('a, string) result) ->
    Req.t ->
    ('a, Eta_http.Server.Error.t) Eta.Effect.t

  val route1 :
    (Req.t -> ('a, Eta_http.Server.Error.t) Eta.Effect.t) ->
    ('a ->
    (Eta_http.Server.Response.t, Eta_http.Server.Error.t) Eta.Effect.t) ->
    Router.route

  val route2 :
    (Req.t -> ('a, Eta_http.Server.Error.t) Eta.Effect.t) ->
    (Req.t -> ('b, Eta_http.Server.Error.t) Eta.Effect.t) ->
    ('a ->
    'b ->
    (Eta_http.Server.Response.t, Eta_http.Server.Error.t) Eta.Effect.t) ->
    Router.route

  val route3 :
    (Req.t -> ('a, Eta_http.Server.Error.t) Eta.Effect.t) ->
    (Req.t -> ('b, Eta_http.Server.Error.t) Eta.Effect.t) ->
    (Req.t -> ('c, Eta_http.Server.Error.t) Eta.Effect.t) ->
    ('a ->
    'b ->
    'c ->
    (Eta_http.Server.Response.t, Eta_http.Server.Error.t) Eta.Effect.t) ->
    Router.route
end

module Json : sig
  val content_type : string
  val headers : Eta_http.Core.Header.t

  val response :
    ?status:int ->
    ?newline:bool ->
    Yojson.Safe.t ->
    Eta_http.Server.Response.t
end

module Middleware : sig
  type t = Eta_http.Server.handler -> Eta_http.Server.handler

  type access_log_entry = {
    request_id : string;
    method_ : string;
    target : string;
    path : string;
    status : int option;
    error_class : string option;
  }

  val compose : t list -> t
  val request_id : ?header:string -> unit -> t
  val access_log : log:(access_log_entry -> unit) -> t
  val timeout : Eta.Duration.t -> t
  val admission : Eta.Semaphore.t -> t

  val cors :
    ?allow_origin:string ->
    ?allow_methods:string list ->
    ?allow_headers:string list ->
    unit ->
    t

  val bearer_auth :
    verify:
      (token:string option ->
      Eta_http.Server.Request.t ->
      (unit, Eta_http.Server.Error.t) Eta.Effect.t) ->
    t
end
