type ('err, 'a) stream = unit -> ('a list, 'err) result

let from_file_map_error ?chunk_size ~on_error path : ('err, bytes) stream =
 fun () ->
  match Common.read_chunks ?chunk_size path with
  | Ok chunks -> Ok chunks
  | Error error -> Error (on_error error)

type app_error = [ `Storage of Common.file_error | `Other ]

let app_file path : (app_error, bytes) stream =
  from_file_map_error ~on_error:(fun error -> `Storage error) path

module type SIG = sig
  type app_error = [ `Other | `Storage of Common.file_error ]

  val from_file_map_error :
    ?chunk_size:int ->
    on_error:(Common.file_error -> 'err) ->
    [> Eio.Fs.dir_ty ] Eio.Path.t ->
    ('err, bytes) stream

  val app_file : [> Eio.Fs.dir_ty ] Eio.Path.t -> (app_error, bytes) stream
end

module _ : SIG = struct
  type nonrec app_error = app_error

  let from_file_map_error = from_file_map_error
  let app_file = app_file
end
