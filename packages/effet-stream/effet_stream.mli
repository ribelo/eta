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

  type ('env, 'err, 'a) t

  val empty : ('env, 'err, 'a) t
  val succeed : 'a -> ('env, 'err, 'a) t
  val from_chunk : 'a chunk -> ('env, 'err, 'a) t
  val from_iterable : 'a list -> ('env, 'err, 'a) t
  val from_effect : ('env, 'err, 'a) Effet.Effect.t -> ('env, 'err, 'a) t
  val fail : 'err -> ('env, 'err, 'a) t

  val map : ('a -> 'b) -> ('env, 'err, 'a) t -> ('env, 'err, 'b) t
  val map_effect :
    ('a -> ('env, 'err, 'b) Effet.Effect.t) ->
    ('env, 'err, 'a) t ->
    ('env, 'err, 'b) t
  val filter : ('a -> bool) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val take : int -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val drop : int -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val scan : ('s -> 'a -> 's) -> 's -> ('env, 'err, 'a) t -> ('env, 'err, 's) t

  val concat :
    ('env, 'err, 'a) t -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val flat_map :
    ('a -> ('env, 'err, 'b) t) -> ('env, 'err, 'a) t -> ('env, 'err, 'b) t

  val merge :
    ('env, 'err, 'a) t -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  (** Run both streams concurrently and interleave emitted values. Downstream
      completion, for example through {!take}, cancels both upstream producers. *)

  val flat_map_par :
    max_concurrency:int ->
    ('a -> ('env, 'err, 'b) t) ->
    ('env, 'err, 'a) t ->
    ('env, 'err, 'b) t
  (** Evaluate inner streams concurrently, with at most [max_concurrency]
      active inners at once.

      @raise Invalid_argument if [max_concurrency <= 0]. *)

  val from_eio_stream : 'a Eio.Stream.t -> ('env, 'err, 'a) t
  (** Pull values from an existing [Eio.Stream.t]. Ownership of the queue and
      its producers remains with the caller. This source has no end-of-stream
      marker; use operators such as {!take} when consuming finite prefixes. *)

  val from_file :
    ?chunk_size:int ->
    [> Eio.Fs.dir_ty ] Eio.Path.t ->
    ('env, [> `File_error of file_error ], bytes) t
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
    ('env, 'err, bytes) t
  (** Like {!from_file}, but maps the public [file_error] record into an
      application-specific typed error. *)

  val named : string -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  val fn :
    string * int * int * int ->
    string ->
    ('env, 'err, 'a) t ->
    ('env, 'err, 'a) t
end

module Sink : sig
  type ('env, 'err, 'in_, 'out) t

  val fold :
    ('out -> 'in_ -> 'out) -> 'out -> ('env, 'err, 'in_, 'out) t
  val fold_effect :
    ('out -> 'in_ -> ('env, 'err, 'out) Effet.Effect.t) ->
    'out ->
    ('env, 'err, 'in_, 'out) t
  val collect_to_list : ('env, 'err, 'a, 'a list) t
  val count : ('env, 'err, 'a, int) t
  val drain : ('env, 'err, 'a, unit) t
end

val run :
  ('env, 'err, 'a) Stream.t ->
  ('env, 'err, 'a, 'b) Sink.t ->
  ('env, 'err, 'b) Effet.Effect.t

val run_collect :
  ('env, 'err, 'a) Stream.t -> ('env, 'err, 'a list) Effet.Effect.t

val run_drain : ('env, 'err, 'a) Stream.t -> ('env, 'err, unit) Effet.Effect.t
