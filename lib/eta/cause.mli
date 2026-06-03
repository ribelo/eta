(** Failure causes that cannot fit in OCaml's [('a, 'e) result].

    [Fail] is the typed error channel. [Die] is an unchecked exception
    from user code or the host runtime, with diagnostic context captured by
    the runtime. [Interrupt] is cancellation, with an optional runtime-owned
    interruption identity.

    [Sequential] preserves ordered failures from sequential composition.
    [Concurrent] preserves failures observed from parallel composition.
    [Finalizer] marks diagnostic failures produced while cleaning up after a
    successful primary effect; ordinary [Effect.catch] leaves failures under
    this node untouched. Finalizer failures are rendered to strings when they
    leave the cleanup effect, so they are no longer part of the typed error
    channel.
    [Suppressed] preserves a primary failure together with a finalizer failure
    that occurred while cleaning up the primary failure. *)

type interrupt_id : immutable_data

(** Diagnostic payload for unchecked defects.

    [span_name] and [annotations] are copied from the active Eta
    [named]/[annotate] context when the defect is captured. [backtrace] is
    controlled by [Runtime.create ?capture_backtrace]. *)
type die = {
  exn : exn;
  backtrace : Printexc.raw_backtrace option;
  span_name : string option;
  annotations : (string * string) list;
}

module Finalizer : sig
  type t =
    | Fail of string
    | Die of die
    | Interrupt of interrupt_id option
    | Sequential of t list
    | Concurrent of t list
    | Finalizer of t
    | Suppressed of { primary : t; finalizer : t }

  val equal : t -> t -> bool
  val diagnostic_equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val is_interrupt_only : t -> bool
end

type 'err t =
  | Fail of 'err
  | Die of die
  | Interrupt of interrupt_id option
  | Sequential of 'err t list
  | Concurrent of 'err t list
  | Finalizer of Finalizer.t
  | Suppressed of { primary : 'err t; finalizer : Finalizer.t }

type 'err same_domain_t = 'err t

(** Portable mirror for failures that cross domain boundaries.

    Same-domain {!t} keeps raw [exn] and [Printexc.raw_backtrace] so local
    diagnostics preserve OCaml exception identity. [Portable.t] materializes
    those raw fields into strings before moving causes across domains. *)
module Portable : sig
  type die : value mod portable = {
    kind : string;
    message : string;
    backtrace : string option;
    span_name : string option;
    annotations : (string * string) list;
  }

  module Finalizer : sig
    type t : value mod portable =
      | Fail of string
      | Die of die
      | Interrupt of interrupt_id option
      | Sequential of t list
      | Concurrent of t list
      | Finalizer of t
      | Suppressed of { primary : t; finalizer : t }

    val equal : t -> t -> bool
    val pp : Format.formatter -> t -> unit
  end

  type ('err : value mod portable) t : value mod portable =
    | Fail of 'err
    | Die of die
    | Interrupt of interrupt_id option
    | Sequential of 'err t list
    | Concurrent of 'err t list
    | Finalizer of Finalizer.t
    | Suppressed of { primary : 'err t; finalizer : Finalizer.t }

  val of_cause : ('err -> 'portable_err) -> 'err same_domain_t -> 'portable_err t
  val equal : ('err -> 'err -> bool) -> 'err t -> 'err t -> bool
  val pp :
    (Format.formatter -> 'err -> unit) -> Format.formatter -> 'err t -> unit
end

val fail : 'err -> 'err t
val die : exn -> 'err t
val die_with_backtrace : exn -> Printexc.raw_backtrace -> 'err t
val die_with_diagnostics :
  ?backtrace:Printexc.raw_backtrace ->
  ?span_name:string ->
  ?annotations:(string * string) list ->
  exn ->
  'err t
(** Build a [Die] cause with explicit diagnostic context. Runtime defect
    capture uses this constructor internally; most application code should not
    need it. *)
val fresh_interrupt_id : unit -> interrupt_id
val equal_interrupt_id : interrupt_id -> interrupt_id -> bool
val interrupt : 'err t
val interrupt_with_id : interrupt_id -> 'err t
val sequential : 'err t list -> 'err t
(** @raise Invalid_argument if the list is empty. *)
val concurrent : 'err t list -> 'err t
(** @raise Invalid_argument if the list is empty. *)
val finalizer : Finalizer.t -> 'err t
val suppressed : primary:'err t -> finalizer:Finalizer.t -> 'err t

val is_interrupt_only : 'err t -> bool
val map : ('err1 -> 'err2) -> 'err1 t -> 'err2 t
val finalizer_of_cause : ('err -> string) -> 'err t -> Finalizer.t

val equal : ('err -> 'err -> bool) -> 'err t -> 'err t -> bool
(** Structural equality for causes. [Die] causes compare by physical exception
    identity, plus diagnostic span and annotation metadata. This preserves
    same-domain exception identity; use {!diagnostic_equal} when test code wants
    to compare materialized exception diagnostics instead. *)

val diagnostic_equal : ('err -> 'err -> bool) -> 'err t -> 'err t -> bool
(** Diagnostic equality for causes. [Die] causes compare exception slot,
    rendered exception message, rendered backtrace, span name, and annotations. *)

val pp : (Format.formatter -> 'err -> unit) -> Format.formatter -> 'err t -> unit
val to_portable : ('err -> 'portable_err) -> 'err t -> 'portable_err Portable.t
