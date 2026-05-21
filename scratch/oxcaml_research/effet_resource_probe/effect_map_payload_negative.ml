open! Portable

module P_atomic = Portable.Atomic

type ('env, 'err, 'a) effect = Effect

let map (_f : 'a -> 'b) (_effect : ('env, 'err, 'a) effect) = Effect

type ('env, 'err : immutable_data, 'a : immutable_data) resource = {
  load : ('env, 'err, 'a) effect;
  value : 'a option P_atomic.t;
}

let manual load =
  map
    (fun value ->
      {
        load;
        value = P_atomic.make (Some value);
      })
    load
