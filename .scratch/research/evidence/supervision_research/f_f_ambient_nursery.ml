(* F-F: ambient nursery.

   The nursery is not passed as an argument to every operation; it is installed
   by [with_nursery] and accessed by [start]. The effect type still carries the
   phantom scope tag, otherwise child handles can escape. This makes the API
   slightly lighter than F-D, but does not remove the rank-2 machinery. *)

module Nursery = struct
  type 'err cause = Fail of 'err | Interrupt

  type ('env, 'err, 'a) t =
    | With_nursery : ('env, 'err, 'a) body -> ('env, 'err, 'a) t

  and ('s, 'env, 'err, 'a) scoped_t =
    | Pure : 'a -> (_, _, _, 'a) scoped_t
    | Bind :
        ('s, 'env, 'err, 'b) scoped_t *
        ('b -> ('s, 'env, 'err, 'a) scoped_t)
        -> ('s, 'env, 'err, 'a) scoped_t
    | Fail : 'err -> (_, _, 'err, _) scoped_t
    | Start :
        ('s, 'env, 'err, 'a) scoped_t
        -> ('s, 'env, _, ('s, 'err, 'a) child) scoped_t
    | Await : ('s, 'err, 'a) child -> ('s, _, 'err, 'a) scoped_t

  and ('env, 'err, 'a) body = {
    run : 's. unit -> ('s, 'env, 'err, 'a) scoped_t;
  }

  and ('s, 'err, 'a) child = {
    result : ('a, 'err cause) result;
  }

  let with_nursery body = With_nursery body
  let pure value = Pure value
  let fail err = Fail err
  let bind k e = Bind (e, k)
  let ( let* ) e k = Bind (e, k)
  let start e = Start e
  let await child = Await child

  let rec interpret_scoped : type s env err a.
      (s, env, err, a) scoped_t -> (a, err cause) result = function
    | Pure value -> Ok value
    | Fail err -> Error (Fail err)
    | Bind (e, k) -> (
        match interpret_scoped e with
        | Error cause -> Error cause
        | Ok value -> interpret_scoped (k value))
    | Start child -> Ok { result = interpret_scoped child }
    | Await child -> child.result

  let run ~env:_ (With_nursery body) = interpret_scoped (body.run ())
end

module type AMBIENT_SIG = sig
  val await_child : unit -> (unit, ([> `Boom ] as 'err), int) Nursery.t
end

let await_child : unit -> (unit, [> `Boom ], int) Nursery.t =
 fun () ->
  let open Nursery in
  with_nursery {
    run = fun (type s) () ->
      let* (child : (s, [> `Boom ], int) child) = start (pure 5) in
      await child
  }

module _ : AMBIENT_SIG = struct
  let await_child = await_child
end
