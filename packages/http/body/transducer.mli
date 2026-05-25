(** Streaming body transducers.

    Gzip uses the [decompress] package. The eta-http wrapper owns expansion
    caps and typed error mapping; [decompress] owns gzip format and CRC checks. *)

type context = {
  protocol : Http_error.Error.protocol;
  method_ : string;
  uri : string;
}

val default_max_decoded_bytes : int

val gzip_decode :
  ?max_decoded_bytes:int ->
  ?context:context ->
  Stream.t ->
  Stream.t

val gzip_encode :
  ?level:int ->
  ?context:context ->
  Stream.t ->
  Stream.t
