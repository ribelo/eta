open! Portable

module Stream_portable = struct
  type 'a t = { raw : 'a Eio.Stream.t }

  let create capacity =
    { raw = Eio.Stream.create capacity }

  let add t (item : 'a @ portable) =
    Eio.Stream.add t.raw item
end

let bad () =
  Eio_main.run @@ fun _env ->
  let counter = ref 0 in
  let stream = Stream_portable.create 1 in
  Stream_portable.add stream (fun () -> !counter)

let () = bad ()

