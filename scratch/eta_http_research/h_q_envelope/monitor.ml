type sample = {
  attack_id : string;
  second : int;
  rss_kb : int;
  live_words : int;
  minor_words_delta : float;
  major_words_delta : float;
  user_cpu_seconds_delta : float;
  system_cpu_seconds_delta : float;
  fd_count : int;
  fiber_count : int;
  stream_active : int;
  stream_cancelled : int;
  stream_live : int;
  frames_seen : int;
  dropped_frames : int;
  disconnected : bool;
  error_class : string;
}

type baseline = {
  minor_words : float;
  major_words : float;
  user_cpu_seconds : float;
  system_cpu_seconds : float;
}

let fd_count () =
  try Array.length (Sys.readdir "/proc/self/fd") with _ -> 0

let rss_kb () =
  try
    let ic = open_in "/proc/self/status" in
    let rec loop () =
      match input_line ic with
      | line ->
          if String.starts_with ~prefix:"VmRSS:" line then (
            close_in_noerr ic;
            match String.split_on_char ' ' line |> List.filter (( <> ) "") with
            | _ :: value :: _ -> int_of_string value
            | _ -> 0)
          else loop ()
      | exception End_of_file ->
          close_in_noerr ic;
          0
    in
    loop ()
  with _ -> 0

let baseline () =
  let gc = Gc.quick_stat () in
  let cpu = Unix.times () in
  {
    minor_words = gc.Gc.minor_words;
    major_words = gc.Gc.major_words;
    user_cpu_seconds = cpu.Unix.tms_utime;
    system_cpu_seconds = cpu.Unix.tms_stime;
  }

let csv_header =
  "attack_id,second,rss_kb,live_words,minor_words_delta,major_words_delta,user_cpu_seconds_delta,system_cpu_seconds_delta,fd_count,fiber_count,stream_active,stream_cancelled,stream_live,frames_seen,dropped_frames,disconnected,error_class"

let csv_row s =
  Printf.sprintf
    "%s,%d,%d,%d,%.0f,%.0f,%.6f,%.6f,%d,%d,%d,%d,%d,%d,%d,%b,%s"
    s.attack_id s.second s.rss_kb s.live_words s.minor_words_delta
    s.major_words_delta s.user_cpu_seconds_delta s.system_cpu_seconds_delta
    s.fd_count s.fiber_count s.stream_active s.stream_cancelled s.stream_live
    s.frames_seen s.dropped_frames s.disconnected s.error_class

let write_csv path samples =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc (csv_header ^ "\n");
      List.iter
        (fun sample -> output_string oc (csv_row sample ^ "\n"))
        samples)

let plateau_int ?(tail = 10) ?(tolerance = 0) values =
  let rec take n acc = function
    | _ when n = 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> take (n - 1) (x :: acc) xs
  in
  let tail_values = values |> List.rev |> take tail [] in
  match tail_values with
  | [] -> true
  | x :: xs ->
      let min_v, max_v =
        List.fold_left (fun (lo, hi) v -> (min lo v, max hi v)) (x, x) xs
      in
      max_v - min_v <= tolerance

let max_float_delta values =
  match values with
  | [] -> 0.0
  | x :: xs ->
      let lo, hi =
        List.fold_left (fun (lo, hi) v -> (min lo v, max hi v)) (x, x) xs
      in
      hi -. lo
