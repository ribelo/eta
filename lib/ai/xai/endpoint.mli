(** Role-typed xAI HTTP authorities.

    Separate nominal types prevent an inference credential from being routed
    through a management endpoint configuration, or vice versa. Proxy and test
    authorities remain configurable through the role-specific constructors. *)

type inference
type management

val inference : string -> (inference, Xai_error.t) result
val management : string -> (management, Xai_error.t) result

val default_inference : inference
val default_management : management

val inference_base_url : inference -> string
val management_base_url : management -> string
