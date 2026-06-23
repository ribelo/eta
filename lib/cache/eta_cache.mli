(** Effect-integrated keyed cache for Eta.

    The cache stores completed lookup successes and typed failures for a
    per-result TTL, deduplicates concurrent cold-key lookups, and evicts
    completed entries with plain LRU when capacity is exceeded. In-flight
    lookups are tracked for single-flight sharing but are not retained cache
    entries for [size] and [stats.current_size]. *)

module type Key = Hashtbl.HashedType

module Make (Key : Key) : sig
  type key = Key.t
  type ('value, 'err) t

  type stats = {
    hits : int;
    misses : int;
    loads : int;
    load_failures : int;
    evictions : int;
    expirations : int;
    current_size : int;
  }
  (** Snapshot of cache counters.

      [hits] counts completed-entry hits from [get]. [misses] counts [get]
      calls that started a lookup. [loads] counts lookup executions from [get]
      misses and [refresh]. [load_failures] counts lookup exits that are not
      successful. [current_size] counts completed entries retained by the
      cache, not in-flight loads. *)

  val make :
    capacity:int ->
    lookup:(key -> ('value, 'err) Eta.Effect.t) ->
    time_to_live:(('value, 'err) Eta.Exit.t -> key -> Eta.Duration.t) ->
    (('value, 'err) t, 'never) Eta.Effect.t
  (** Create a cache.

      [capacity] bounds retained completed entries and must be positive.
      [lookup] runs outside the cache lock. [time_to_live exit key] decides how
      long a successful or typed-failed lookup result is retained.
      [Eta.Duration.zero] means the result is not cached.

      Interrupted, interruption-containing, and defective lookups are delivered
      to current waiters but are not cached; a later [get] retries the key.

      @raise Invalid_argument if [capacity <= 0]. *)

  val get : ('value, 'err) t -> key -> ('value, 'err) Eta.Effect.t
  (** Return the cached value for [key], or run [lookup key].

      Concurrent cold [get] calls for the same key share one lookup and receive
      the same exit. *)

  val get_if_present :
    ('value, 'err) t ->
    key ->
    (('value, 'err) Eta.Exit.t option, 'never) Eta.Effect.t
  (** Return the retained exit for [key] without invoking the lookup. Expired
      entries are removed and reported as absent. *)

  val refresh : ('value, 'err) t -> key -> ('value, 'err) Eta.Effect.t
  (** Run [lookup key] and update the cache from its exit. Existing completed
      entries remain visible to [get] while refresh is running. *)

  val invalidate :
    ('value, 'err) t -> key -> (unit, 'never) Eta.Effect.t
  (** Remove [key] if it is present. In-flight waiters are not cancelled. *)

  val invalidate_all : ('value, 'err) t -> (unit, 'never) Eta.Effect.t
  (** Remove all retained and in-flight table entries. Existing in-flight
      waiters still complete from their already-started lookup. *)

  val size : ('value, 'err) t -> (int, 'never) Eta.Effect.t
  (** Number of completed entries currently retained. *)

  val stats : ('value, 'err) t -> (stats, 'never) Eta.Effect.t
  (** Return a counter snapshot. *)
end
