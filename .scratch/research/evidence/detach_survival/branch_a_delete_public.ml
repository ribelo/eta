(* Branch A: delete public detach.

   With Effet's current public-GADT style, an internal daemon node cannot be
   hidden while [Effect.t] remains an exact public variant. The viable shape is
   to make the effect type abstract and expose constructors through smart
   constructors, with daemon/fork kept in a Private module. That is a broad API
   shift, not a surgical detach deletion. *)

module Abstract_effect : sig
  type ('env, 'err, 'a) t

  val pure : 'a -> ('env, 'err, 'a) t
  val bind :
    ('a -> ('env, 'err, 'b) t) -> ('env, 'err, 'a) t -> ('env, 'err, 'b) t

  module Private : sig
    val daemon : ('env, 'err, unit) t -> ('env, 'err, unit) t
  end
end = struct
  type ('env, 'err, 'a) t =
    | Pure : 'a -> (_, _, 'a) t
    | Bind :
        ('env, 'err, 'a) t * ('a -> ('env, 'err, 'b) t)
        -> ('env, 'err, 'b) t
    | Daemon : ('env, 'err, unit) t -> ('env, 'err, unit) t

  let pure value = Pure value
  let bind k eff = Bind (eff, k)

  module Private = struct
    let daemon eff = Daemon eff
  end
end

module Resource_shape = struct
  type ('env, 'err, 'a) resource = {
    load : ('env, 'err, 'a) Abstract_effect.t;
    failures : 'err list ref;
  }

  let auto load =
    Abstract_effect.bind
      (fun resource ->
        Abstract_effect.Private.daemon
          (Abstract_effect.bind
             (fun _ -> Abstract_effect.pure ())
             resource.load)
        |> Abstract_effect.bind (fun () -> Abstract_effect.pure resource))
      (Abstract_effect.pure { load; failures = ref [] })
end

module type BRANCH_A_SIG = sig
  val resource :
    (unit, [ `Refresh_failed ],
     (unit, [ `Refresh_failed ], int) Resource_shape.resource)
    Abstract_effect.t
end

module _ : BRANCH_A_SIG = struct
  let load : (unit, [ `Refresh_failed ], int) Abstract_effect.t =
    Abstract_effect.pure 1

  let resource = Resource_shape.auto load
end

let abstract_effect_with_private_daemon_compiles () = true
