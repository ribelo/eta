open Ppxlib

let loc = Location.none

let () =
  let open Ast_builder.Default in
  let expr =
    pexp_fun ~loc Nolabel None (pvar ~loc "env") (evar ~loc "env")
  in
  match expr.pexp_desc with
  | Pexp_function (params, _, _) ->
      if List.length params <> 1 then failwith "unexpected helper shape"
  | _ -> failwith "expected function expression"

