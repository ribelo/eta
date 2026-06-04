(** HTTP/2 client socket writer adapter. *)

type drain_result : immutable_data =
  | Yield of { written : int }
  | Close of {
      written : int;
      code : int;
    }

val cstructs_of_iovecs : Bigstringaf.t H2.IOVec.t list -> Cstruct.t list
val write_iovecs :
  flow:[> Eio.Flow.sink_ty] Eio.Resource.t ->
  Bigstringaf.t H2.IOVec.t list ->
  int

val drain_client :
  flow:[> Eio.Flow.sink_ty] Eio.Resource.t ->
  H2.Client_connection.t ->
  drain_result

val run_client :
  write:(Bigstringaf.t H2.IOVec.t list -> (int, 'err) Eta.Effect.t) ->
  H2.Client_connection.t ->
  (unit, 'err) Eta.Effect.t
