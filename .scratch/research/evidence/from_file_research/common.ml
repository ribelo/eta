type file_operation = [ `Open | `Read | `Close ]

type file_error_kind =
  [ `Already_exists
  | `File_too_large
  | `Io
  | `Not_found
  | `Not_native
  | `Permission_denied
  | `Unexpected ]

type file_error = {
  operation : file_operation;
  path : string;
  kind : file_error_kind;
  message : string;
  cause : exn;
}

let kind_of_exn = function
  | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) -> `Already_exists
  | Eio.Io (Eio.Fs.E Eio.Fs.File_too_large, _) -> `File_too_large
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> `Not_found
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_native _), _) -> `Not_native
  | Eio.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _) -> `Permission_denied
  | Eio.Io _ -> `Io
  | _ -> `Unexpected

let make_file_error ~operation ~path cause =
  {
    operation;
    path;
    kind = kind_of_exn cause;
    message = Format.asprintf "%a" Eio.Exn.pp cause;
    cause;
  }

let read_chunks ?(chunk_size = 4) path =
  if chunk_size <= 0 then invalid_arg "chunk_size must be > 0";
  let path_label = Format.asprintf "%a" Eio.Path.pp path in
  let operation = ref `Open in
  try
    let chunks =
      Eio.Switch.run ~name:"from_file_research" @@ fun sw ->
      let flow = Eio.Path.open_in ~sw path in
      operation := `Read;
      let buffer = Cstruct.create chunk_size in
      let rec loop acc =
        match Eio.Flow.single_read flow buffer with
        | n ->
            let chunk = Cstruct.to_bytes (Cstruct.sub buffer 0 n) in
            loop (chunk :: acc)
        | exception End_of_file ->
            operation := `Close;
            List.rev acc
      in
      loop []
    in
    Ok chunks
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (make_file_error ~operation:!operation ~path:path_label exn)
