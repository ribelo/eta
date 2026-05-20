type ('err, 'a) stream = unit -> ('a list, 'err) result

let from_flow ?(chunk_size = 4) ~on_read_error flow : ('err, bytes) stream =
 fun () ->
  if chunk_size <= 0 then invalid_arg "chunk_size must be > 0";
  let buffer = Cstruct.create chunk_size in
  let rec loop acc =
    match Eio.Flow.single_read flow buffer with
    | n ->
        let chunk = Cstruct.to_bytes (Cstruct.sub buffer 0 n) in
        loop (chunk :: acc)
    | exception End_of_file -> Ok (List.rev acc)
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn -> Error (on_read_error exn)
  in
  loop []

module type SIG = sig
  val from_flow :
    ?chunk_size:int ->
    on_read_error:(exn -> 'err) ->
    _ Eio.Flow.source ->
    ('err, bytes) stream
end

module _ : SIG = struct
  let from_flow = from_flow
end
