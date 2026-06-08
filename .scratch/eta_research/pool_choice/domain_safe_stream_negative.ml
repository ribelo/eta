let stream = Eio.Stream.create 8

let () =
  Eio.Stream.add stream 1;
  let domain =
    Domain.Safe.spawn (fun () -> ignore (Eio.Stream.take_nonblocking stream))
  in
  Domain.join domain
