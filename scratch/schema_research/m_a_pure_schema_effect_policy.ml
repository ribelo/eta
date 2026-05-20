open Effet
open Fixture
open Migration_fixture

module Schema = struct
  type 'a t = {
    decode : Json.t -> ('a, issue list) result;
    encode : 'a -> Json.t;
    json_schema : Json.t;
    samples : 'a list;
    equal : 'a -> 'a -> bool;
  }

  type ('record, 'field) field =
    | Required : {
        name : string;
        schema : 'field t;
        get : 'record -> 'field;
      }
        -> ('record, 'field) field
    | Optional : {
        name : string;
        schema : 'field t;
        get : 'record -> 'field option;
      }
        -> ('record, 'field option) field

  let required name schema get = Required { name; schema; get }
  let optional name schema get = Optional { name; schema; get }

  let field_name : type record a. (record, a) field -> string = function
    | Required f -> f.name
    | Optional f -> f.name

  let field_schema_json : type record a. (record, a) field -> Json.t =
    function
    | Required f -> f.schema.json_schema
    | Optional f -> f.schema.json_schema

  let field_required_json : type record a. (record, a) field -> Json.t option =
    function
    | Required f -> Some (Json.String f.name)
    | Optional _ -> None

  let emit_field : type record a.
      (record, a) field -> record -> (string * Json.t) option =
   fun field record ->
    match field with
    | Required f -> Some (f.name, f.schema.encode (f.get record))
    | Optional f -> Option.map (fun value -> (f.name, f.schema.encode value)) (f.get record)

  let string =
    {
      decode =
        (function
        | Json.String s -> Ok s
        | json -> Error [ issue ("Expected string, got " ^ Json.to_string json) ]);
      encode = (fun s -> Json.String s);
      json_schema = Json.object_ [ ("type", Json.String "string") ];
      samples = [ ""; "x" ];
      equal = String.equal;
    }

  let bool =
    {
      decode =
        (function
        | Json.Bool b -> Ok b
        | json -> Error [ issue ("Expected boolean, got " ^ Json.to_string json) ]);
      encode = (fun b -> Json.Bool b);
      json_schema = Json.object_ [ ("type", Json.String "boolean") ];
      samples = [ false; true ];
      equal = Bool.equal;
    }

  let int =
    {
      decode =
        (function
        | Json.Number n when is_int_float n -> Ok (int_of_float n)
        | json -> Error [ issue ("Expected int, got " ^ Json.to_string json) ]);
      encode = (fun n -> Json.Number (float_of_int n));
      json_schema = Json.object_ [ ("type", Json.String "integer") ];
      samples = [ 0; 1 ];
      equal = Int.equal;
    }

  let float =
    {
      decode =
        (function
        | Json.Number n -> Ok n
        | json -> Error [ issue ("Expected number, got " ^ Json.to_string json) ]);
      encode = (fun n -> Json.Number n);
      json_schema = Json.object_ [ ("type", Json.String "number") ];
      samples = [ 0.; 1. ];
      equal = Float.equal;
    }

  let array item =
    let decode = function
      | Json.Array xs ->
          let rec loop i acc issues = function
            | [] -> if issues = [] then Ok (List.rev acc) else Error (List.rev issues)
            | x :: xs -> (
                match item.decode x with
                | Ok value -> loop (i + 1) (value :: acc) issues xs
                | Error item_issues ->
                    loop (i + 1) acc (List.rev_append (at (string_of_int i) item_issues) issues) xs)
          in
          loop 0 [] [] xs
      | json -> Error [ issue ("Expected array, got " ^ Json.to_string json) ]
    in
    {
      decode;
      encode = (fun xs -> Json.Array (List.map item.encode xs));
      json_schema = Json.object_ [ ("type", Json.String "array"); ("items", item.json_schema) ];
      samples = [ []; item.samples ];
      equal = List.equal item.equal;
    }

  let option item =
    {
      decode =
        (function
        | Json.Null -> Ok None
        | json -> Result.map (fun value -> Some value) (item.decode json));
      encode = (function None -> Json.Null | Some value -> item.encode value);
      json_schema = Json.object_ [ ("anyOf", Json.Array [ item.json_schema; Json.object_ [ ("type", Json.String "null") ] ]) ];
      samples = None :: List.map (fun value -> Some value) item.samples;
      equal = Option.equal item.equal;
    }

  let refine ~name check schema =
    {
      schema with
      decode =
        (fun json ->
          match schema.decode json with
          | Error issues -> Error issues
          | Ok value -> (
              match check value with [] -> Ok value | issues -> Error issues));
      json_schema =
        Json.object_
          [ ("allOf", Json.Array [ schema.json_schema ]); ("description", Json.String name) ];
    }

  let transform ~name ~decode ~encode schema =
    {
      decode =
        (fun json ->
          match schema.decode json with Ok value -> decode value | Error issues -> Error issues);
      encode = (fun value -> schema.encode (encode value));
      json_schema =
        Json.object_
          [ ("allOf", Json.Array [ schema.json_schema ]); ("description", Json.String name) ];
      samples =
        List.filter_map
          (fun value -> match decode value with Ok decoded -> Some decoded | Error _ -> None)
          schema.samples;
      equal = Stdlib.( = );
    }

  let brand ~name pred schema =
    transform ~name
      ~decode:(fun value ->
        if pred value then Ok (Migration_fixture.Brand.make value)
        else Error [ issue ("Expected " ^ name) ])
      ~encode:Migration_fixture.Brand.value schema

  let enum ~name cases =
    let decode = function
      | Json.String s -> (
          match List.find_opt (fun (label, _) -> String.equal label s) cases with
          | Some (_, value) -> Ok value
          | None -> Error [ issue ("Expected " ^ name ^ ", got " ^ Json.to_string (Json.String s)) ])
      | json -> Error [ issue ("Expected " ^ name ^ ", got " ^ Json.to_string json) ]
    in
    {
      decode;
      encode =
        (fun value ->
          let label, _ =
            List.find
              (fun (_, candidate) ->
                (* Enum values here are nullary variants, so structural equality
                   is the simplest lab stand-in. *)
                Stdlib.( = ) value candidate)
              cases
          in
          Json.String label);
      json_schema =
        Json.object_
          [ ("enum", Json.Array (List.map (fun (label, _) -> Json.String label) cases)) ];
      samples = List.map snd cases;
      equal = Stdlib.( = );
    }

  let decode_field : type record a.
      Json.t -> (record, a) field -> (a, issue list) result =
   fun json field ->
    match field with
    | Required f -> (
        match Json.find f.name json with
        | None -> Error [ issue ~path:[ f.name ] "Missing key" ]
        | Some value -> Result.map_error (at f.name) (f.schema.decode value))
    | Optional f -> (
        match Json.find f.name json with
        | None -> Ok None
        | Some value ->
            Result.map (fun value -> Some value)
              (Result.map_error (at f.name) (f.schema.decode value)))

  let record4 ~name make f1 f2 f3 f4 ~equal ~samples =
    let fields =
      [
        (field_name f1, field_schema_json f1);
        (field_name f2, field_schema_json f2);
        (field_name f3, field_schema_json f3);
        (field_name f4, field_schema_json f4);
      ]
    in
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match
              (decode_field json f1, decode_field json f2, decode_field json f3, decode_field json f4)
            with
            | Ok a, Ok b, Ok c, Ok d -> Ok (make a b c d)
            | results ->
                let collect = function Ok _ -> [] | Error issues -> issues in
                let a, b, c, d = results in
                Error (collect a @ collect b @ collect c @ collect d))
        | json -> Error [ issue ("Expected object " ^ name ^ ", got " ^ Json.to_string json) ]);
      encode =
        (fun record ->
          Json.Object
            (List.filter_map
               Fun.id
               [
                 emit_field f1 record;
                 emit_field f2 record;
                 emit_field f3 record;
                 emit_field f4 record;
               ]));
      json_schema =
        Json.object_
          [
            ("type", Json.String "object");
            ("title", Json.String name);
            ("properties", Json.Object fields);
            ( "required",
              Json.Array
                (List.filter_map Fun.id
                   [
                     field_required_json f1;
                     field_required_json f2;
                     field_required_json f3;
                     field_required_json f4;
                   ]) );
          ];
      samples;
      equal;
    }

  let record3 ~name make f1 f2 f3 ~equal ~samples =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match (decode_field json f1, decode_field json f2, decode_field json f3) with
            | Ok a, Ok b, Ok c -> Ok (make a b c)
            | a, b, c ->
                let collect = function Ok _ -> [] | Error issues -> issues in
                Error (collect a @ collect b @ collect c))
        | json -> Error [ issue ("Expected object " ^ name ^ ", got " ^ Json.to_string json) ]);
      encode =
        (fun record ->
          Json.Object
            (List.filter_map Fun.id
               [ emit_field f1 record; emit_field f2 record; emit_field f3 record ]));
      json_schema =
        Json.object_
          [
            ("type", Json.String "object");
            ("title", Json.String name);
            ( "properties",
              Json.Object
                [
                  (field_name f1, field_schema_json f1);
                  (field_name f2, field_schema_json f2);
                  (field_name f3, field_schema_json f3);
                ] );
            ( "required",
              Json.Array
                (List.filter_map Fun.id
                   [
                     field_required_json f1;
                     field_required_json f2;
                     field_required_json f3;
                   ]) );
          ];
      samples;
      equal;
    }

  let record6 ~name make f1 f2 f3 f4 f5 f6 ~equal ~samples =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match
              ( decode_field json f1,
                decode_field json f2,
                decode_field json f3,
                decode_field json f4,
                decode_field json f5,
                decode_field json f6 )
            with
            | Ok a, Ok b, Ok c, Ok d, Ok e, Ok f -> Ok (make a b c d e f)
            | a, b, c, d, e, f ->
                let collect = function Ok _ -> [] | Error issues -> issues in
                Error (collect a @ collect b @ collect c @ collect d @ collect e @ collect f))
        | json -> Error [ issue ("Expected object " ^ name ^ ", got " ^ Json.to_string json) ]);
      encode =
        (fun record ->
          Json.Object
            (List.filter_map Fun.id
               [
                 emit_field f1 record;
                 emit_field f2 record;
                 emit_field f3 record;
                 emit_field f4 record;
                 emit_field f5 record;
                 emit_field f6 record;
               ]));
      json_schema =
        Json.object_
          [
            ("type", Json.String "object");
            ("title", Json.String name);
            ( "required",
              Json.Array
                (List.filter_map Fun.id
                   [
                     field_required_json f1;
                     field_required_json f2;
                     field_required_json f3;
                     field_required_json f4;
                     field_required_json f5;
                     field_required_json f6;
                   ]) );
          ];
      samples;
      equal;
    }

  let tagged_union ~name ~tag cases =
    let decode json =
      match Json.find tag json with
      | Some (Json.String tag_value) -> (
          match List.find_opt (fun (case, _, _) -> String.equal case tag_value) cases with
          | Some (_, decode, _) -> decode json
          | None -> Error [ issue ~path:[ tag ] ("Unknown tag " ^ tag_value) ])
      | Some json -> Error [ issue ~path:[ tag ] ("Expected string tag, got " ^ Json.to_string json) ]
      | None -> Error [ issue ~path:[ tag ] "Missing tag" ]
    in
    {
      decode;
      encode =
        (fun value ->
          let rec try_cases = function
            | [] -> invalid_arg ("cannot encode " ^ name)
            | (tag_value, _, encode) :: rest -> (
                match encode value with
                | None -> try_cases rest
                | Some (Json.Object fields) -> Json.Object ((tag, Json.String tag_value) :: fields)
                | Some json -> json)
          in
          try_cases cases);
      json_schema =
        Json.object_
          [ ("oneOf", Json.Array (List.map (fun (tag_value, _, _) -> Json.object_ [ ("title", Json.String tag_value) ]) cases)) ];
      samples = [];
      equal = Stdlib.( = );
    }

  let lazy_ thunk =
    {
      decode = (fun json -> (thunk ()).decode json);
      encode = (fun value -> (thunk ()).encode value);
      json_schema = Json.object_ [ ("$ref", Json.String "#/recursive") ];
      samples = [];
      equal = (fun a b -> (thunk ()).equal a b);
    }

  let decode schema json =
    match schema.decode json with
    | Ok value -> Effect.pure value
    | Error issues -> Effect.fail (`Decode issues)

  let encode schema value = schema.encode value
  let equal schema = schema.equal
  let samples schema = schema.samples
  let json_schema schema = schema.json_schema

  let decode_with_policy schema policy json =
    Effect.bind policy (decode schema json)
end

let non_empty =
  Schema.refine ~name:"non-empty"
    (fun s -> if String.length s > 0 then [] else [ issue "Expected non-empty string" ])
    Schema.string

let bounded_int ~min ~max =
  Schema.refine ~name:(Printf.sprintf "%d..%d" min max)
    (fun n ->
      if n >= min && n <= max then []
      else [ issue (Printf.sprintf "Expected %d <= value <= %d" min max) ])
    Schema.int

let user_id =
  Schema.brand ~name:"user_id"
    (fun s -> String.length s > 4 && String.sub s 0 4 = "usr_")
    Schema.string

let email =
  Schema.brand ~name:"email"
    (fun s -> String.contains s '@')
    Schema.string

let flag_key =
  Schema.brand ~name:"flag_key"
    (fun s -> String.length s > 5 && String.sub s 0 5 = "flag.")
    Schema.string

let role =
  Schema.enum ~name:"role"
    [ ("admin", Admin); ("analyst", Analyst); ("viewer", Viewer) ]

let retry_after =
  Schema.transform ~name:"duration-ms"
    ~decode:(fun s ->
      if String.ends_with ~suffix:"ms" s then
        match int_of_string_opt (String.sub s 0 (String.length s - 2)) with
        | Some n when n >= 0 -> Ok n
        | _ -> Error [ issue "Expected non-negative duration in ms" ]
      else Error [ issue "Expected duration like 500ms" ])
    ~encode:(fun n -> string_of_int n ^ "ms")
    Schema.string

let database =
  Schema.record3 ~name:"database"
    (fun host port ssl -> { host; port; ssl })
    (Schema.required "host" non_empty (fun db -> db.host))
    (Schema.required "port" (bounded_int ~min:1 ~max:65535) (fun db -> db.port))
    (Schema.required "ssl" Schema.bool (fun db -> db.ssl))
    ~equal:database_equal ~samples:[ sample_config.db ]

let user =
  Schema.record4 ~name:"user"
    (fun id name email roles -> { id; name; email; roles })
    (Schema.required "id" user_id (fun u -> u.id))
    (Schema.required "name" non_empty (fun u -> u.name))
    (Schema.optional "email" email (fun u -> u.email))
    (Schema.required "roles" (Schema.array role) (fun u -> u.roles))
    ~equal:user_equal ~samples:[ sample_user ]

let feature =
  Schema.record3 ~name:"feature"
    (fun key enabled rollout -> { key; enabled; rollout })
    (Schema.required "key" flag_key (fun f -> f.key))
    (Schema.required "enabled" Schema.bool (fun f -> f.enabled))
    (Schema.optional "rollout" (bounded_int ~min:0 ~max:100) (fun f -> f.rollout))
    ~equal:feature_equal ~samples:sample_config.features

let auth =
  let password_decode json =
    match Json.find "minLength" json with
    | Some value -> (
        match (bounded_int ~min:8 ~max:128).Schema.decode value with
        | Ok min_length -> Ok (Password { min_length })
        | Error issues -> Error (at "minLength" issues))
    | None -> Error [ issue ~path:[ "minLength" ] "Missing key" ]
  in
  let oauth_decode json =
    match (Json.find "issuer" json, Json.find "clientId" json) with
    | Some (Json.String issuer), Some (Json.String client_id) ->
        Ok (OAuth { issuer; client_id })
    | _ -> Error [ issue "Invalid OAuth auth" ]
  in
  let password_encode = function
    | Password { min_length } ->
        Some (Json.object_ [ ("minLength", Json.number min_length) ])
    | _ -> None
  in
  let oauth_encode = function
    | OAuth { issuer; client_id } ->
        Some
          (Json.object_
             [ ("issuer", Json.string issuer); ("clientId", Json.string client_id) ])
    | _ -> None
  in
  {
    (Schema.tagged_union ~name:"auth" ~tag:"_tag"
       [ ("Password", password_decode, password_encode); ("OAuth", oauth_decode, oauth_encode) ])
    with
    Schema.equal = auth_equal;
    samples = [ sample_config.auth ];
  }

let config =
  Schema.record6 ~name:"config"
    (fun service db auth users features retry_after_ms ->
      { service; db; auth; users; features; retry_after_ms })
    (Schema.required "service" non_empty (fun c -> c.service))
    (Schema.required "db" database (fun c -> c.db))
    (Schema.required "auth" auth (fun c -> c.auth))
    (Schema.required "users" (Schema.array user) (fun c -> c.users))
    (Schema.required "features" (Schema.array feature) (fun c -> c.features))
    (Schema.required "retryAfter" retry_after (fun c -> c.retry_after_ms))
    ~equal:config_equal ~samples:[ sample_config ]

let event =
  let user_created_decode json =
    match Json.find "user" json with
    | Some value -> Result.map (fun user -> User_created user) (user.Schema.decode value)
    | None -> Error [ issue ~path:[ "user" ] "Missing key" ]
  in
  let user_created_encode = function
    | User_created u -> Some (Json.object_ [ ("user", user.Schema.encode u) ])
    | _ -> None
  in
  let feature_toggled_decode json =
    match (Json.find "key" json, Json.find "enabled" json) with
    | Some key_json, Some enabled_json -> (
        match (flag_key.Schema.decode key_json, Schema.bool.Schema.decode enabled_json) with
        | Ok key, Ok enabled -> Ok (Feature_toggled { key; enabled })
        | a, b ->
            let collect = function Ok _ -> [] | Error issues -> issues in
            Error (collect a @ collect b))
    | _ -> Error [ issue "Invalid FeatureToggled event" ]
  in
  let feature_toggled_encode = function
    | Feature_toggled { key; enabled } ->
        Some
          (Json.object_
             [ ("key", flag_key.Schema.encode key); ("enabled", Json.Bool enabled) ])
    | _ -> None
  in
  let metric_decode json =
    match (Json.find "name" json, Json.find "value" json) with
    | Some (Json.String name), Some (Json.Number value) -> Ok (Metric { name; value })
    | _ -> Error [ issue "Invalid Metric event" ]
  in
  let metric_encode = function
    | Metric { name; value } ->
        Some (Json.object_ [ ("name", Json.String name); ("value", Json.Number value) ])
    | _ -> None
  in
  {
    (Schema.tagged_union ~name:"event" ~tag:"_tag"
       [
         ("UserCreated", user_created_decode, user_created_encode);
         ("FeatureToggled", feature_toggled_decode, feature_toggled_encode);
         ("Metric", metric_decode, metric_encode);
       ])
    with
    Schema.equal = event_equal;
    samples = [ sample_event ];
  }

let rec menu () =
  let item_decode json =
    match (Json.find "label" json, Json.find "route" json) with
    | Some (Json.String label), Some (Json.String route) -> Ok (Item { label; route })
    | _ -> Error [ issue "Invalid menu item" ]
  in
  let item_encode = function
    | Item { label; route } ->
        Some (Json.object_ [ ("label", Json.String label); ("route", Json.String route) ])
    | _ -> None
  in
  let group_decode json =
    match (Json.find "label" json, Json.find "children" json) with
    | Some (Json.String label), Some children_json -> (
        match (Schema.array (Schema.lazy_ menu)).Schema.decode children_json with
        | Ok children -> Ok (Group { label; children })
        | Error issues -> Error (at "children" issues))
    | _ -> Error [ issue "Invalid menu group" ]
  in
  let group_encode = function
    | Group { label; children } ->
        Some
          (Json.object_
             [
               ("label", Json.String label);
               ("children", (Schema.array (Schema.lazy_ menu)).Schema.encode children);
             ])
    | _ -> None
  in
  {
    (Schema.tagged_union ~name:"menu" ~tag:"_tag"
       [ ("Item", item_decode, item_encode); ("Group", group_decode, group_encode) ])
    with
    Schema.equal = menu_equal;
    samples = [ sample_menu ];
  }

let decode_config_with_policy json =
  let policy config =
    Effect.bind
      (fun allowed ->
        if allowed then Effect.pure config
        else Effect.fail (`Decode [ issue "feature policy rejected config" ]))
      (Effect.sync "feature_policy" (fun env ->
           List.for_all (fun feature -> env#feature_allowed (Brand.value feature.key)) config.features))
  in
  Schema.decode_with_policy config policy json

let support = full_support

module type MIGRATION_SIG = sig
  module Schema : sig
    type 'a t

    val decode :
      'a t -> Fixture.Json.t -> ('env, [> `Decode of Fixture.issue list ], 'a) Effect.t

    val encode : 'a t -> 'a -> Fixture.Json.t
    val equal : 'a t -> 'a -> 'a -> bool
    val samples : 'a t -> 'a list
  end

  val config : Migration_fixture.config Schema.t
  val event : Migration_fixture.event Schema.t
  val menu : unit -> Migration_fixture.menu Schema.t

  val decode_config_with_policy :
    Fixture.Json.t ->
    (< feature_allowed : string -> bool ; .. >, [> `Decode of Fixture.issue list ], Migration_fixture.config)
    Effect.t

  val support : Migration_fixture.support
end

module _ : MIGRATION_SIG = struct
  module Schema = struct
    include Schema

    let encode t = t.encode
    let equal t = t.equal
    let samples t = t.samples
  end

  let config = config
  let event = event
  let menu = menu
  let decode_config_with_policy = decode_config_with_policy
  let support = support
end
