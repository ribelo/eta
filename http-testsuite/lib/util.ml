(** Shared utilities. *)

let ( let* ) = Result.bind
let quote = Filename.quote

let run_cmd ?(env = []) cmd =
  let full = String.concat " " (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v)) env @ [ cmd ]) in
  match Sys.command full with
  | 0 -> Ok ()
  | code -> Error (Printf.sprintf "command failed code=%d cmd=%s" code full)

let run_cmd_out ?(env = []) cmd =
  let full = String.concat " " (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k (quote v)) env @ [ cmd ]) in
  let ic = Unix.open_process_in full in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let rec loop acc =
         match input_line ic with
         | line -> loop (line :: acc)
         | exception End_of_file -> List.rev acc
       in
       let lines = loop [] in
       match Unix.close_process_in ic with
       | WEXITED 0 -> Ok lines
       | WEXITED code ->
           Error
             (Printf.sprintf "exit %d: %s\n%s" code cmd
                (String.concat "\n" lines))
       | WSIGNALED n ->
           Error
             (Printf.sprintf "signal %d: %s\n%s" n cmd
                (String.concat "\n" lines))
       | WSTOPPED n ->
           Error
             (Printf.sprintf "stopped %d: %s\n%s" n cmd
                (String.concat "\n" lines)))

let write_file path contents =
  let out = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr out)
    (fun () -> output_string out contents)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)

let mkdir_p path =
  ignore (Sys.command ("mkdir -p " ^ quote path))

let absolute_path path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

let sha256_of_string = Sha256.hex

let sha256_of_file path =
  read_file path |> sha256_of_string

let body_to_string stream =
  Eta_http.Body.Stream.read_all stream
  |> Eta.Effect.map Bytes.unsafe_to_string

let now_ms () =
  Unix.gettimeofday () *. 1000.0

let gc_stat () =
  let s = Gc.quick_stat () in
  (s.Gc.minor_words, s.Gc.major_words, s.Gc.promoted_words, s.Gc.top_heap_words)

let rss_kb () =
  try
    let ic = open_in "/proc/self/status" in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let rec loop () =
           match input_line ic with
           | line when String.starts_with ~prefix:"VmRSS:" line ->
               (match String.split_on_char ' ' line |> List.filter (( <> ) "") with
                | _ :: value :: _ -> int_of_string value
                | _ -> 0)
           | _ -> loop ()
           | exception End_of_file -> 0
         in
         loop ())
  with _ -> 0

let fd_count () =
  try Array.length (Sys.readdir "/proc/self/fd") with _ -> 0

let version_of_cmd cmd =
  match run_cmd_out cmd with
  | Ok (line :: _) ->
      (match String.split_on_char ' ' line with
       | _ :: ver :: _ -> String.trim ver
       | _ -> String.trim line)
  | _ -> "unknown"

let hostname () =
  match run_cmd_out "hostname" with
  | Ok (h :: _) -> String.trim h
  | _ -> "unknown"

let utc_timestamp () =
  let now = Unix.gettimeofday () in
  let tm = Unix.gmtime now in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let git_sha () =
  match run_cmd_out "git rev-parse --short HEAD" with
  | Ok (sha :: _) -> String.trim sha
  | _ -> "unknown"

let random_port () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close s)
    (fun () ->
       Unix.setsockopt s Unix.SO_REUSEADDR true;
       Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
       match Unix.getsockname s with
       | Unix.ADDR_INET (_, port) -> port
       | _ -> failwith "unexpected socket address")
