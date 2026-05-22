open Ppxlib

let eta_effect_ident ~loc name =
  let open Ast_builder.Default in
  pexp_ident ~loc
    (Located.mk ~loc
       (Longident.Ldot (Longident.Ldot (Lident "Eta", "Effect"), name)))

let expand_fn ~ctxt body =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  pexp_apply ~loc (eta_effect_ident ~loc "fn")
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
      ({ pexp_desc = Pexp_ident { txt = lid; loc = name_loc }; _ }, Some typ, _) ->
      (cap_name_of_lid name_loc lid, typ)
  | _ ->
      fail expr.pexp_loc
        "expected capability binding of the form (name : Type)"

let parse_caps expr =
  match expr.pexp_desc with
  | Pexp_tuple caps -> List.map (fun (_, cap) -> parse_cap cap) caps
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

let expand_sync_like ~ctxt ~kind expr =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  match expr.pexp_desc with
  | Pexp_apply
      ( { pexp_desc = Pexp_constant (Pconst_string (name, _, _)); _ },
        [ (Nolabel, caps_expr); (Nolabel, body) ] ) ->
      if expression_mentions_env body then
        fail body.pexp_loc
          "eta leaf body must use listed captures, not env directly";
      let caps = parse_caps caps_expr in
      check_no_duplicate_caps loc caps;
      let body =
        List.fold_right
          (fun (cap, typ) acc ->
            let cap_loc = { loc with loc_ghost = true } in
            let cap_expr = pexp_constraint ~loc (evar ~loc cap) typ in
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
        pexp_apply ~loc (eta_effect_ident ~loc "named")
          [
            (Nolabel, estring ~loc name);
            ( Nolabel,
              pexp_apply ~loc (eta_effect_ident ~loc kind)
                [ (Nolabel, pexp_fun ~loc Nolabel None (punit ~loc) body) ]
            );
          ]
      in
      expand_fn ~ctxt leaf
  | _ ->
      fail expr.pexp_loc
        "expected [%eta.sync \"name\" (cap : Type) body] or a tuple of caps"

let fn_extension =
  Extension.V3.declare "eta.fn" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    expand_fn

let sync_extension =
  Extension.V3.declare "eta.sync" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    (expand_sync_like ~kind:"sync")

let () =
  Driver.register_transformation "ppx_eta"
    ~rules:
      [
        Context_free.Rule.extension fn_extension;
        Context_free.Rule.extension sync_extension;
      ]
