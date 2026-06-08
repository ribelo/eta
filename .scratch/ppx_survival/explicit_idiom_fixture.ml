open Effet

module Clock = struct
  type t = { now_ms : unit -> int }
end

module Log = struct
  type t = { info : string -> unit }
end

let pos = __POS__

let current_time () =
  Effect.fn pos __FUNCTION__
    (Effect.thunk "fixture.current_time" (fun env -> env#clock.Clock.now_ms ()))

let log_message msg =
  Effect.fn pos __FUNCTION__
    (Effect.thunk "fixture.log_message" (fun env -> env#log.Log.info msg))

let pure_user id = Effect.fn pos __FUNCTION__ (Effect.pure ("user-" ^ id))
let fail_user id = Effect.fn pos __FUNCTION__ (Effect.fail (`No_user id))
let delayed value = Effect.fn pos __FUNCTION__ (Effect.pure value)
let mapped value = Effect.fn pos __FUNCTION__ (Effect.map succ (Effect.pure value))
let bound value = Effect.fn pos __FUNCTION__ (Effect.bind (fun x -> Effect.pure (x + 1)) (Effect.pure value))
let caught () = Effect.fn pos __FUNCTION__ (Effect.catch (fun `Boom -> Effect.pure 0) (Effect.fail `Boom))
let annotated () = Effect.fn pos __FUNCTION__ (Effect.annotate ~key:"k" ~value:"v" (Effect.pure ()))
let logged () = Effect.fn pos __FUNCTION__ (Effect.log "hello")
let metric () =
  Effect.fn pos __FUNCTION__
    (Effect.metric_update ~name:"m" ~kind:Counter_monotonic (Int 1))
let pair a b = Effect.fn pos __FUNCTION__ (Effect.par (Effect.pure a) (Effect.pure b))
let all xs = Effect.fn pos __FUNCTION__ (Effect.all (List.map Effect.pure xs))
let race xs = Effect.fn pos __FUNCTION__ (Effect.race (List.map Effect.pure xs))
let local_module () =
  let module Local = struct
    let value = 1
  end in
  Effect.fn pos __FUNCTION__ (Effect.pure Local.value)

let local_function n =
  let inner x = Effect.fn pos __FUNCTION__ (Effect.pure (x + n)) in
  inner 1

let lambda_mapper xs =
  Effect.fn pos __FUNCTION__
    (Effect.pure (List.map (fun x -> x + 1) xs))

let partial_application prefix =
  let add_prefix x = prefix ^ x in
  Effect.fn pos __FUNCTION__ (Effect.pure (add_prefix "x"))

let scoped resource =
  Effect.fn pos __FUNCTION__
    (Effect.acquire_release ~acquire:(Effect.pure resource) ~release:(fun _ -> Effect.unit))

let supervisor () =
  Effect.fn pos __FUNCTION__
    (Effect.supervisor_scoped
       { run = (fun supervisor -> Effect.supervisor_failures supervisor) })

let current_span () = Effect.fn pos __FUNCTION__ Effect.current_span
let current_context () = Effect.fn pos __FUNCTION__ Effect.current_context
