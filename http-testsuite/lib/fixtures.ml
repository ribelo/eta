(** Static fixture generation for server tests. *)

let write_file path contents =
  let out = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr out)
    (fun () -> output_string out contents)

let generate ~dir =
  Util.mkdir_p dir;
  write_file (Filename.concat dir "empty.txt") "";
  write_file (Filename.concat dir "1k.bin") (String.make 1024 'x');
  write_file (Filename.concat dir "1m.bin") (String.make (1024 * 1024) 'x');
  let path_100m = Filename.concat dir "100m.bin" in
  if not (Sys.file_exists path_100m) then
    ignore
      (Sys.command
         (Printf.sprintf "dd if=/dev/zero of=%s bs=1M count=100 status=none"
            (Filename.quote path_100m)));
  dir

let path dir name = Filename.concat dir name
