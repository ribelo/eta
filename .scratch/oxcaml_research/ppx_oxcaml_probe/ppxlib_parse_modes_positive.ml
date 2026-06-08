open Ppxlib

let parse source =
  Parse.implementation (Lexing.from_string source)

let mode_count = function
  | [
      {
        pstr_desc =
          Pstr_value
            ( _,
              [
                {
                  pvb_modes;
                  _;
                };
              ] );
        _;
      };
    ] ->
      List.length pvb_modes
  | _ -> failwith "unexpected parsed structure"

let () =
  let ast = parse "let (thunk @ portable) env = env\n" in
  if mode_count ast = 0 then failwith "ppxlib parsed no value-binding modes"

