(** Same-runtime bounded resource pool for eta_js fibers. *)

type ('conn, 'err) t

type stats = {
  active : int;
  idle : int;
  waiting : int;
  max_size : int;
  opened : int;
  closed : int;
  health_rejected : int;
  cancelled_waiters : int;
  shutting_down : bool;
}

val create :
  ?name:string ->
  ?kind:string ->
  max_size:int ->
  ?max_idle:int ->
  ?idle_lifetime:Duration.t ->
  ?max_lifetime:Duration.t ->
  ?idle_check_interval:Duration.t ->
  acquire:('conn, ([> `Pool_shutdown ] as 'err)) Effect.t ->
  release:('conn -> (unit, 'err) Effect.t) ->
  ?health_check:('conn -> (unit, 'err) Effect.t) ->
  unit ->
  (('conn, 'err) t, 'err) Effect.t

val with_resource :
  ('conn, ([> `Pool_shutdown ] as 'err)) t ->
  ('conn -> ('a, 'err) Effect.t) ->
  ('a, 'err) Effect.t

val shutdown :
  ?deadline:Duration.t ->
  ('conn, ([> `Pool_shutdown_timeout ] as 'err)) t ->
  (unit, 'err) Effect.t

val stats : ('conn, 'err) t -> stats
