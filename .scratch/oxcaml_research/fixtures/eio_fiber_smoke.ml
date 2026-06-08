let main () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let promise, resolve = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () -> Eio.Promise.resolve resolve 41);
  match Eio.Promise.await promise with
  | 41 -> ()
  | n -> failwith (Printf.sprintf "unexpected promise result: %d" n)

let () = main ()

