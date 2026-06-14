(* Ad-hoc memtrace CTF analyzer for autoresearch: aggregates sampled allocation
   words by the top (allocation-site) backtrace frame and prints the hottest
   sites. Usage: mtop.exe TRACE.ctf [N]. Temporary tool; not part of the suite. *)

module Trace = Memtrace.Trace

let () =
  let file = Sys.argv.(1) in
  let topn = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 30 in
  let r = Trace.Reader.open_ ~filename:file in
  let by_site : (string, int * int) Hashtbl.t = Hashtbl.create 4096 in
  let total = ref 0 in
  Trace.Reader.iter r ~parse_backtraces:true (fun _t ev ->
      match ev with
      | Trace.Event.Alloc a ->
          let words = a.length in
          total := !total + words;
          (* Innermost frame = allocation site. backtrace_buffer is stored
             outermost-first, so walk from the end (backtrace_length-1) inward
             and pick the first frame that resolves to a source location. *)
          let site = ref "<unknown>" in
          (try
             for i = a.backtrace_length - 1 downto 0 do
               let locs = Trace.Reader.lookup_location_code r a.backtrace_buffer.(i) in
               match locs with
               | loc :: _ ->
                   site := Trace.Location.to_string loc;
                   raise Exit
               | [] -> ()
             done
           with Exit -> ());
          let (w, c) = try Hashtbl.find by_site !site with Not_found -> (0, 0) in
          Hashtbl.replace by_site !site (w + words, c + 1)
      | _ -> ());
  let rows =
    Hashtbl.fold (fun site (w, c) acc -> (site, w, c) :: acc) by_site []
    |> List.sort (fun (_, a, _) (_, b, _) -> compare b a)
  in
  Printf.printf "total sampled alloc words: %d\n" !total;
  Printf.printf "%-10s %-8s  %s\n" "words" "count" "site";
  let rec take n = function
    | [] -> ()
    | _ when n = 0 -> ()
    | (site, w, c) :: tl ->
        let pct = 100.0 *. float_of_int w /. float_of_int (max 1 !total) in
        Printf.printf "%-10d %-8d %5.1f%%  %s\n" w c pct site;
        take (n - 1) tl
  in
  take topn rows
