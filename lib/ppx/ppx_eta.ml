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
  default : string option;
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
      | "default" -> { acc with default = Some (payload_string loc attr) }
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
      Option.map
        (fun value -> (Labelled "default", estring ~loc value))
        attrs.default;
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
           (fun field -> (Nolabel, evar ~loc field.field_name))
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

let () =
  Driver.register_transformation "ppx_eta"
    ~rules:
      [
        Context_free.Rule.extension fn_extension;
        Context_free.Rule.extension sync_extension;
        Context_free.Rule.extension sql_table_extension;
      ]
