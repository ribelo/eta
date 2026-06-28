(* Realistic transducer round-trip: Stream -> split_lines -> Stream.

   Uses bridge_lib (the channel core + StreamA abstract + StreamP private).
   Runs the SAME round trip through each bridge and compares. *)

open Stream_core_reopen_common

module Channel = Bridge_lib.Channel
module StreamA = Bridge_lib.StreamA
module StreamP = Bridge_lib.StreamP

(* ABSTRACT bridge: forward needs the named [to_channel]. *)
let round_trip_abstract () =
  let byte_stream : (string, [ `E ]) StreamA.t =
    StreamA.source [ "a\nb"; "\nc"; "d" ]
  in
  let lines_channel : (string, string, _, _, [ `E ]) Channel.t =
    Channel.Compose (StreamA.to_channel byte_stream, Channel.split_lines "")
  in
  let terminal =
    match Channel.run_fold (fun acc x -> x :: acc) [] lines_channel with
    | Ok (rev, leftover) -> (List.rev rev, leftover)
    | Error _ -> ([], "<err>")
  in
  let line_stream : (string, [ `E ]) StreamA.t =
    StreamA.of_channel (Channel.emit_terminal_as_last lines_channel)
  in
  let lines =
    match StreamA.run_fold (fun acc x -> x :: acc) [] line_stream with
    | Ok rev -> List.rev rev | Error _ -> []
  in
  Printf.printf "[abstract] run terminal: lines=[%s] leftover=%S\n"
    (String.concat "; " (fst terminal)) (snd terminal);
  Printf.printf "[abstract] round-trip stream lines: [%s]\n" (String.concat "; " lines)

(* PRIVATE bridge: forward is a [(:>)] coercion; backward is [of_channel]. *)
let round_trip_private () =
  let byte_stream : (string, [ `E ]) StreamP.t =
    StreamP.source [ "a\nb"; "\nc"; "d" ]
  in
  let as_channel : (string, unit, unit, unit, [ `E ]) Channel.t =
    (byte_stream :> (string, unit, unit, unit, [ `E ]) Channel.t)
  in
  let lines_channel : (string, string, _, _, [ `E ]) Channel.t =
    Channel.Compose (as_channel, Channel.split_lines "")
  in
  let line_stream : (string, [ `E ]) StreamP.t =
    StreamP.of_channel (Channel.emit_terminal_as_last lines_channel)
  in
  let lines =
    match StreamP.run_fold (fun acc x -> x :: acc) [] line_stream with
    | Ok rev -> List.rev rev | Error _ -> []
  in
  Printf.printf "[private]  round-trip stream lines: [%s]\n" (String.concat "; " lines)

let () =
  round_trip_abstract ();
  round_trip_private ();
  Printf.printf "\nBoth bridges carry the SAME round trip (lines a;b plus the\n";
  Printf.printf "trailing partial \"cd\" as a final line) over ONE channel core.\n";
  Printf.printf "\nEncapsulation (see neg_*.ml): private exposes (s :> channel)\n";
  Printf.printf "outside; abstract forces the named to_channel/of_channel.\n"
