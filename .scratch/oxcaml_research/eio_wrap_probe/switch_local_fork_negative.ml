module Switch_local = struct
  type t = Eio.Switch.t

  let run (body : t @ local -> 'a) =
    Eio.Switch.run (fun sw -> body sw)
end

module Fiber_local = struct
  let fork (sw : Switch_local.t @ local) body =
    Eio.Fiber.fork ~sw body
end

let bad () =
  Eio_main.run @@ fun _env ->
  Switch_local.run (fun sw ->
    Fiber_local.fork sw (fun () -> ()))

let () = bad ()

