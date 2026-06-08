open! Portable

type env : immutable_data = { input : int }
type error : immutable_data = { message : string }

module Effect = struct
  type ('env : value mod portable contended, 'err : value mod portable, 'a : value mod portable) t =
    | Thunk : string * ('env -> 'a) @@ portable -> ('env, 'err, 'a) t
end

let build () =
  let counter = ref 0 in
  let program : (env, error, int) Effect.t =
    Effect.Thunk
      ( "bad-ref-capture",
        fun env ->
          incr counter;
          env.input + !counter )
  in
  ignore program

let () = build ()

