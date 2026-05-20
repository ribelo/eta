open Ppxlib

let effet_effect_ident ~loc name =
  let open Ast_builder.Default in
  pexp_ident ~loc
    (Located.mk ~loc
       (Longident.Ldot (Longident.Ldot (Lident "Effet", "Effect"), name)))

let expand_fn ~ctxt body =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  pexp_apply ~loc (effet_effect_ident ~loc "fn")
    [
      (Nolabel, evar ~loc "__POS__");
      (Nolabel, evar ~loc "__FUNCTION__");
      (Nolabel, body);
    ]

let fail loc message = Location.raise_errorf ~loc "%s" message

let cap_name_of_lid loc = function
  | Lident name -> name
  | _ -> fail loc "capability names must be simple identifiers"

let parse_cap expr =
  match expr.pexp_desc with
  | Pexp_constraint
      ({ pexp_desc = Pexp_ident { txt = lid; loc = name_loc }; _ }, typ) ->
      (cap_name_of_lid name_loc lid, typ)
  | _ ->
      fail expr.pexp_loc
        "expected capability binding of the form (name : Type)"

let parse_caps expr =
  match expr.pexp_desc with
  | Pexp_tuple caps -> List.map parse_cap caps
  | _ -> [ parse_cap expr ]

let check_no_duplicate_caps loc caps =
  let seen = Hashtbl.create 8 in
  List.iter
    (fun name ->
      if Hashtbl.mem seen name then
        fail loc ("duplicate capability binding: " ^ name);
      Hashtbl.add seen name ())
    (List.map fst caps)

let rec expression_mentions_env expr =
  let found = ref false in
  let iter =
    object
      inherit Ast_traverse.iter as super

      method! expression expr =
        (match expr.pexp_desc with
        | Pexp_ident { txt = Lident "env"; _ } -> found := true
        | _ -> ());
        super#expression expr
    end
  in
  iter#expression expr;
  !found

let expand_thunk_like ~ctxt ~kind expr =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  match expr.pexp_desc with
  | Pexp_apply
      ( { pexp_desc = Pexp_constant (Pconst_string (name, _, _)); _ },
        [ (Nolabel, caps_expr); (Nolabel, body) ] ) ->
      if expression_mentions_env body then
        fail body.pexp_loc
          "effet leaf body must use listed capabilities, not env directly";
      let caps = parse_caps caps_expr in
      check_no_duplicate_caps loc caps;
      let env = evar ~loc "__effet_env" in
      let body =
        List.fold_right
          (fun (cap, typ) acc ->
            let cap_loc = { loc with loc_ghost = true } in
            let cap_expr =
              pexp_constraint ~loc
                (pexp_send ~loc env (Located.mk ~loc:cap_loc cap))
                typ
            in
            pexp_let ~loc Nonrecursive
              [
                value_binding ~loc
                  ~pat:(ppat_var ~loc (Located.mk ~loc:cap_loc cap))
                  ~expr:cap_expr;
              ]
              acc)
          caps body
      in
      let leaf =
        pexp_apply ~loc (effet_effect_ident ~loc kind)
          [
            (Nolabel, estring ~loc name);
            (Nolabel, pexp_fun ~loc Nolabel None (pvar ~loc "__effet_env") body);
          ]
      in
      expand_fn ~ctxt leaf
  | _ ->
      fail expr.pexp_loc
        "expected [%effet.thunk \"name\" (cap : Type) body] or a tuple of caps"

let expand_env ~ctxt expr =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  match expr.pexp_desc with
  | Pexp_record (fields, None) ->
      let names =
        List.map
          (fun ({ txt = lid; loc }, value) ->
            let name = cap_name_of_lid loc lid in
            (name, value))
          fields
      in
      check_no_duplicate_caps loc names;
      let class_fields =
        List.map
          (fun (name, value) ->
            pcf_method ~loc
              ( Located.mk ~loc name,
                Public,
                Cfk_concrete (Fresh, value) ))
          names
      in
      pexp_object ~loc
        (class_structure ~self:(ppat_any ~loc) ~fields:class_fields)
  | _ -> fail expr.pexp_loc "expected [%effet.env { cap = value; ... }]"

let fn_extension =
  Extension.V3.declare "effet.fn" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    expand_fn

let thunk_extension =
  Extension.V3.declare "effet.thunk" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    (expand_thunk_like ~kind:"thunk")

let env_extension =
  Extension.V3.declare "effet.env" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    expand_env

let () =
  Driver.register_transformation "ppx_effet"
    ~rules:
      [
        Context_free.Rule.extension fn_extension;
        Context_free.Rule.extension thunk_extension;
        Context_free.Rule.extension env_extension;
      ]
