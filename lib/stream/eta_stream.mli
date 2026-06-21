(** Pull-based, chunked streams for Eta. *)

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
    diagnostic : string;
  }
  (** Typed file-system failure reported by {!from_file}. [path] is the
      printable Eio path label, [kind] is a stable coarse classification,
      and [message] is an Eta-owned diagnostic string. [diagnostic] currently
      carries the same formatted text for callers that want a named diagnostic
      field without depending on Eio exception constructors. *)

  val pp_file_error : Format.formatter -> file_error -> unit

  type ('a, 'err) t

  val empty : ('a, 'err) t
  val succeed : 'a -> ('a, 'err) t
  val from_chunk : 'a chunk -> ('a, 'err) t
  val from_iterable : 'a list -> ('a, 'err) t
  val range : start:int -> stop:int -> (int, 'err) t
  val from_effect : ('a, 'err) Eta.Effect.t -> ('a, 'err) t
  val fail : 'err -> ('a, 'err) t
  val from_schedule :
    (unit, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t ->
    ('out, 'err) t
  (** Emit each continuing output of [schedule]. Each continuing step sleeps
      for its computed delay before emitting its output; the terminal [Done]
      output is not emitted. Schedule tap failures fail the stream normally. *)

  val map : ('a -> 'b) -> ('a, 'err) t -> ('b, 'err) t
  val map_effect :
    ('a -> ('b, 'err) Eta.Effect.t) ->
    ('a, 'err) t ->
    ('b, 'err) t
  val tap :
    ('a -> (unit, 'err) Eta.Effect.t) ->
    ('a, 'err) t ->
    ('a, 'err) t
  (** Run an effectful observer for every emitted element, preserving the
      element when the observer succeeds. Observer failure fails the stream
      normally. *)

  val tap_error :
    ('err -> (unit, 'err) Eta.Effect.t) ->
    ('a, 'err) t ->
    ('a, 'err) t
  (** Run an effectful observer for typed stream failures. If the observer
      succeeds, the original failure is preserved. If the observer fails, the
      observer failure becomes the stream failure. *)

  val filter : ('a -> bool) -> ('a, 'err) t -> ('a, 'err) t
  val filter_map : ('a -> 'b option) -> ('a, 'err) t -> ('b, 'err) t
  (** Map and filter in one pass. [Some value] is emitted and [None] is
      dropped. *)

  val filter_map_effect :
    ('a -> ('b option, 'err) Eta.Effect.t) ->
    ('a, 'err) t ->
    ('b, 'err) t
  (** Effectful {!filter_map}. Mapper failure fails the stream normally. *)

  val changes : ('a, 'err) t -> ('a, 'err) t
  (** Emit the first element and then emit only values that are not
      structurally equal to the previous emitted value. *)

  val changes_with :
    ('a -> 'a -> bool) -> ('a, 'err) t -> ('a, 'err) t
  (** Emit the first element and then suppress later values when [equivalent
      previous current] returns [true], where [previous] is the previous
      emitted value. [equivalent] is expected to be an equivalence relation;
      behavior for non-equivalence predicates is not a separate Eta policy. *)

  val changes_with_effect :
    ('a -> 'a -> (bool, 'err) Eta.Effect.t) ->
    ('a, 'err) t ->
    ('a, 'err) t
  (** Effectful {!changes_with}. Comparator failure fails the stream normally. *)

  val zip :
    ('a, 'err) t -> ('b, 'err) t -> ('a * 'b, 'err) t
  (** Pair two streams point-wise. The zipped stream ends when either side
      ends; unpaired values from the longer side are discarded. *)

  val zip_with :
    ('a -> 'b -> 'c) ->
    ('a, 'err) t ->
    ('b, 'err) t ->
    ('c, 'err) t
  (** Pair two streams point-wise and combine each pair with [f]. The zipped
      stream ends when either side ends. *)

  val zip_with_index : ('a, 'err) t -> ('a * int, 'err) t
  (** Pair every emitted value with its zero-based index.

      @raise Invalid_argument if the index would exceed [max_int]. *)

  val schedule :
    ('a, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t ->
    ('a, 'err) t ->
    ('a, 'err) t
  (** Emit upstream values while [schedule] continues. Each upstream value is
      passed to the schedule as input. A continuing step emits the value and
      sleeps for its delay before the next value is processed; a terminal step
      stops the stream without emitting that value. *)

  val repeat :
    (unit, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t ->
    ('a, 'err) t ->
    ('a, 'err) t
  (** Run the whole source stream once, then repeat it for every continuing
      schedule step. Each continuing step sleeps before the next repetition.
      Source or schedule tap failures fail the stream normally. *)

  val retry :
    ('err, 'out, (unit, 'err) Eta.Effect.t) Eta.Schedule.t ->
    ('a, 'err) t ->
    ('a, 'err) t
  (** Retry the whole source stream when it fails with a typed error and
      [schedule] continues. Elements emitted before a failure remain emitted.
      If the schedule is exhausted, the final typed stream error is preserved. *)

  val timeout : Eta.Duration.t -> ('a, 'err) t -> ('a, 'err) t
  (** End the stream cleanly if the next emitted value does not arrive within
      [duration]. The timeout is per next value, not total stream lifetime, and
      resets after every emitted value. Timeout cancels the active upstream pull
      so source cleanup still runs.

      A zero duration ends immediately without starting an upstream pull. Eta's
      fold runner does not expose effect-smol's same-turn zero-duration pull
      race deterministically, so this is the reference-nearest explicit
      behavior. *)

  val take : int -> ('a, 'err) t -> ('a, 'err) t
  val take_while : ('a -> bool) -> ('a, 'err) t -> ('a, 'err) t
  (** Emit the longest leading prefix whose values satisfy [predicate].
      The first value for which [predicate] returns [false] is not emitted,
      and the stream stops. *)

  val take_while_effect :
    ('a -> (bool, 'err) Eta.Effect.t) -> ('a, 'err) t -> ('a, 'err) t
  (** Effectful {!take_while}. Predicate failure fails the stream normally. *)

  val take_until_effect :
    ('a -> (bool, 'err) Eta.Effect.t) -> ('a, 'err) t -> ('a, 'err) t
  (** Emit values until [predicate] returns [true]. The value that satisfies
      [predicate] is emitted before the stream stops. *)
  val drop : int -> ('a, 'err) t -> ('a, 'err) t
  val drop_while : ('a -> bool) -> ('a, 'err) t -> ('a, 'err) t
  (** Drop the longest leading prefix whose values satisfy [predicate].
      The first value for which [predicate] returns [false] is emitted,
      followed by the rest of the stream without rechecking the predicate. *)

  val drop_while_effect :
    ('a -> (bool, 'err) Eta.Effect.t) -> ('a, 'err) t -> ('a, 'err) t
  (** Effectful {!drop_while}. Predicate failure fails the stream normally. *)

  val drop_until : ('a -> bool) -> ('a, 'err) t -> ('a, 'err) t
  (** Drop values until [predicate] returns [true], drop that matching value
      too, then emit the rest of the stream without rechecking the predicate. *)

  val drop_until_effect :
    ('a -> (bool, 'err) Eta.Effect.t) -> ('a, 'err) t -> ('a, 'err) t
  (** Effectful {!drop_until}. Predicate failure fails the stream normally. *)

  val scan : ('s -> 'a -> 's) -> 's -> ('a, 'err) t -> ('s, 'err) t
  val grouped : int -> ('a, 'err) t -> ('a list, 'err) t
  (** Collect upstream values into non-empty batches of at most [n] items.
      The final batch may contain fewer than [n] items.

      @raise Invalid_argument if [n <= 0]. *)

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

  val from_queue : ('a, 'err) Eta.Queue.t -> ('a, 'err) t
  (** Pull values from an Eta queue. A clean queue close ends the stream;
      [Queue.close_with_error err] fails the stream with [err]. *)

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

module Mailbox : sig
  type 'a t
  type offer_result = Enqueued | Dropped | Closed

  val create : ?capacity:int -> unit -> 'a t
  (** Create a bounded producer-side stream mailbox.

      [capacity] defaults to [1024].
      @raise Invalid_argument if [capacity <= 0]. *)

  val offer : 'a t -> 'a -> offer_result
  (** Try to enqueue without waiting for capacity. Full mailboxes drop the new
      value and return [Dropped]. Closed mailboxes return [Closed]. *)

  val close : 'a t -> unit
  (** Close the mailbox. Consumers drain already-enqueued values and then the
      mailbox stream ends. *)

  val dropped : 'a t -> int
  (** Number of values dropped by {!offer}. *)

  val length : 'a t -> int
  (** Number of values currently queued. *)

  val to_stream : 'a t -> ('a, 'err) Stream.t
  (** Consume values from the mailbox as a stream. *)

  val to_batch_stream : max:int -> 'a t -> ('a list, 'err) Stream.t
  (** Consume non-empty batches from the mailbox. The consumer waits for the
      first value in each batch, then drains up to [max - 1] values already
      available without waiting for a full batch.

      @raise Invalid_argument if [max <= 0]. *)
end

module Drain_counter : sig
  type t

  val create : unit -> t
  val value : t -> int
  val incr : t -> unit
  val decr : t -> unit
  val incr_by : t -> int -> unit
  val decr_by : t -> int -> unit

  val await_zero : ?name:string -> t -> (unit, 'err) Eta.Effect.t
  (** Wait until the counter reaches zero. This is useful for producer/consumer
      adapters that need a non-polling drain signal while still exposing the
      wait as an Eta eff.

      @raise Invalid_argument if [incr_by] or [decr_by] receive a negative
      count, or if [decr_by] would decrement below zero. *)
end

module Sink : sig
  type ('in_, 'out, 'err) t

  val fold :
    ('out -> 'in_ -> 'out) -> 'out -> ('in_, 'out, 'err) t
  val fold_effect :
    ('out -> 'in_ -> ('out, 'err) Eta.Effect.t) ->
    'out ->
    ('in_, 'out, 'err) t
  val collect_to_list : ('a, 'a list, 'err) t
  val count : ('a, int, 'err) t
  val drain : ('a, unit, 'err) t
end

val run :
  ('a, 'err) Stream.t ->
  ('a, 'b, 'err) Sink.t ->
  ('b, 'err) Eta.Effect.t

val run_collect : ('a, 'err) Stream.t -> ('a list, 'err) Eta.Effect.t

val run_drain : ('a, 'err) Stream.t -> (unit, 'err) Eta.Effect.t

val run_for_each :
  ('a -> (unit, 'err) Eta.Effect.t) ->
  ('a, 'err) Stream.t ->
  (unit, 'err) Eta.Effect.t

val run_fold :
  ('acc -> 'a -> 'acc) ->
  'acc ->
  ('a, 'err) Stream.t ->
  ('acc, 'err) Eta.Effect.t

val run_count : ('a, 'err) Stream.t -> (int, 'err) Eta.Effect.t
