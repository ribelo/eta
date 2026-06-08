(* F-G: detach-only baseline.

   This mirrors the current Effect.detach pressure point: detached work has no
   typed sink. The only observable channel is a side-effecting callback. *)

module Detach_only = struct
  type 'err cause = Fail of 'err | Die of string | Interrupt

  type ('err, 'a) t =
    | Pure : 'a -> (_, 'a) t
    | Fail : 'err -> ('err, _) t
    | Bind : ('err, 'b) t * ('b -> ('err, 'a) t) -> ('err, 'a) t
    | Detach : ('err, unit) t * ('err -> unit) option -> (_, unit) t

  let pure value = Pure value
  let fail err = Fail err
  let bind k e = Bind (e, k)
  let ( let* ) e k = Bind (e, k)
  let detach ?on_error e = Detach (e, on_error)

  let rec run : type err a. (err, a) t -> (a, err cause) result = function
    | Pure value -> Ok value
    | Fail err -> Error (Fail err)
    | Bind (e, k) -> (
        match run e with
        | Error cause -> Error cause
        | Ok value -> run (k value))
    | Detach (e, on_error) ->
        (match run e with
         | Ok () -> ()
         | Error (Fail err) -> Option.iter (fun f -> f err) on_error
         | Error _ -> ());
        Ok ()
end

module type DETACH_SIG = sig
  val swallowed_without_callback : (unit, [> `Boom ] Detach_only.cause) result
  val side_channel_callback : int
end

let swallowed_without_callback =
  let open Detach_only in
  run (detach (fail `Boom))

let side_channel_callback =
  let open Detach_only in
  let seen = ref 0 in
  let _ = run (detach ~on_error:(fun `Boom -> incr seen) (fail `Boom)) in
  !seen

module _ : DETACH_SIG = struct
  let swallowed_without_callback = swallowed_without_callback
  let side_channel_callback = side_channel_callback
end
