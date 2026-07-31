(** Transport-neutral multipart/form-data construction. *)

type replayability = Replayable | One_shot

type reader = unit -> bytes option

type source = {
  length : int64 option;
  replayability : replayability;
  open_reader : unit -> reader;
}
(** A pull source. [length], when present, is the exact source length.
    [open_reader] is not called during multipart construction. A replayable
    source opens a fresh reader for each body attempt. *)

type data = Buffered of bytes | Pull of source

type part =
  | Text of {
      name : string;
      value : string;
    }
  | File of {
      name : string;
      filename : string;
      content_type : string;
      data : data;
    }

type error =
  | Empty
  | Invalid_disposition of string
  | Invalid_header of string
  | Length_overflow
  | Impossible_shape of string

type t = private {
  boundary : string;
  content_length : int64 option;
  body : Request.body;
}

val error_message : error -> string

val make : part list -> (t, error) result
(** Build one multipart body.

    Buffered parts use a deterministic content-derived Eta-prefixed boundary
    absent from all encoded metadata and payloads, and produce [Request.Fixed].

    Pull parts use a fresh Eta-prefixed boundary and do not preread or spool
    sources. The body is replayable only when all pull sources are replayable.
    Otherwise it is one-shot, with a known-length one-shot body when every
    source length is known. [content_length] is exact only when every source
    length is known.

    The body preserves noncolliding source bytes in order. It detects
    [CRLF "--" boundary] at source start and across arbitrary source
    partitions, and fails with [Error.t] before emitting bytes that complete
    that delimiter. It also fails if a source emits a byte count different
    from its declared length. Source exceptions become [Error.t]. *)
