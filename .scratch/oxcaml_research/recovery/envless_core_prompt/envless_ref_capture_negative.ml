open! Portable

type error : immutable_data = Rejected of string

module Effect = struct
  type ('err : immutable_data, 'a : immutable_data) t =
    | Thunk : string * (unit -> 'a) @@ portable -> ('err, 'a) t
end

let build () =
  let counter = ref 0 in
  let program : (error, int) Effect.t =
    Effect.Thunk
      ( "bad-ref-capture",
        fun () ->
          incr counter;
          !counter )
  in
  ignore program

let () = build ()
