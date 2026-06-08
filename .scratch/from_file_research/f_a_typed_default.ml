type file_error = Common.file_error

type ('err, 'a) stream = unit -> ('a list, 'err) result

let from_file ?chunk_size path : ([> `File_error of file_error ], bytes) stream =
 fun () ->
  match Common.read_chunks ?chunk_size path with
  | Ok chunks -> Ok chunks
  | Error error -> Error (`File_error error)

let recover_missing stream =
  match stream () with
  | Ok chunks -> chunks
  | Error (`File_error { Common.kind = `Not_found; _ }) -> []
  | Error (`File_error error) -> failwith error.message

module type SIG = sig
  val from_file :
    ?chunk_size:int ->
    [> Eio.Fs.dir_ty ] Eio.Path.t ->
    ([> `File_error of file_error ], bytes) stream

  val recover_missing :
    ([< `File_error of file_error ], bytes) stream -> bytes list
end

module _ : SIG = struct
  let from_file = from_file
  let recover_missing = recover_missing
end
