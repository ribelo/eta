type ('s, 'err) t = ('s, 'err) Effect.supervisor
type ('s, 'err) supervisor = ('s, 'err) t
type ('s, 'err, 'a) child = ('s, 'err, 'a) Effect.supervisor_child

module Scope = struct
  type ('s, 'a, 'err) t = ('s, 'a, 'err) Effect.supervisor_scope

  let pure = Effect_erasure.supervisor_pure
  let lift = Effect_erasure.supervisor_lift
  let fail = Effect_erasure.supervisor_fail
  let bind = Effect_erasure.supervisor_bind
  let ( let* ) e (k) = bind k e
  let start = Effect_erasure.supervisor_start
  let await = Effect_erasure.supervisor_await
  let cancel = Effect_erasure.supervisor_cancel
  let request_cancel = Effect_erasure.supervisor_request_cancel
  let failures = Effect_erasure.supervisor_failures
  let check = Effect_erasure.supervisor_check
  let yield = Effect.supervisor_yield
end

type ('a, 'err) body = {
  run : 's. ('s, 'err) t -> ('s, 'a, 'err) Scope.t;
}

let scoped ?max_failures body =
  Effect.supervisor_scoped ?max_failures
    { run = (fun supervisor -> body.run supervisor) }
