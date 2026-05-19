(** Canonical capability traits shipped by Effet.

    These are object-type aliases that effect helpers can require via
    row polymorphism. An application's [env] is just an object that
    happens to have the methods these traits demand.

    Example:

    {[
      type env = <
        clock : Effet.Capabilities.clock;
        http  : my_http;
        ..
      >
    ]}

    Effect helpers then write:

    {[
      let sleep ms : (<clock : clock; ..>, _, unit) Effect.t = ...
    ]}

    and OCaml's row polymorphism composes them automatically. *)

(** A clock can sleep for a duration. Every Effet runtime supplies a
    default clock backed by [Eio.Time.clock]. *)
class type clock = object
  method sleep : Duration.t -> unit
end

(** An optional logger. Provided as an example trait; not required. *)
class type log = object
  method info : string -> unit
  method warn : string -> unit
  method error : string -> unit
end

(** Bridge an [Eio.Time.clock] into the [clock] trait. *)
val clock_of_eio :
  [> float Eio.Time.clock_ty ] Eio.Std.r -> clock
