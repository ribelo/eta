(** Stateful recurrence-policy descriptions. Drives retry/repeat/resource
    refresh loops. *)

type ('input, 'output, 'hook) t
(** A schedule consumes values of ['input] and produces ['output] values while
    deciding whether to continue and how long to wait before the next step.
    Schedule policy owns ['hook] values and their structural order; a driver
    owns their interpretation through {!step_plan} or {!step_with_hooks}. *)

type no_hook = |
(** Marker for schedules that have no effectful tap hooks and can be stepped
    directly with {!step} / {!next}. *)

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

val recurs : int -> ('input, int, 'hook) t
val forever : ('input, int, 'hook) t
val spaced : Duration.t -> ('input, int, 'hook) t
val fixed : Duration.t -> ('input, int, 'hook) t
val windowed : Duration.t -> ('input, int, 'hook) t
val exponential : ?factor:float -> Duration.t -> ('input, Duration.t, 'hook) t
val fibonacci : Duration.t -> ('input, Duration.t, 'hook) t
val linear : initial:Duration.t -> step:Duration.t -> ('input, Duration.t, 'hook) t
val elapsed : ('input, Duration.t, 'hook) t
val during : Duration.t -> ('input, Duration.t, 'hook) t
val recur_until : ('input -> bool) -> ('input, 'input, 'hook) t

val both :
  ('input, 'a, 'hook) t ->
  ('input, 'b, 'hook) t ->
  ('input, 'a * 'b, 'hook) t
val either :
  ('input, 'a, 'hook) t ->
  ('input, 'b, 'hook) t ->
  ('input, 'a * 'b, 'hook) t
val and_then :
  ('input, 'left, 'hook) t ->
  ('input, 'right, 'hook) t ->
  ('input, ('left, 'right) and_then_output, 'hook) t
val modify_delay :
  ('output -> Duration.t -> Duration.t) ->
  ('input, 'output, 'hook) t ->
  ('input, 'output, 'hook) t
val while_output :
  ('output -> bool) ->
  ('input, 'output, 'hook) t ->
  ('input, 'output, 'hook) t
val tap_input :
  ('input -> 'hook) ->
  ('input, 'output, 'hook) t ->
  ('input, 'output, 'hook) t
(** Run an effectful hook before each inner schedule step. Eta's effect
    drivers instantiate ['hook] as [(unit, _) Effect.t]; if the hook fails,
    the inner schedule state is not advanced. *)

val tap_output :
  ('output -> 'hook) ->
  ('input, 'output, 'hook) t ->
  ('input, 'output, 'hook) t
(** Run an effectful hook after each inner schedule step produces an output,
    including terminal [Done] outputs. Eta's effect drivers instantiate
    ['hook] as [(unit, _) Effect.t]. *)

val jittered :
  ?min:float ->
  ?max:float ->
  ('input, 'output, 'hook) t ->
  ('input, 'output, 'hook) t
val named : string -> ('input, 'output, 'hook) t -> ('input, 'output, 'hook) t

val pp : Format.formatter -> ('input, 'output, 'hook) t -> unit

type ('input, 'output, 'hook) driver

val start :
  ?random:Capabilities.random ->
  ('input, 'output, 'hook) t ->
  ('input, 'output, 'hook) driver
(** Start a stateful schedule driver. [Jittered] draws from [random]. Portable
    runtimes should pass an explicit worker-safe random capability instead of
    relying on the same-domain default. *)

type ('input, 'output, 'hook) step =
  | Complete of
      ('input, 'output) decision * ('input, 'output, 'hook) driver
  | Hook of 'hook * (unit -> ('input, 'output, 'hook) step)
(** Suspended schedule step. Callers that drive effectful taps can run [Hook]
    values in their own effect system and resume only after the hook succeeds. *)

val step_plan :
  now_ms:int ->
  input:'input ->
  ('input, 'output, 'hook) driver ->
  ('input, 'output, 'hook) step

val step_with_hooks :
  run_hook:('hook -> unit) ->
  now_ms:int ->
  input:'input ->
  ('input, 'output, 'hook) driver ->
  ('input, 'output) decision * ('input, 'output, 'hook) driver
(** Step a schedule with an explicit hook interpreter. Effect drivers pass an
    interpreter that runs hook effects in the current Eta runtime. *)

val step :
  now_ms:int ->
  input:'input ->
  ('input, 'output, no_hook) driver ->
  ('input, 'output) decision * ('input, 'output, no_hook) driver
(** Step a schedule with no effectful hooks using the current runtime clock and
    input value. *)

val next :
  now_ms:int ->
  input:'input ->
  ('input, 'output, no_hook) driver ->
  (('input, 'output) metadata * ('input, 'output, no_hook) driver) option
(** Step a schedule and return [Some metadata] only when it continues. This is a
    convenience for callers that only need recurrence delays; use {!step} when
    the final [Done] output matters. *)
