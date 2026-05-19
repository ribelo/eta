(** Lazy, runtime-interpreted effects.

    {v
      ('env, 'err, 'a) Effect.t
        ^^^^   ^^^   ^^
        env    err   success
    v}

    - ['env] is the requirement channel. Prefer structural object types
      for capabilities, e.g. [< clock : Capabilities.clock; .. >].
    - ['err] is the typed failure channel. Polymorphic variants work well:
      [[> `Http_404 | `Db_unavailable ]].
    - ['a] is the success value.

    Effet follows the Effect-TS / ZIO shape, but uses OCaml's GADTs,
    polymorphic variants, object rows, and Eio runtime primitives. *)

type ('env, 'err, 'a) t =
  | Pure : 'a -> (_, _, 'a) t
  | Fail : 'err -> (_, 'err, _) t
  | Sync : string * ('env -> 'a) -> ('env, _, 'a) t
  | Async : string * ('env -> 'a) -> ('env, _, 'a) t
  | Bind :
      ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t)
      -> ('env, 'err, 'a) t
  | Map : ('env, 'err, 'b) t * ('b -> 'a) -> ('env, 'err, 'a) t
  | Catch :
      ('env, 'err1, 'a) t * ('err1 -> ('env, 'err2, 'a) t)
      -> ('env, 'err2, 'a) t
  | Tap_error : ('env, 'err, 'a) t * ('err -> unit) -> ('env, 'err, 'a) t
  | Delay : Duration.t * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Timeout :
      Duration.t * ('env, 'err, 'a) t -> ('env, [> `Timeout ] as 'err, 'a) t
  | Concat : ('env, 'err, unit) t list -> ('env, 'err, unit) t
  | Race : ('env, 'err, 'a) t list -> ('env, 'err, 'a) t
  | Detach : ('env, _, unit) t -> ('env, 'err, unit) t
  | Uninterruptible : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Repeat : ('env, 'err, unit) t * Schedule.t -> ('env, 'err, unit) t
  | Retry :
      ('env, 'err, 'a) t * Schedule.t * ('err -> bool)
      -> ('env, 'err, 'a) t
  | Acquire_release :
      ('env, 'err, 'a) t * ('a -> ('env, _, unit) t)
      -> ('env, 'err, 'a) t
  | Scoped : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Named : string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Annotate : string * string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val pure : 'a -> ('env, 'err, 'a) t
val fail : 'err -> ('env, 'err, 'a) t
val unit : ('env, 'err, unit) t

val sync : string -> ('env -> 'a) -> ('env, 'err, 'a) t
val async : string -> ('env -> 'a) -> ('env, 'err, 'a) t

val map : ('a -> 'b) -> ('env, 'err, 'a) t -> ('env, 'err, 'b) t
val bind :
  ('a -> ('env, 'err, 'b) t) -> ('env, 'err, 'a) t -> ('env, 'err, 'b) t
val ( >>= ) :
  ('env, 'err, 'a) t -> ('a -> ('env, 'err, 'b) t) -> ('env, 'err, 'b) t

val tap :
  ('a -> ('env, 'err, unit) t) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val seq : ('env, 'err, unit) t -> ('env, 'err, unit) t -> ('env, 'err, unit) t
val concat : ('env, 'err, unit) t list -> ('env, 'err, unit) t

val race : ('env, 'err, 'a) t list -> ('env, 'err, 'a) t
(** First child to produce a value wins; the rest are cancelled. *)

val detach : ('env, _, unit) t -> ('env, 'err, unit) t
(** Start a unit effect detached from the current effect and return
    immediately. The runtime owns the detached fiber. *)

val uninterruptible : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
(** Defer parent cancellation while running the wrapped effect.

    This maps to [Eio.Cancel.protect]. It does not turn interruption
    into a typed failure, and it does not catch defects. *)

val catch :
  ('err1 -> ('env, 'err2, 'a) t) ->
  ('env, 'err1, 'a) t ->
  ('env, 'err2, 'a) t

val tap_error :
  ('err -> unit) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val retry :
  Schedule.t -> ('err -> bool) -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val delay : Duration.t -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
val timeout :
  Duration.t -> ('env, [> `Timeout ] as 'err, 'a) t -> ('env, 'err, 'a) t
val repeat : Schedule.t -> ('env, 'err, unit) t -> ('env, 'err, unit) t

val acquire_release :
  acquire:('env, 'err, 'a) t ->
  release:('a -> ('env, _, unit) t) ->
  ('env, 'err, 'a) t

val scoped : ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val named : string -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t
val annotate :
  key:string -> value:string -> ('env, 'err, 'a) t -> ('env, 'err, 'a) t

val name : ('env, 'err, 'a) t -> string option
val collect_names : ('env, 'err, 'a) t -> string list
