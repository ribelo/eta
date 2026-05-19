open Effet_schema

module User_id : sig
  type t = private string

  val schema : t Schema.t
  val value : t -> string
  val equal : t -> t -> bool
end = struct
  type t = string

  let valid s = String.length s > 4 && String.sub s 0 4 = "usr_"
  let value s = s
  let equal = String.equal

  let schema =
    Schema.transform ~name:"user_id"
      ~decode:(fun s ->
        if valid s then Ok s else Error [ issue "Expected user_id" ])
      ~encode:value ~equal Schema.string
end

module Email : sig
  type t = private string

  val schema : t Schema.t
  val value : t -> string
  val equal : t -> t -> bool
end = struct
  type t = string

  let valid s = String.contains s '@'
  let value s = s
  let equal = String.equal

  let schema =
    Schema.transform ~name:"email"
      ~decode:(fun s -> if valid s then Ok s else Error [ issue "Expected email" ])
      ~encode:value ~equal Schema.string
end

module Flag_key : sig
  type t = private string

  val schema : t Schema.t
  val value : t -> string
  val equal : t -> t -> bool
end = struct
  type t = string

  let valid s = String.length s > 5 && String.sub s 0 5 = "flag."
  let value s = s
  let equal = String.equal

  let schema =
    Schema.transform ~name:"flag_key"
      ~decode:(fun s ->
        if valid s then Ok s else Error [ issue "Expected flag_key" ])
      ~encode:value ~equal Schema.string
end

type user_id = User_id.t
type email = Email.t
type flag_key = Flag_key.t

type role = Admin | Analyst | Viewer

type user = {
  id : user_id;
  name : string;
  email : email option;
  roles : role list;
}

type database = {
  host : string;
  port : int;
  ssl : bool;
}

type auth =
  | Password of { min_length : int }
  | OAuth of {
      issuer : string;
      client_id : string;
    }

type feature = {
  key : flag_key;
  enabled : bool;
  rollout : int option;
}

type config = {
  service : string;
  db : database;
  auth : auth;
  users : user list;
  features : feature list;
  retry_after_ms : int;
}

type event =
  | User_created of user
  | Feature_toggled of {
      key : flag_key;
      enabled : bool;
    }
  | Metric of {
      name : string;
      value : float;
    }

type menu =
  | Item of {
      label : string;
      route : string;
    }
  | Group of {
      label : string;
      children : menu list;
    }

let role_equal a b =
  match (a, b) with
  | Admin, Admin | Analyst, Analyst | Viewer, Viewer -> true
  | _ -> false

let user_equal a b =
  User_id.equal a.id b.id
  && String.equal a.name b.name
  && Option.equal Email.equal a.email b.email
  && List.equal role_equal a.roles b.roles

let database_equal a b =
  String.equal a.host b.host && Int.equal a.port b.port && Bool.equal a.ssl b.ssl

let auth_equal a b =
  match (a, b) with
  | Password a, Password b -> Int.equal a.min_length b.min_length
  | OAuth a, OAuth b ->
      String.equal a.issuer b.issuer && String.equal a.client_id b.client_id
  | _ -> false

let feature_equal a b =
  Flag_key.equal a.key b.key
  && Bool.equal a.enabled b.enabled
  && Option.equal Int.equal a.rollout b.rollout

let config_equal a b =
  String.equal a.service b.service
  && database_equal a.db b.db
  && auth_equal a.auth b.auth
  && List.equal user_equal a.users b.users
  && List.equal feature_equal a.features b.features
  && Int.equal a.retry_after_ms b.retry_after_ms

let event_equal a b =
  match (a, b) with
  | User_created a, User_created b -> user_equal a b
  | Feature_toggled a, Feature_toggled b ->
      Flag_key.equal a.key b.key && Bool.equal a.enabled b.enabled
  | Metric a, Metric b -> String.equal a.name b.name && Float.equal a.value b.value
  | _ -> false

let rec menu_equal a b =
  match (a, b) with
  | Item a, Item b -> String.equal a.label b.label && String.equal a.route b.route
  | Group a, Group b ->
      String.equal a.label b.label && List.equal menu_equal a.children b.children
  | _ -> false

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

let role =
  Schema.enum ~name:"role"
    [ ("admin", Admin); ("analyst", Analyst); ("viewer", Viewer) ]
    ~equal:role_equal

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
    ~equal:database_equal ()

let user =
  Schema.record4 ~name:"user"
    (fun id name email roles -> { id; name; email; roles })
    (Schema.required "id" User_id.schema (fun u -> u.id))
    (Schema.required "name" non_empty (fun u -> u.name))
    (Schema.optional "email" Email.schema (fun u -> u.email))
    (Schema.required "roles" (Schema.array role) (fun u -> u.roles))
    ~equal:user_equal ()

let feature =
  Schema.record3 ~name:"feature"
    (fun key enabled rollout -> { key; enabled; rollout })
    (Schema.required "key" Flag_key.schema (fun f -> f.key))
    (Schema.required "enabled" Schema.bool (fun f -> f.enabled))
    (Schema.optional "rollout" (bounded_int ~min:0 ~max:100) (fun f -> f.rollout))
    ~equal:feature_equal ()

let auth =
  let password_decode json =
    match Json.find "minLength" json with
    | Some value -> (
        match Schema.decode_result (bounded_int ~min:8 ~max:128) value with
        | Ok min_length -> Ok (Password { min_length })
        | Error issues -> Error (at "minLength" issues))
    | None -> Error [ issue ~path:[ "minLength" ] "Missing key" ]
  in
  let oauth_decode json =
    match (Json.find "issuer" json, Json.find "clientId" json) with
    | Some issuer_json, Some client_json -> (
        match
          ( Schema.decode_result non_empty issuer_json,
            Schema.decode_result non_empty client_json )
        with
        | Ok issuer, Ok client_id -> Ok (OAuth { issuer; client_id })
        | a, b ->
            let collect = function Ok _ -> [] | Error issues -> issues in
            Error (at "issuer" (collect a) @ at "clientId" (collect b)))
    | _ -> Error [ issue "Invalid OAuth auth" ]
  in
  let password_encode = function
    | Password { min_length } ->
        Some (Json.object_ [ ("minLength", Json.int min_length) ])
    | _ -> None
  in
  let oauth_encode = function
    | OAuth { issuer; client_id } ->
        Some
          (Json.object_
             [ ("issuer", Json.string issuer); ("clientId", Json.string client_id) ])
    | _ -> None
  in
  Schema.tagged_union ~name:"auth" ~tag:"_tag"
    [
      Schema.case ~tag:"Password" ~decode:password_decode ~encode:password_encode;
      Schema.case ~tag:"OAuth" ~decode:oauth_decode ~encode:oauth_encode;
    ]
    ~equal:auth_equal

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
    ~equal:config_equal ()

let event =
  let user_created_decode json =
    match Json.find "user" json with
    | Some value -> Result.map (fun user -> User_created user) (Schema.decode_result user value)
    | None -> Error [ issue ~path:[ "user" ] "Missing key" ]
  in
  let user_created_encode = function
    | User_created u -> Some (Json.object_ [ ("user", Schema.encode user u) ])
    | _ -> None
  in
  let feature_toggled_decode json =
    match (Json.find "key" json, Json.find "enabled" json) with
    | Some key_json, Some enabled_json -> (
        match
          ( Schema.decode_result Flag_key.schema key_json,
            Schema.decode_result Schema.bool enabled_json )
        with
        | Ok key, Ok enabled -> Ok (Feature_toggled { key; enabled })
        | a, b ->
            let collect = function Ok _ -> [] | Error issues -> issues in
            Error (at "key" (collect a) @ at "enabled" (collect b)))
    | _ -> Error [ issue "Invalid FeatureToggled event" ]
  in
  let feature_toggled_encode = function
    | Feature_toggled { key; enabled } ->
        Some
          (Json.object_
             [ ("key", Schema.encode Flag_key.schema key); ("enabled", Json.bool enabled) ])
    | _ -> None
  in
  let metric_decode json =
    match (Json.find "name" json, Json.find "value" json) with
    | Some (Json.String name), Some (Json.Number value) -> Ok (Metric { name; value })
    | _ -> Error [ issue "Invalid Metric event" ]
  in
  let metric_encode = function
    | Metric { name; value } ->
        Some (Json.object_ [ ("name", Json.string name); ("value", Json.number value) ])
    | _ -> None
  in
  Schema.tagged_union ~name:"event" ~tag:"_tag"
    [
      Schema.case ~tag:"UserCreated" ~decode:user_created_decode ~encode:user_created_encode;
      Schema.case ~tag:"FeatureToggled" ~decode:feature_toggled_decode
        ~encode:feature_toggled_encode;
      Schema.case ~tag:"Metric" ~decode:metric_decode ~encode:metric_encode;
    ]
    ~equal:event_equal

let rec menu () =
  let item_decode json =
    match (Json.find "label" json, Json.find "route" json) with
    | Some (Json.String label), Some (Json.String route) -> Ok (Item { label; route })
    | _ -> Error [ issue "Invalid menu item" ]
  in
  let item_encode = function
    | Item { label; route } ->
        Some (Json.object_ [ ("label", Json.string label); ("route", Json.string route) ])
    | _ -> None
  in
  let group_decode json =
    match (Json.find "label" json, Json.find "children" json) with
    | Some (Json.String label), Some children_json -> (
        match Schema.decode_result (Schema.array (Schema.lazy_ menu)) children_json with
        | Ok children -> Ok (Group { label; children })
        | Error issues -> Error (at "children" issues))
    | _ -> Error [ issue "Invalid menu group" ]
  in
  let group_encode = function
    | Group { label; children } ->
        Some
          (Json.object_
             [
               ("label", Json.string label);
               ("children", Schema.encode (Schema.array (Schema.lazy_ menu)) children);
             ])
    | _ -> None
  in
  Schema.tagged_union ~name:"menu" ~tag:"_tag"
    [
      Schema.case ~tag:"Item" ~decode:item_decode ~encode:item_encode;
      Schema.case ~tag:"Group" ~decode:group_decode ~encode:group_encode;
    ]
    ~equal:menu_equal

let sample_user_json =
  Json.object_
    [
      ("id", Json.string "usr_123");
      ("name", Json.string "Ada");
      ("email", Json.string "ada@example.test");
      ("roles", Json.array [ Json.string "admin"; Json.string "analyst" ]);
    ]

let sample_config_json =
  Json.object_
    [
      ("service", Json.string "billing");
      ( "db",
        Json.object_
          [
            ("host", Json.string "db.internal");
            ("port", Json.int 5432);
            ("ssl", Json.bool true);
          ] );
      ( "auth",
        Json.object_
          [
            ("_tag", Json.string "OAuth");
            ("issuer", Json.string "https://issuer.example");
            ("clientId", Json.string "billing-web");
          ] );
      ("users", Json.array [ sample_user_json ]);
      ( "features",
        Json.array
          [
            Json.object_
              [
                ("key", Json.string "flag.new-checkout");
                ("enabled", Json.bool true);
                ("rollout", Json.int 25);
              ];
          ] );
      ("retryAfter", Json.string "500ms");
    ]

let bad_config_json =
  Json.object_
    [
      ("service", Json.string "");
      ( "db",
        Json.object_
          [
            ("host", Json.string "");
            ("port", Json.int 70000);
            ("ssl", Json.string "yes");
          ] );
      ("auth", Json.object_ [ ("_tag", Json.string "Unknown") ]);
      ("users", Json.array [ Json.object_ [ ("id", Json.string "bad") ] ]);
      ( "features",
        Json.array
          [
            Json.object_
              [
                ("key", Json.string "bad");
                ("enabled", Json.bool true);
                ("rollout", Json.int 200);
              ];
          ] );
      ("retryAfter", Json.string "soon");
    ]

let sample_event_json =
  Json.object_ [ ("_tag", Json.string "UserCreated"); ("user", sample_user_json) ]

let sample_menu_json =
  Json.object_
    [
      ("_tag", Json.string "Group");
      ("label", Json.string "root");
      ( "children",
        Json.array
          [
            Json.object_
              [
                ("_tag", Json.string "Item");
                ("label", Json.string "Home");
                ("route", Json.string "/");
              ];
            Json.object_
              [
                ("_tag", Json.string "Group");
                ("label", Json.string "Admin");
                ( "children",
                  Json.array
                    [
                      Json.object_
                        [
                          ("_tag", Json.string "Item");
                          ("label", Json.string "Users");
                          ("route", Json.string "/admin/users");
                        ];
                    ] );
              ];
          ] );
    ]

let rec eval : type env err a. env -> (env, err, a) Effet.Effect.t -> (a, err) result =
 fun env eff ->
  match Effet.Effect.Private.view eff with
  | Effet.Effect.Private.Pure value -> Ok value
  | Effet.Effect.Private.Fail error -> Error error
  | Effet.Effect.Private.Sync (_, f) | Effet.Effect.Private.Async (_, f) -> Ok (f env)
  | Effet.Effect.Private.Map (inner, f) -> Result.map f (eval env inner)
  | Effet.Effect.Private.Bind (inner, f) -> (
      match eval env inner with Ok value -> eval env (f value) | Error error -> Error error)
  | Effet.Effect.Private.Catch (inner, f) -> (
      match eval env inner with Ok value -> Ok value | Error error -> eval env (f error))
  | Effet.Effect.Private.Tap_error (inner, f) -> (
      match eval env inner with
      | Ok value -> Ok value
      | Error error ->
          f error;
          Error error)
  | Effet.Effect.Private.Provide (env, inner) -> eval env inner
  | Effet.Effect.Private.Named (_, _, inner)
  | Effet.Effect.Private.Annotate (_, _, inner)
  | Effet.Effect.Private.Link_span (_, inner)
  | Effet.Effect.Private.With_external_parent (_, _, inner) ->
      eval env inner
  | _ -> failwith "test evaluator only supports the schema effect subset"

let run_effect eff = eval (object end) eff
let run_effect_env env eff = eval env eff

let expect_ok name = function
  | Ok value -> value
  | Error (`Decode issues) -> failwith (Printf.sprintf "%s: %s" name (render_issues issues))

let expect_decode_error name = function
  | Ok _ -> failwith (name ^ ": expected decode failure")
  | Error (`Decode issues) -> issues

let decode_ok schema json = run_effect (Schema.decode schema json) |> expect_ok "decode"

let check_bool name value = if not value then failwith name
let check_int name expected actual = if expected <> actual then failwith name

let test_config_roundtrip () =
  let decoded = decode_ok config sample_config_json in
  check_bool "retry transform" (decoded.retry_after_ms = 500);
  check_bool "feature key value"
    (String.equal "flag.new-checkout" (Flag_key.value (List.hd decoded.features).key));
  check_bool "roundtrip json"
    (Json.equal sample_config_json (Schema.encode config decoded));
  check_bool "self equal" (Schema.equal config decoded decoded)

let test_many_issues () =
  let issues = run_effect (Schema.decode config bad_config_json) |> expect_decode_error "bad config" in
  check_bool "all errors" (List.length issues >= 8);
  check_bool "nested user id path"
    (List.exists (fun issue -> issue.path = [ "users"; "0"; "id" ]) issues)

let test_tagged_and_recursive () =
  let event_value = decode_ok event sample_event_json in
  check_bool "event self equal" (Schema.equal event event_value event_value);
  check_bool "event roundtrip"
    (Json.equal sample_event_json (Schema.encode event event_value));
  let menu_value = decode_ok (menu ()) sample_menu_json in
  check_bool "menu self equal" (Schema.equal (menu ()) menu_value menu_value);
  check_bool "menu roundtrip"
    (Json.equal sample_menu_json (Schema.encode (menu ()) menu_value))

let test_policy_env_row () =
  let policy config =
    let open Effet in
    Effect.bind
      (fun allowed ->
        if allowed then Effect.pure config
        else Effect.fail (`Decode [ issue "feature policy rejected config" ]))
      (Effect.sync "feature-policy" (fun env ->
           List.for_all
             (fun feature -> env#feature_allowed (Flag_key.value feature.key))
             config.features))
  in
  let env = object method feature_allowed key = String.equal key "flag.new-checkout" end in
  let accepted =
    run_effect_env env (Schema.decode_with_policy config policy sample_config_json)
    |> expect_ok "policy accepted"
  in
  check_bool "policy decoded" (Schema.equal config accepted accepted);
  let env = object method feature_allowed _ = false end in
  let issues =
    run_effect_env env (Schema.decode_with_policy config policy sample_config_json)
    |> expect_decode_error "policy rejected"
  in
  check_int "policy issue count" 1 (List.length issues)

let test_cause_integration () =
  let seen = ref 0 in
  let program =
    Schema.decode config bad_config_json
    |> Effet.Effect.map (fun _ -> 0)
    |> Effet.Effect.tap_error (function `Decode issues -> seen := List.length issues)
    |> Effet.Effect.catch (function
         | `Decode issues -> Effet.Effect.pure (List.length issues))
  in
  let recovered = run_effect program |> expect_ok "catch decode" in
  check_bool "tap saw issues" (!seen >= 8);
  check_bool "catch recovered" (recovered >= 8)

let test_json_schema () =
  match Schema.json_schema config with
  | Json.Object fields ->
      check_bool "has title" (List.mem_assoc "title" fields)
  | _ -> failwith "expected object schema"

let () =
  test_config_roundtrip ();
  test_many_issues ();
  test_tagged_and_recursive ();
  test_policy_env_row ();
  test_cause_integration ();
  test_json_schema ();
  print_endline "effet-schema tests passed"
