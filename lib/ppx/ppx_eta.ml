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

let expand_sync_like ~ctxt ~kind expr =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  match expr.pexp_desc with
  | Pexp_apply
      ( { pexp_desc = Pexp_constant (Pconst_string (name, _, _)); _ },
        [ (Nolabel, body) ] ) ->
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
      fail expr.pexp_loc "expected [%eta.sync \"name\" body]"

let fn_extension =
  Extension.V3.declare "eta.fn" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    expand_fn

let sync_extension =
  Extension.V3.declare "eta.sync" Extension.Context.expression
    Ast_pattern.(single_expr_payload __)
    (expand_sync_like ~kind:"sync")

let longident_of_path path =
  match String.split_on_char '.' path with
  | [] -> invalid_arg "empty path"
  | first :: rest ->
      List.fold_left
        (fun acc name -> Longident.Ldot (acc, name))
        (Longident.Lident first) rest

let sql_ident ~loc path =
  let open Ast_builder.Default in
  pexp_ident ~loc (Located.mk ~loc (longident_of_path path))

let type_ident ~loc name =
  let open Ast_builder.Default in
  ptyp_constr ~loc (Located.mk ~loc (Longident.Lident name)) []

let record_label ~loc name =
  let open Ast_builder.Default in
  Located.mk ~loc (Longident.Lident name)

let pascal_case name =
  let buf = Buffer.create (String.length name) in
  let capitalize_next = ref true in
  String.iter
    (fun ch ->
      if ch = '_' || ch = '-' then capitalize_next := true
      else if !capitalize_next then (
        Buffer.add_char buf (Char.uppercase_ascii ch);
        capitalize_next := false)
      else Buffer.add_char buf ch)
    name;
  Buffer.contents buf

let payload_empty attr =
  match attr.attr_payload with
  | PStr [] -> true
  | _ -> false

let payload_string loc attr =
  match attr.attr_payload with
  | PStr
      [
        {
          pstr_desc =
            Pstr_eval
              ({ pexp_desc = Pexp_constant (Pconst_string (value, _, _)); _ }, _);
          _;
        };
      ] ->
      value
  | _ -> fail loc ("attribute " ^ attr.attr_name.txt ^ " expects a string")

let payload_expr loc attr =
  match attr.attr_payload with
  | PStr [ { pstr_desc = Pstr_eval (expr, _); _ } ] -> expr
  | _ -> fail loc ("attribute " ^ attr.attr_name.txt ^ " expects an expression")

type sql_column_attrs = {
  primary_key : bool;
  not_null : bool;
  unique : bool;
  default : expression option;
  references : expression option;
  on_delete : string option;
  on_update : string option;
}

let empty_sql_column_attrs =
  {
    primary_key = false;
    not_null = false;
    unique = false;
    default = None;
    references = None;
    on_delete = None;
    on_update = None;
  }

let parse_sql_column_attrs attrs =
  List.fold_left
    (fun acc attr ->
      let loc = attr.attr_loc in
      match attr.attr_name.txt with
      | "primary_key" ->
          if not (payload_empty attr) then
            fail loc "attribute primary_key does not take a payload";
          { acc with primary_key = true }
      | "not_null" ->
          if not (payload_empty attr) then
            fail loc "attribute not_null does not take a payload";
          { acc with not_null = true }
      | "unique" ->
          if not (payload_empty attr) then
            fail loc "attribute unique does not take a payload";
          { acc with unique = true }
      | "default" -> { acc with default = Some (payload_expr loc attr) }
      | "references" -> { acc with references = Some (payload_expr loc attr) }
      | "on_delete" -> { acc with on_delete = Some (payload_string loc attr) }
      | "on_update" -> { acc with on_update = Some (payload_string loc attr) }
      | name -> fail loc ("unsupported eta.sql.table column attribute: " ^ name))
    empty_sql_column_attrs attrs

let rec sql_typ_expr typ =
  let loc = typ.ptyp_loc in
  let open Ast_builder.Default in
  match typ.ptyp_desc with
  | Ptyp_constr ({ txt = Longident.Lident "int"; _ }, []) ->
      sql_ident ~loc "Eta_sql.int"
  | Ptyp_constr ({ txt = Longident.Lident "int64"; _ }, []) ->
      sql_ident ~loc "Eta_sql.int64"
  | Ptyp_constr ({ txt = Longident.Lident "string"; _ }, []) ->
      sql_ident ~loc "Eta_sql.text"
  | Ptyp_constr ({ txt = Longident.Lident "bool"; _ }, []) ->
      sql_ident ~loc "Eta_sql.bool"
  | Ptyp_constr ({ txt = Longident.Lident "float"; _ }, []) ->
      sql_ident ~loc "Eta_sql.float"
  | Ptyp_constr ({ txt = Longident.Lident "bytes"; _ }, []) ->
      sql_ident ~loc "Eta_sql.blob"
  | Ptyp_constr ({ txt = Longident.Lident "option"; _ }, [ inner ])
  | Ptyp_constr ({ txt = Longident.Ldot (Longident.Lident "Option", "t"); _ }, [ inner ])
    ->
      pexp_apply ~loc (sql_ident ~loc "Eta_sql.nullable")
        [ (Nolabel, sql_typ_expr inner) ]
  | _ ->
      fail loc
        "eta.sql.table supports int, int64, string, bool, float, bytes, and option fields"

type sql_field = {
  label : label_declaration;
  field_name : string;
  field_loc : Location.t;
  sql_typ : expression;
  attrs : sql_column_attrs;
}

let parse_sql_field label =
  {
    label;
    field_name = label.pld_name.txt;
    field_loc = label.pld_name.loc;
    sql_typ = sql_typ_expr label.pld_type;
    attrs = parse_sql_column_attrs label.pld_attributes;
  }

let option_label loc label value =
  Option.map
    (fun value -> (Labelled label, Ast_builder.Default.estring ~loc value))
    value

let schema_reference_expr ~loc attrs =
  match attrs.references with
  | None ->
      if Option.is_some attrs.on_delete || Option.is_some attrs.on_update then
        fail loc
          "eta.sql.table on_delete/on_update require a references attribute";
      None
  | Some column ->
      let args =
        [
          option_label loc "on_delete" attrs.on_delete;
          option_label loc "on_update" attrs.on_update;
          Some (Nolabel, column);
        ]
        |> List.filter_map Fun.id
      in
      Some
        (Ast_builder.Default.pexp_apply ~loc
           (sql_ident ~loc "Eta_sql.Eta_schema.references")
           args)

let schema_column_expr field =
  let loc = field.field_loc in
  let open Ast_builder.Default in
  let attrs = field.attrs in
  let optional =
    [
      (if attrs.primary_key then Some (Labelled "primary_key", ebool ~loc true)
       else None);
      (if attrs.not_null then Some (Labelled "not_null", ebool ~loc true)
       else None);
      (if attrs.unique then Some (Labelled "unique", ebool ~loc true) else None);
      Option.map (fun value -> (Labelled "default", value)) attrs.default;
      Option.map
        (fun value -> (Labelled "references", value))
        (schema_reference_expr ~loc attrs);
      Some (Nolabel, evar ~loc field.field_name);
    ]
    |> List.filter_map Fun.id
  in
  pexp_apply ~loc (sql_ident ~loc "Eta_sql.Eta_schema.column") optional

let projection_constructor ~loc fields =
  let open Ast_builder.Default in
  match fields with
  | [] -> fail loc "eta.sql.table requires at least one field"
  | [ field ] ->
      pexp_apply ~loc (sql_ident ~loc "Eta_sql.Projection.one")
        [ (Nolabel, evar ~loc field.field_name) ]
  | _ ->
      let arity = List.length fields in
      if arity > 8 then
        fail loc "eta.sql.table all projection supports at most 8 fields";
      pexp_apply ~loc
        (sql_ident ~loc ("Eta_sql.Projection.t" ^ string_of_int arity))
        (List.map
           (fun field ->
             ( Nolabel,
               pexp_apply ~loc (sql_ident ~loc "Eta_sql.Projection.one")
                 [ (Nolabel, evar ~loc field.field_name) ] ))
           fields)

let mapper_pattern ~loc fields =
  let open Ast_builder.Default in
  match fields with
  | [ field ] -> ppat_var ~loc (Located.mk ~loc field.field_name)
  | _ ->
      ppat_tuple ~loc
        (List.map
           (fun field -> ppat_var ~loc (Located.mk ~loc field.field_name))
           fields)

let record_expr ~loc fields =
  let open Ast_builder.Default in
  pexp_record ~loc
    (List.map
       (fun field ->
         (record_label ~loc field.field_name, evar ~loc field.field_name))
       fields)
    None

let all_projection_expr ~loc fields =
  let open Ast_builder.Default in
  let mapper =
    pexp_fun ~loc Nolabel None (mapper_pattern ~loc fields) (record_expr ~loc fields)
  in
  pexp_apply ~loc (sql_ident ~loc "Eta_sql.Projection.map")
    [ (Nolabel, mapper); (Nolabel, projection_constructor ~loc fields) ]

let strip_label_attrs label = { label with pld_attributes = [] }

let expand_sql_table ~ctxt items =
  let loc = Expansion_context.Extension.extension_point_loc ctxt in
  let open Ast_builder.Default in
  match items with
  | [
   {
     pstr_desc = Pstr_type (_, [ ({ ptype_name; ptype_kind; _ } as td) ]);
     _;
   };
  ] -> (
      match ptype_kind with
      | Ptype_record labels ->
          let table_name = ptype_name.txt in
          if table_name = "" then fail ptype_name.loc "table type name is empty";
          let module_name = pascal_case table_name in
          let row_type_name = table_name ^ "_row" in
          let fields = List.map parse_sql_field labels in
          let row_td =
            {
              td with
              ptype_name = Located.mk ~loc:ptype_name.loc row_type_name;
              ptype_params = [];
              ptype_cstrs = [];
              ptype_kind = Ptype_record (List.map strip_label_attrs labels);
              ptype_private = Public;
              ptype_manifest = None;
              ptype_attributes = [];
            }
          in
          let row_alias_td =
            {
              td with
              ptype_name = Located.mk ~loc "row";
              ptype_params = [];
              ptype_cstrs = [];
              ptype_kind = Ptype_abstract;
              ptype_private = Public;
              ptype_manifest = Some (type_ident ~loc row_type_name);
              ptype_attributes = [];
            }
          in
          let table_module =
            pstr_module ~loc
              (module_binding ~loc
                 ~name:(Located.mk ~loc (Some module_name))
                 ~expr:
                   (pmod_structure ~loc
                      ([
                         pstr_module ~loc
                           (module_binding ~loc
                              ~name:(Located.mk ~loc (Some "T"))
                              ~expr:
                                (pmod_apply ~loc
                                   (pmod_ident ~loc
                                      (Located.mk ~loc
                                         (longident_of_path "Eta_sql.Table.Make")))
                                   (pmod_structure ~loc
                                      [
                                        pstr_value ~loc Nonrecursive
                                          [
                                            value_binding ~loc
                                              ~pat:
                                                (ppat_var ~loc
                                                   (Located.mk ~loc "name"))
                                              ~expr:(estring ~loc table_name);
                                          ];
                                      ])));
                         pstr_include ~loc
                           (include_infos ~loc
                              (pmod_ident ~loc
                                 (Located.mk ~loc (Longident.Lident "T"))));
                         pstr_type ~loc Nonrecursive [ row_alias_td ];
                       ]
                      @ List.map
                          (fun field ->
                            pstr_value ~loc:field.field_loc Nonrecursive
                              [
                                value_binding ~loc:field.field_loc
                                  ~pat:
                                    (ppat_var ~loc:field.field_loc
                                       (Located.mk ~loc:field.field_loc
                                          field.field_name))
                                  ~expr:
                                    (pexp_apply ~loc:field.field_loc
                                       (evar ~loc:field.field_loc "column")
                                       [
                                         (Nolabel, estring ~loc:field.field_loc field.field_name);
                                         (Nolabel, field.sql_typ);
                                       ]);
                              ])
                          fields
                      @ [
                          pstr_value ~loc Nonrecursive
                            [
                              value_binding ~loc
                                ~pat:(ppat_var ~loc (Located.mk ~loc "all"))
                                ~expr:(all_projection_expr ~loc fields);
                            ];
                          pstr_value ~loc Nonrecursive
                            [
                              value_binding ~loc
                                ~pat:(ppat_var ~loc (Located.mk ~loc "schema"))
                                ~expr:
                                  (pexp_apply ~loc
                                     (sql_ident ~loc "Eta_sql.Eta_schema.create_table")
                                     [
                                       (Nolabel, evar ~loc "table");
                                       (Nolabel, elist ~loc (List.map schema_column_expr fields));
                                     ]);
                            ];
                        ])))
          in
          pstr_include ~loc
            (include_infos ~loc
               (pmod_structure ~loc [ pstr_type ~loc Nonrecursive [ row_td ]; table_module ]))
      | _ -> fail ptype_name.loc "eta.sql.table expects a record type declaration")
  | _ ->
      fail loc
        "expected [%%eta.sql.table type users = { id : int; name : string }]"

let sql_table_extension =
  Extension.V3.declare "eta.sql.table" Extension.Context.structure_item
    Ast_pattern.(pstr __)
    expand_sql_table

let eta_render_attribute =
  Attribute.declare_with_attr_loc "@eta.render" Attribute.Context.rtag
    Ast_pattern.__
    (fun ~attr_loc payload -> (attr_loc, payload))

let eta_render row ~type_name ~tag_name =
  match Attribute.get_res eta_render_attribute row with
  | Ok None -> None
  | Ok (Some (attr_loc, payload)) -> (
      match payload with
      | PStr [ { pstr_desc = Pstr_eval (expr, _); _ } ] -> Some expr
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

let eta_error_case ~type_name row =
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
              (pexp_apply ~loc (sql_ident ~loc "Format.pp_print_string")
                 [
                   (Nolabel, evar ~loc "fmt");
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
      let value = "value" in
      let args =
        [
          (Nolabel, evar ~loc "fmt");
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
        ~rhs:(pexp_apply ~loc (sql_ident ~loc "Format.fprintf") args)
  | Rtag (tag, _, payloads) ->
      fail tag.loc
        (Printf.sprintf
           "eta_error: tag `%s in type %s has %d payload types; eta_error \
            supports nullary tags or exactly one payload; combine them into one \
            supported payload type or write pp_%s manually"
           tag.txt type_name (List.length payloads) type_name)

let eta_error_type declaration =
  let loc = declaration.ptype_loc in
  let type_name = declaration.ptype_name.txt in
  let open Ast_builder.Default in
  if declaration.ptype_params <> [] then
    fail declaration.ptype_name.loc
      (Printf.sprintf
         "eta_error: type %s has type parameters; eta_error version 1 supports \
          monomorphic error types; remove the parameters or write pp_%s manually"
         type_name type_name);
  if declaration.ptype_private = Private then
    fail declaration.ptype_name.loc
      (Printf.sprintf
         "eta_error: type %s is private; eta_error version 1 supports public \
          closed polymorphic-variant aliases; make it public or write pp_%s \
          manually"
         type_name type_name);
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
             "eta_error: type %s is not a closed polymorphic-variant alias; \
              [@@deriving eta_error] supports type %s = [ `Tag ... ]; rewrite \
              the type as a closed polymorphic variant or write pp_%s manually"
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
      (ptyp_arrow ~loc Nolabel (type_ident ~loc type_name)
         (ptyp_constr ~loc (Located.mk ~loc (Longident.Lident "unit")) []))
  in
  pstr_value ~loc Nonrecursive
    [
      value_binding ~loc
        ~pat:
          (ppat_constraint ~loc
             (ppat_var ~loc (Located.mk ~loc ("pp_" ^ type_name)))
             printer_type)
        ~expr:
          (pexp_fun ~loc Nolabel None
             (ppat_var ~loc (Located.mk ~loc "fmt"))
             (pexp_function ~loc (List.map (eta_error_case ~type_name) rows)));
    ]

let eta_error_generator =
  Deriving.Generator.make_noarg (fun ~loc:_ ~path:_ (_, declarations) ->
      List.map eta_error_type declarations)

let () =
  Deriving.add "eta_error" ~str_type_decl:eta_error_generator |> Deriving.ignore;
  Driver.register_transformation "ppx_eta"
    ~rules:
      [
        Context_free.Rule.extension fn_extension;
        Context_free.Rule.extension sync_extension;
        Context_free.Rule.extension sql_table_extension;
      ]
