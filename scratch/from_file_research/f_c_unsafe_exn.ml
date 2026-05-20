type ('err, 'a) stream = unit -> 'a list

let from_file_unsafe ?chunk_size path : ('err, bytes) stream =
 fun () ->
  match Common.read_chunks ?chunk_size path with
  | Ok chunks -> chunks
  | Error error -> raise error.cause

let cannot_recover_with_typed_error stream =
  try Ok (stream ()) with exn -> Error exn

module type SIG = sig
  val from_file_unsafe :
    ?chunk_size:int -> [> Eio.Fs.dir_ty ] Eio.Path.t -> ('err, bytes) stream

  val cannot_recover_with_typed_error : ('err, 'a) stream -> ('a list, exn) result
end

module _ : SIG = struct
  let from_file_unsafe = from_file_unsafe
  let cannot_recover_with_typed_error = cannot_recover_with_typed_error
end
