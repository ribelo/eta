(** Failure causes that cannot fit in OCaml's [('a, 'e) result].

    [Fail] is the typed error channel. [Die] is an unchecked exception
    from user code or the host runtime, with diagnostic context captured by
    the runtime. [Interrupt] is cancellation, with an optional runtime-owned
    interruption identity.

    [Sequential] preserves ordered failures from sequential composition.
    [Concurrent] preserves failures observed from parallel composition.
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

type 'err t =
  | Fail of 'err
  | Die of die
  | Interrupt of interrupt_id option
  | Sequential of 'err t list
  | Concurrent of 'err t list
  | Suppressed of { primary : 'err t; finalizer : 'err t }

type 'err same_domain_t = 'err t

(** Portable mirror for failures that cross domain boundaries.

    Same-domain {!t} keeps raw [exn] and [Printexc.raw_backtrace] so local
    diagnostics preserve OCaml exception identity. [Portable.t] materializes
    those raw fields into strings before moving causes through Parallel. *)
module Portable : sig
  type die : value mod portable = {
    kind : string;
    message : string;
    backtrace : string option;
    span_name : string option;
    annotations : (string * string) list;
  }

  type ('err : value mod portable) t : value mod portable =
    | Fail of 'err
    | Die of die
    | Interrupt of interrupt_id option
    | Sequential of 'err t list
    | Concurrent of 'err t list
    | Suppressed of { primary : 'err t; finalizer : 'err t }

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
val interrupt : 'err t
val interrupt_with_id : interrupt_id -> 'err t
val sequential : 'err t list -> 'err t
val concurrent : 'err t list -> 'err t
val suppressed : primary:'err t -> finalizer:'err t -> 'err t

val is_interrupt_only : 'err t -> bool

val equal : ('err -> 'err -> bool) -> 'err t -> 'err t -> bool
val pp : (Format.formatter -> 'err -> unit) -> Format.formatter -> 'err t -> unit
val to_portable : ('err -> 'portable_err) -> 'err t -> 'portable_err Portable.t
