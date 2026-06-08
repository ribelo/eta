open Eta

module Fiber_scope = struct
  type ('s, 'a, 'err) fiber = ('s, 'err, 'a) Supervisor.child
  type ('s, 'a, 'err) t = ('s, 'a, 'err) Supervisor.Scope.t

  let lift = Supervisor.Scope.lift
  let pure = Supervisor.Scope.pure

  type ('child, 'a, 'err) body = {
    run : 's. ('s, 'child, 'err) fiber -> ('s, 'a, 'err) t;
  }

  let with_fiber child body =
    Supervisor.scoped
      {
        run =
          (fun sup ->
            let open Supervisor.Scope in
            let* fiber = start sup (lift child) in
            body.run fiber);
      }
end

let escaped () =
  Fiber_scope.with_fiber Effect.unit
    {
      run =
        (fun fiber ->
          let open Fiber_scope in
          pure fiber);
    }

let _ = escaped

