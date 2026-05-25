(* Benchmark body stream reading overhead *)

open Eta

let make_stream ~chunk_size ~chunk_count =
  let remaining = ref chunk_count in
  let read_next () =
    if !remaining = 0 then Effect.pure Eta_http_body.Stream.End
    else (
      decr remaining;
      let chunk = Bytes.create chunk_size in
      Effect.pure (Eta_http_body.Stream.Chunk chunk))
  in
  Eta_http_body.Stream.of_reader read_next

let body_length stream =
  let rec loop total =
    Eta_http_body.Stream.read stream
    |> Effect.bind (function
         | None -> Effect.pure total
         | Some chunk -> loop (total + Bytes.length chunk))
  in
  loop 0

let timeit f =
  let t0 = Unix.gettimeofday () in
  let result = f () in
  let t1 = Unix.gettimeofday () in
  (result, (t1 -. t0) *. 1000.0)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run (fun sw ->
    let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
    let chunk_size = 16 * 1024 in
    let chunk_count = 64 in
    let stream = make_stream ~chunk_size ~chunk_count in
    let len, ms =
      timeit (fun () ->
        Eta.Runtime.run rt (body_length stream)
        |> function Eta.Exit.Ok n -> n | _ -> 0)
    in
    Printf.printf "body_length: %d bytes in %.3f ms (%.3f ms per chunk)\n%!"
      len ms (ms /. float chunk_count))
