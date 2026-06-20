(** HTTP/2 client socket writer adapter. *)

type drain_result =
  | Yield of { written : int }
  | Close of {
      written : int;
      code : int;
    }

val cstructs_of_iovecs :
  Bigstringaf.t Eta_http_h2.Iovec.t list -> Cstruct.t list
val write_iovecs :
  flow:[> Eio.Flow.sink_ty] Eio.Resource.t ->
  Bigstringaf.t Eta_http_h2.Iovec.t list ->
  int

val drain_client :
  flow:[> Eio.Flow.sink_ty] Eio.Resource.t ->
  Eta_http_h2.Connection.t ->
  drain_result

val run_client :
  write:(Bigstringaf.t Eta_http_h2.Iovec.t list -> (int, 'err) Eta.Effect.t) ->
  Eta_http_h2.Connection.t ->
  (unit, 'err) Eta.Effect.t
