(** Pull-based, chunked streams for Effet. *)

type +'a chunk = 'a list

module Stream : sig
  type file_operation = [ `Close | `Open | `Read ]
  type file_error_kind =
    [ `Already_exists
    | `File_too_large
    | `Io
    | `Not_found
    | `Not_native
    | `Permission_denied
    | `Unexpected ]

  type file_error = {
    operation : file_operation;
    path : string;
    kind : file_error_kind;
    message : string;
    cause : exn;
  }
  (** Typed file-system failure reported by {!from_file}. [path] is the
      printable Eio path label, [kind] is a stable coarse classification,
      [message] is formatted with {!Eio.Exn.pp}, and [cause] preserves the
      original exception for diagnostics. *)

  val pp_file_error : Format.formatter -> file_error -> unit

  type ('a, 'err) t

  val empty : ('a, 'err) t
  val succeed : 'a -> ('a, 'err) t
  val from_chunk : 'a chunk -> ('a, 'err) t
  val from_iterable : 'a list -> ('a, 'err) t
  val from_effect : ('a, 'err) Effet.Effect.t -> ('a, 'err) t
  val fail : 'err -> ('a, 'err) t

  val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
  val map_effect :
    ('a -> ('b, 'err) Effet.Effect.t) ->
    ('a, 'err) t ->
    ('b, 'err) t
  val filter : ('a -> bool) -> ('a, 'err) t -> ('a, 'err) t
  val take : int -> ('a, 'err) t -> ('a, 'err) t
  val drop : int -> ('a, 'err) t -> ('a, 'err) t
  val scan : ('s -> 'a -> 's) -> 's -> ('a, 'err) t -> ('s, 'err) t

  val concat :
    ('a, 'err) t -> ('a, 'err) t -> ('a, 'err) t
  val flat_map :
    ('a -> ('b, 'err) t) -> ('a, 'err) t -> ('b, 'err) t

  val merge :
    ('a, 'err) t -> ('a, 'err) t -> ('a, 'err) t
  (** Run both streams concurrently and interleave emitted values. Downstream
      completion, for example through {!take}, cancels both upstream producers. *)

  val flat_map_par :
    max_concurrency:int ->
    ('a -> ('b, 'err) t) ->
    ('a, 'err) t ->
    ('b, 'err) t
  (** Evaluate inner streams concurrently, with at most [max_concurrency]
      active inners at once.

      @raise Invalid_argument if [max_concurrency <= 0]. *)

  val from_eio_stream : 'a Eio.Stream.t -> ('a, 'err) t
  (** Pull values from an existing [Eio.Stream.t]. Ownership of the queue and
      its producers remains with the caller. This source has no end-of-stream
      marker; use operators such as {!take} when consuming finite prefixes. *)

  val from_file :
    ?chunk_size:int ->
    [> Eio.Fs.dir_ty ] Eio.Path.t ->
    (bytes, [> `File_error of file_error ]) t
  (** Read a file as a stream of [bytes] chunks.

      The source opens the file when the stream is run, reads at most
      [chunk_size] bytes per emitted chunk, and closes the descriptor when the
      stream finishes, fails, or is stopped early by downstream operators such
      as {!take}. The default [chunk_size] is 64 KiB.

      File I/O exceptions are reported in the typed error channel as
      [`File_error error]. Cancellation remains interruption, and downstream
      failures are not wrapped.

      Use {!from_file_map_error} when an application wants to map file errors
      into its own error variant instead of exposing [`File_error _].

      @raise Invalid_argument if [chunk_size <= 0]. *)

  val from_file_map_error :
    ?chunk_size:int ->
    on_error:(file_error -> 'err) ->
    [> Eio.Fs.dir_ty ] Eio.Path.t ->
    (bytes, 'err) t
  (** Like {!from_file}, but maps the public [file_error] record into an
      application-specific typed error. *)

  val named : string -> ('a, 'err) t -> ('a, 'err) t
  val fn :
    string * int * int * int ->
    string ->
    ('a, 'err) t ->
    ('a, 'err) t
end

module Sink : sig
  type ('in_, 'out, 'err) t

  val fold :
    ('out -> 'in_ -> 'out) -> 'out -> ('in_, 'out, 'err) t
  val fold_effect :
    ('out -> 'in_ -> ('out, 'err) Effet.Effect.t) ->
    'out ->
    ('in_, 'out, 'err) t
  val collect_to_list : ('a, 'a list, 'err) t
  val count : ('a, int, 'err) t
  val drain : ('a, unit, 'err) t
end

val run :
  ('a, 'err) Stream.t ->
  ('a, 'b, 'err) Sink.t ->
  ('b, 'err) Effet.Effect.t

val run_collect : ('a, 'err) Stream.t -> ('a list, 'err) Effet.Effect.t

val run_drain : ('a, 'err) Stream.t -> (unit, 'err) Effet.Effect.t
