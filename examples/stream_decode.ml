open Eta

type error = [ `Decode_failed of string ] [@@deriving eta_error]

let decode = function
  | "" -> Error (`Decode_failed "empty chunk")
  | value -> Ok (String.uppercase_ascii value)

let program =
  Eta_stream.Stream.from_iterable [ "alpha"; "beta"; "gamma" ]
  |> Eta_stream.Stream.map_effect (fun raw ->
         [%eta.result "stream.decode" (decode raw)])
  |> Eta_stream.run_collect

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt program with
  | Exit.Ok values -> Format.printf "stream:%s@." (String.concat "," values)
  | Exit.Error cause ->
      Format.eprintf "stream failed: %a@." (Cause.pp pp_error) cause;
      exit 1
