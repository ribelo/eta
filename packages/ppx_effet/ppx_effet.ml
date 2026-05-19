open Ppxlib

let expand_fn ~ctxt body =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  pexp_apply ~loc
    (pexp_ident ~loc
       (Located.mk ~loc
          (Longident.Ldot (Longident.Ldot (Lident "Effet", "Effect"), "fn"))))
    [
      (Nolabel, evar ~loc "__POS__");
      (Nolabel, evar ~loc "__FUNCTION__");
      (Nolabel, body);
    ]

let fn_extension =
  Extension.V3.declare "effet.fn" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    expand_fn

let () =
  Driver.register_transformation "ppx_effet"
    ~rules:[ Context_free.Rule.extension fn_extension ]
