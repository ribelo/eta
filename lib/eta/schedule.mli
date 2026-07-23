(** Stateful recurrence-policy descriptions. Drives retry/repeat/resource
    refresh loops. *)

type ('input, 'output) t
(** A schedule consumes values of ['input] and produces ['output] values while
    deciding whether to continue and how long to wait before the next step. *)

type ('input, 'output) metadata = {
  input : 'input;
  output : 'output;
  attempt : int;
  start_ms : int;
  now_ms : int;
  elapsed : Duration.t;
  elapsed_since_previous : Duration.t;
  delay : Duration.t;
}
(** Metadata for a completed schedule step. [delay] is the sleep before the next
    recurrence when the decision is [Continue]; it is [Duration.zero] for
    [Done]. *)

type ('input, 'output) decision =
  | Continue of ('input, 'output) metadata
  | Done of ('input, 'output) metadata

type ('left, 'right) and_then_output =
  | First_phase of 'left
  | Second_phase of 'right
(** Output produced by {!and_then}; first-phase steps are wrapped in
    [First_phase], and second-phase steps are wrapped in [Second_phase]. *)

val recurs : int -> ('input, int) t
val forever : ('input, int) t
val spaced : Duration.t -> ('input, int) t
val fixed : Duration.t -> ('input, int) t
val windowed : Duration.t -> ('input, int) t
val exponential : ?factor:float -> Duration.t -> ('input, Duration.t) t
val fibonacci : Duration.t -> ('input, Duration.t) t
val linear : initial:Duration.t -> step:Duration.t -> ('input, Duration.t) t
val elapsed : ('input, Duration.t) t
val during : Duration.t -> ('input, Duration.t) t
val recur_until : ('input -> bool) -> ('input, 'input) t

val both :
  ('input, 'a) t ->
  ('input, 'b) t ->
  ('input, 'a * 'b) t
val either :
  ('input, 'a) t ->
  ('input, 'b) t ->
  ('input, 'a * 'b) t
val and_then :
  ('input, 'left) t ->
  ('input, 'right) t ->
  ('input, ('left, 'right) and_then_output) t
val modify_delay :
  ('output -> Duration.t -> Duration.t) ->
  ('input, 'output) t ->
  ('input, 'output) t
val while_output :
  ('output -> bool) ->
  ('input, 'output) t ->
  ('input, 'output) t

val jittered :
  ?min:float ->
  ?max:float ->
  ('input, 'output) t ->
  ('input, 'output) t
val named : string -> ('input, 'output) t -> ('input, 'output) t
(** Attach a label used by {!pp}. Naming does not change stepping and does not
    itself emit logs, spans, or metrics. *)

val pp : Format.formatter -> ('input, 'output) t -> unit

type ('input, 'output) driver

val start :
  ?random:Capabilities.random ->
  ('input, 'output) t ->
  ('input, 'output) driver
(** Start a stateful schedule driver. [Jittered] draws from [random]. Portable
    runtimes should pass an explicit worker-safe random capability instead of
    relying on the same-domain default. *)

val step :
  now_ms:int ->
  input:'input ->
  ('input, 'output) driver ->
  ('input, 'output) decision * ('input, 'output) driver
(** Step a schedule using the supplied current runtime clock and input value. *)

val next :
  now_ms:int ->
  input:'input ->
  ('input, 'output) driver ->
  (('input, 'output) metadata * ('input, 'output) driver) option
(** Step a schedule and return [Some metadata] only when it continues. This is a
    convenience for callers that only need recurrence delays; use {!step} when
    the final [Done] output matters. *)
