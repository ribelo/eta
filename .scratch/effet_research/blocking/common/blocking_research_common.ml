type latency = {
  samples : int;
  p50_us : int;
  p95_us : int;
  p99_us : int;
  max_us : int;
}

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)
let now_ms () = now_us () / 1_000

let percentile sorted pct =
  match sorted with
  | [] -> 0
  | _ ->
      let len = List.length sorted in
      let idx =
        float_of_int (len - 1) *. pct |> int_of_float |> min (len - 1) |> max 0
      in
      List.nth sorted idx

let summarize samples =
  let sorted = List.sort compare samples in
  {
    samples = List.length sorted;
    p50_us = percentile sorted 0.50;
    p95_us = percentile sorted 0.95;
    p99_us = percentile sorted 0.99;
    max_us = (match List.rev sorted with [] -> 0 | x :: _ -> x);
  }

let with_heartbeat ?(interval_s = 0.001) body =
  let running = ref true in
  let samples = ref [] in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
      let target = ref (now_us () + int_of_float (interval_s *. 1_000_000.0)) in
      while !running do
        Eio_unix.sleep interval_s;
        let actual = now_us () in
        samples := max 0 (actual - !target) :: !samples;
        target := actual + int_of_float (interval_s *. 1_000_000.0)
      done);
  Eio.Fiber.yield ();
  let started = now_us () in
  let result =
    try Ok (body ())
    with exn ->
      let bt = Printexc.get_raw_backtrace () in
      Error (exn, bt)
  in
  let ended_ = now_us () in
  running := false;
  Eio.Fiber.yield ();
  (result, summarize !samples, ended_ - started)

let run_eio f = Eio_main.run @@ fun _stdenv -> f ()

let read_status_value prefix =
  try
    let ic = open_in "/proc/self/status" in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rec loop () =
          match input_line ic with
          | line ->
              if String.length line >= String.length prefix
                 && String.sub line 0 (String.length prefix) = prefix
              then
                let value =
                  String.sub line (String.length prefix)
                    (String.length line - String.length prefix)
                  |> String.trim
                in
                let digits =
                  value
                  |> String.to_seq
                  |> Seq.take_while (function '0' .. '9' -> true | _ -> false)
                  |> String.of_seq
                in
                Some (int_of_string (if digits = "" then "0" else digits))
              else loop ()
          | exception End_of_file -> None
        in
        loop ())
  with _ -> None

let thread_count () = read_status_value "Threads:"
let rss_kb () = read_status_value "VmRSS:"

let print_summary name fields =
  let fields =
    ("probe", name)
    :: List.map (fun (k, v) -> (k, v)) fields
  in
  fields
  |> List.map (fun (k, v) -> k ^ "=" ^ v)
  |> String.concat " "
  |> print_endline

let latency_fields prefix latency =
  [
    (prefix ^ "_samples", string_of_int latency.samples);
    (prefix ^ "_p50_us", string_of_int latency.p50_us);
    (prefix ^ "_p95_us", string_of_int latency.p95_us);
    (prefix ^ "_p99_us", string_of_int latency.p99_us);
    (prefix ^ "_max_us", string_of_int latency.max_us);
  ]

let us_to_ms us = float_of_int us /. 1000.0

let sleep_blocking seconds = Unix.sleepf seconds

let cpu_burn iterations =
  let acc = ref 0x12345 in
  for i = 1 to iterations do
    acc := ((!acc lxor (i * 1103515245)) + 12345) land 0x3fffffff
  done;
  !acc

let run_many ~sw count f =
  List.init count (fun i -> Eio.Fiber.fork_promise ~sw (fun () -> f i))
  |> List.map Eio.Promise.await_exn

let mean ints =
  match ints with
  | [] -> 0.0
  | xs ->
      float_of_int (List.fold_left ( + ) 0 xs) /. float_of_int (List.length xs)

let min_opt = function [] -> None | xs -> Some (List.fold_left min max_int xs)
let max_opt = function [] -> None | xs -> Some (List.fold_left max min_int xs)
