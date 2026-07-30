open Ppxlib

let eta_effect_ident ~loc name =
  let open Ast_builder.Default in
  pexp_ident ~loc
    (Located.mk ~loc
       (Longident.Ldot (Longident.Ldot (Lident "Eta", "Effect"), name)))

let eta_observability_ident ~loc name =
  let open Ast_builder.Default in
  pexp_ident ~loc
    (Located.mk ~loc
       (Longident.Ldot (Lident "Eta_observability", name)))

let expand_fn ~ctxt body =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  pexp_apply ~loc (eta_observability_ident ~loc "fn")
    [
      (Nolabel, evar ~loc "__POS__");
      (Nolabel, evar ~loc "__FUNCTION__");
      (Nolabel, body);
    ]

let fail loc message = Location.raise_errorf ~loc "%s" message

let expand_sync_like ~ctxt ~kind ~form expr =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  match expr.pexp_desc with
  | Pexp_apply
      ( { pexp_desc = Pexp_constant (Pconst_string (name, _, _)); _ },
        [ (Nolabel, body) ] ) ->
      let leaf =
        pexp_apply ~loc (eta_observability_ident ~loc "named")
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
        (Printf.sprintf "expected [%%eta.%s \"name\" body]" form)

let fn_extension =
  Extension.V3.declare "eta.fn" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    expand_fn

let sync_extension =
  Extension.V3.declare "eta.sync" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    (expand_sync_like ~kind:"sync" ~form:"sync")

let result_extension =
  Extension.V3.declare "eta.result" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    (expand_sync_like ~kind:"sync_result" ~form:"result")

let longident_of_path path =
  match String.split_on_char '.' path with
  | [] -> invalid_arg "empty path"
  | first :: rest ->
      List.fold_left
        (fun acc name -> Longident.Ldot (acc, name))
        (Longident.Lident first) rest

let path_ident ~loc path =
  let open Ast_builder.Default in
  pexp_ident ~loc (Located.mk ~loc (longident_of_path path))

let eta_render_attribute =
  Attribute.declare_with_attr_loc "@eta.render" Attribute.Context.rtag
    Ast_pattern.__
    (fun ~attr_loc payload -> (attr_loc, payload))

let eta_render row ~type_name ~tag_name =
  match Attribute.get_res eta_render_attribute row with
  | Ok None -> None
  | Ok (Some (attr_loc, payload)) -> (
      match payload with
      | PStr
          [
            {
              pstr_desc = Pstr_eval (({ pexp_desc = Pexp_ident _; _ } as expr), _);
              _;
            };
          ] ->
          Some expr
      | _ ->
          fail attr_loc
            (Printf.sprintf
               "eta_error: tag `%s in type %s has malformed [@eta.render]; \
                expected [@eta.render My_type.pp] where the printer has type \
                Format.formatter -> payload -> unit; fix or remove the attribute"
               tag_name type_name))
  | Error _ ->
      fail row.prf_loc
        (Printf.sprintf
           "eta_error: tag `%s in type %s has multiple [@eta.render] \
            attributes; keep exactly one renderer attribute"
           tag_name type_name)

let eta_error_builtin typ =
  match typ.ptyp_desc with
  | Ptyp_constr ({ txt = Longident.Lident "string"; _ }, []) -> Some "%s"
  | Ptyp_constr ({ txt = Longident.Lident "int"; _ }, []) -> Some "%d"
  | Ptyp_constr ({ txt = Longident.Lident "int64"; _ }, []) -> Some "%Ld"
  | Ptyp_constr ({ txt = Longident.Lident "float"; _ }, []) -> Some "%g"
  | Ptyp_constr ({ txt = Longident.Lident "bool"; _ }, []) -> Some "%b"
  | _ -> None

let eta_error_case ~fmt ~type_name row =
  let loc = row.prf_loc in
  let open Ast_builder.Default in
  match row.prf_desc with
  | Rinherit _ ->
      fail loc
        (Printf.sprintf
           "eta_error: type %s contains an inherited polymorphic-variant row; \
            eta_error cannot derive inherited tags; list the tags explicitly \
            or write pp_%s manually"
           type_name type_name)
  | Rtag (tag, true, []) -> (
      match eta_render row ~type_name ~tag_name:tag.txt with
      | Some _ ->
          fail tag.loc
            (Printf.sprintf
               "eta_error: nullary tag `%s in type %s has [@eta.render]; render \
                applies only to one-payload tags; remove the attribute or add a \
                payload"
               tag.txt type_name)
      | None ->
          case
            ~lhs:(ppat_variant ~loc tag.txt None)
            ~guard:None
            ~rhs:
              (pexp_apply ~loc (path_ident ~loc "Format.pp_print_string")
                 [
                   (Nolabel, evar ~loc fmt);
                   (Nolabel, estring ~loc (String.lowercase_ascii tag.txt));
                 ]))
  | Rtag (tag, false, [ typ ]) ->
      let renderer = eta_render row ~type_name ~tag_name:tag.txt in
      let format =
        match (renderer, eta_error_builtin typ) with
        | Some _, _ -> "%a"
        | None, Some format -> format
        | None, None ->
            fail typ.ptyp_loc
              (Printf.sprintf
                 "eta_error: payload of tag `%s in type %s is unsupported; \
                  supported built-ins are string, int, int64, float, and bool; \
                  add [@eta.render My_type.pp] to this tag or write pp_%s \
                  manually"
                 tag.txt type_name type_name)
      in
      let value = gen_symbol ~prefix:"__eta_value" () in
      let args =
        [
          (Nolabel, evar ~loc fmt);
          ( Nolabel,
            estring ~loc
              (String.lowercase_ascii tag.txt ^ ":" ^ format) );
        ]
        @ Option.fold ~none:[]
            ~some:(fun renderer -> [ (Nolabel, renderer) ])
            renderer
        @ [ (Nolabel, evar ~loc value) ]
      in
      case
        ~lhs:
          (ppat_variant ~loc tag.txt
             (Some (ppat_var ~loc (Located.mk ~loc value))))
        ~guard:None
        ~rhs:(pexp_apply ~loc (path_ident ~loc "Format.fprintf") args)
  | Rtag (tag, _, payloads) ->
      fail tag.loc
        (Printf.sprintf
           "eta_error: tag `%s in type %s has %d payload types; eta_error \
            supports nullary tags or exactly one payload; combine them into one \
            supported payload type or write pp_%s manually"
           tag.txt type_name (List.length payloads) type_name)

let eta_error_declaration declaration =
  let loc = declaration.ptype_loc in
  let type_name = declaration.ptype_name.txt in
  let open Ast_builder.Default in
  if declaration.ptype_private = Private then
    fail declaration.ptype_name.loc
      (Printf.sprintf
         "eta_error: type %s is private, so generated pp_%s cannot pattern-match \
          its tags; make the alias public or write pp_%s manually inside the \
          defining module"
         type_name type_name type_name);
  let rows =
    match (declaration.ptype_kind, declaration.ptype_manifest) with
    | Ptype_abstract,
      Some { ptyp_desc = Ptyp_variant (rows, Closed, None); _ } ->
        rows
    | Ptype_abstract,
      Some ({ ptyp_desc = Ptyp_variant (_, (Open | Closed), Some _); _ } as typ)
    | Ptype_abstract,
      Some ({ ptyp_desc = Ptyp_variant (_, Open, None); _ } as typ) ->
        fail typ.ptyp_loc
          (Printf.sprintf
             "eta_error: type %s uses an open or restricted \
              polymorphic-variant row; pp_%s must be exhaustive; use [ ... ] \
              without > or <, or write pp_%s manually"
             type_name type_name type_name)
    | _ ->
        fail declaration.ptype_name.loc
          (Printf.sprintf
             "eta_error: type %s is not a public, explicit-tag closed \
              polymorphic-variant alias; [@@deriving eta_error] supports type \
              %s = [ `Tag ... ]; rewrite the type as a public closed row with \
              every tag listed explicitly, or write pp_%s manually"
             type_name type_name type_name)
  in
  if rows = [] then
    fail declaration.ptype_name.loc
      (Printf.sprintf
         "eta_error: type %s has no tags; eta_error requires at least one \
          polymorphic-variant tag; add a tag or write pp_%s manually"
         type_name type_name);
  let formatter_type =
    ptyp_constr ~loc
      (Located.mk ~loc
         (Longident.Ldot (Longident.Lident "Format", "formatter")))
      []
  in
  let printer_type =
    ptyp_arrow ~loc Nolabel formatter_type
      (ptyp_arrow ~loc Nolabel
         (core_type_of_type_declaration declaration)
         (ptyp_constr ~loc (Located.mk ~loc (Longident.Lident "unit")) []))
  in
  (type_name, rows, printer_type)

let eta_error_type declaration =
  let loc = declaration.ptype_loc in
  let type_name, rows, printer_type = eta_error_declaration declaration in
  let open Ast_builder.Default in
  let fmt = gen_symbol ~prefix:"__eta_fmt" () in
  let error = gen_symbol ~prefix:"__eta_error" () in
  pstr_value ~loc Nonrecursive
    [
      value_binding ~loc
        ~pat:
          (ppat_constraint ~loc
             (ppat_var ~loc (Located.mk ~loc ("pp_" ^ type_name)))
             printer_type)
        ~expr:
          (pexp_fun ~loc Nolabel None
             (ppat_var ~loc (Located.mk ~loc fmt))
             (pexp_fun ~loc Nolabel None
                (ppat_var ~loc (Located.mk ~loc error))
                (pexp_match ~loc (evar ~loc error)
                   (List.map (eta_error_case ~fmt ~type_name) rows))));
    ]

let eta_error_signature declaration =
  let loc = declaration.ptype_loc in
  let type_name, rows, printer_type = eta_error_declaration declaration in
  let open Ast_builder.Default in
  List.iter
    (fun row -> ignore (eta_error_case ~fmt:"__eta_fmt" ~type_name row))
    rows;
  psig_value ~loc
    (value_description ~loc ~name:(Located.mk ~loc ("pp_" ^ type_name))
       ~type_:printer_type ~prim:[])

let eta_error_structure_generator =
  Deriving.Generator.make_noarg (fun ~loc:_ ~path:_ (_, declarations) ->
      List.map eta_error_type declarations)

let eta_error_signature_generator =
  Deriving.Generator.make_noarg (fun ~loc:_ ~path:_ (_, declarations) ->
      List.map eta_error_signature declarations)

let () =
  Deriving.add "eta_error" ~str_type_decl:eta_error_structure_generator
    ~sig_type_decl:eta_error_signature_generator
  |> Deriving.ignore;
  Driver.register_transformation "ppx_eta"
    ~rules:
      [
        Context_free.Rule.extension fn_extension;
        Context_free.Rule.extension sync_extension;
        Context_free.Rule.extension result_extension;
      ]
