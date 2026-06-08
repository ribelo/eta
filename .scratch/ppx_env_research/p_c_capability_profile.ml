open Effet
open Services

module Auth_cap = struct
  class type has_auth = object
    method auth : Auth.t
  end

  let get (env : #has_auth) = env#auth

  let sync name f =
    Effect.sync name (fun env -> f (get env))
end

module Log_cap = struct
  class type has_log = object
    method log : Log.t
  end

  let get (env : #has_log) = env#log
end

let current_user () =
  Auth_cap.sync "auth.current_user" Auth.current_user

let run () =
  let env =
    object
      method auth = auth "alice"
    end
  in
  run env (current_user ())

