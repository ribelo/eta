open Eta_schema

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
    ~equal:Int.equal
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
        | Error issues -> Error (at_field "minLength" issues))
    | None -> Error [ issue ~path:[ Field "minLength" ] "Missing key" ]
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
            Error (at_field "issuer" (collect a) @ at_field "clientId" (collect b)))
    | _ -> Error [ issue "Invalid OAuth auth" ]
  in
  let password_encode = function
    | Password { min_length } ->
        Ok (Some (Json.object_ [ ("minLength", Json.int min_length) ]))
    | _ -> Ok None
  in
  let oauth_encode = function
    | OAuth { issuer; client_id } ->
        Ok (Some
          (Json.object_
             [ ("issuer", Json.string issuer); ("clientId", Json.string client_id) ]))
    | _ -> Ok None
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
    | None -> Error [ issue ~path:[ Field "user" ] "Missing key" ]
  in
  let user_created_encode = function
    | User_created u ->
        Result.map
          (fun user_json -> Some (Json.object_ [ ("user", user_json) ]))
          (Schema.encode_result user u)
    | _ -> Ok None
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
            Error (at_field "key" (collect a) @ at_field "enabled" (collect b)))
    | _ -> Error [ issue "Invalid FeatureToggled event" ]
  in
  let feature_toggled_encode = function
    | Feature_toggled { key; enabled } ->
        Result.map
          (fun key_json ->
            Some (Json.object_ [ ("key", key_json); ("enabled", Json.bool enabled) ]))
          (Schema.encode_result Flag_key.schema key)
    | _ -> Ok None
  in
  let metric_decode json =
    match (Json.find "name" json, Json.find "value" json) with
    | Some (Json.String name), Some value_json -> (
        match Schema.decode_result Schema.float value_json with
        | Ok value -> Ok (Metric { name; value })
        | Error issues -> Error (at_field "value" issues))
    | _ -> Error [ issue "Invalid Metric event" ]
  in
  let metric_encode = function
    | Metric { name; value } ->
        Ok
          (Some
             (Json.object_ [ ("name", Json.string name); ("value", Json.number value) ]))
    | _ -> Ok None
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
        Ok (Some (Json.object_ [ ("label", Json.string label); ("route", Json.string route) ]))
    | _ -> Ok None
  in
  let group_decode json =
    match (Json.find "label" json, Json.find "children" json) with
    | Some (Json.String label), Some children_json -> (
        match Schema.decode_result (Schema.array (Schema.lazy_ menu)) children_json with
        | Ok children -> Ok (Group { label; children })
        | Error issues -> Error (at_field "children" issues))
    | _ -> Error [ issue "Invalid menu group" ]
  in
  let group_encode = function
    | Group { label; children } ->
        Result.map
          (fun children_json ->
            Some
              (Json.object_
                 [ ("label", Json.string label); ("children", children_json) ]))
          (Schema.encode_result (Schema.array (Schema.lazy_ menu)) children)
    | _ -> Ok None
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

let rec eval : type err a. (a, err) Eta.Effect.t -> (a, err) result =
 fun eff ->
  match Eta.Effect.Private.view eff with
  | Eta.Effect.Private.Pure value -> Ok value
  | Eta.Effect.Private.Fail error -> Error error
  | Eta.Effect.Private.Sync (_, f) -> Ok (f ())
  | Eta.Effect.Private.Map (inner, f) -> Result.map f (eval inner)
  | Eta.Effect.Private.Bind (inner, f) -> (
      match eval inner with Ok value -> eval (f value) | Error error -> Error error)
  | Eta.Effect.Private.Catch (inner, f) -> (
      match eval inner with Ok value -> Ok value | Error error -> eval (f error))
  | Eta.Effect.Private.Tap_error (inner, f) -> (
      match eval inner with
      | Ok value -> Ok value
      | Error error ->
          f error;
          Error error)
  | Eta.Effect.Private.Named (_, _, inner)
  | Eta.Effect.Private.Annotate (_, _, inner)
  | Eta.Effect.Private.Link_span (_, inner)
  | Eta.Effect.Private.With_external_parent (_, inner)
  | Eta.Effect.Private.With_context (_, inner) ->
      eval inner
  | Eta.Effect.Private.Current_context -> Ok None
  | _ -> failwith "test evaluator only supports the schema effect subset"

let run_effect eff = eval eff

let expect_ok name = function
  | Ok value -> value
  | Error (`Decode issues) -> failwith (Printf.sprintf "%s: %s" name (render_issues issues))
  | Error (`Encode issues) -> failwith (Printf.sprintf "%s: %s" name (render_issues issues))

let expect_decode_error name = function
  | Ok _ -> failwith (name ^ ": expected decode failure")
  | Error (`Decode issues) -> issues
  | Error (`Encode _) -> failwith (name ^ ": expected decode failure, got encode failure")

let expect_encode_error name = function
  | Ok _ -> failwith (name ^ ": expected encode failure")
  | Error (`Encode issues) -> issues
  | Error (`Decode _) -> failwith (name ^ ": expected encode failure, got decode failure")

let decode_ok schema json = run_effect (Schema.decode schema json) |> expect_ok "decode"
let encode_ok schema value = run_effect (Schema.encode schema value) |> expect_ok "encode"

let check_bool name value = if not value then failwith name
let check_int name expected actual = if expected <> actual then failwith name
let check_string name expected actual = if not (String.equal expected actual) then failwith name

let check_option_string name expected actual =
  match (expected, actual) with
  | None, None -> ()
  | Some expected, Some actual when String.equal expected actual -> ()
  | _ -> failwith name

let test_config_roundtrip () =
  let decoded = decode_ok config sample_config_json in
  check_bool "retry transform" (decoded.retry_after_ms = 500);
  check_bool "feature key value"
    (String.equal "flag.new-checkout" (Flag_key.value (List.hd decoded.features).key));
  check_bool "roundtrip json"
    (Json.equal sample_config_json (encode_ok config decoded));
  check_bool "self equal" (Schema.equal config decoded decoded)

let test_many_issues () =
  let issues = run_effect (Schema.decode config bad_config_json) |> expect_decode_error "bad config" in
  check_bool "all errors" (List.length issues >= 8);
  check_bool "nested user id path"
    (List.exists (fun issue -> issue.path = [ Field "users"; Index 0; Field "id" ]) issues)

let test_tagged_and_recursive () =
  let event_value = decode_ok event sample_event_json in
  check_bool "event self equal" (Schema.equal event event_value event_value);
  check_bool "event roundtrip"
    (Json.equal sample_event_json (encode_ok event event_value));
  let menu_value = decode_ok (menu ()) sample_menu_json in
  check_bool "menu self equal" (Schema.equal (menu ()) menu_value menu_value);
  check_bool "menu roundtrip"
    (Json.equal sample_menu_json (encode_ok (menu ()) menu_value))

let test_policy_closure_deps () =
  let feature_allowed key = String.equal key "flag.new-checkout" in
  let policy config =
    let open Eta in
    Effect.bind
      (fun allowed ->
        if allowed then Effect.pure config
        else Effect.fail (`Decode [ issue "feature policy rejected config" ]))
      (Effect.sync "feature-policy" (fun () ->
           List.for_all
             (fun feature -> feature_allowed (Flag_key.value feature.key))
             config.features))
  in
  let accepted =
    run_effect (Schema.decode_with_policy config policy sample_config_json)
    |> expect_ok "policy accepted"
  in
  check_bool "policy decoded" (Schema.equal config accepted accepted);
  let feature_allowed _ = false in
  let policy config =
    let open Eta in
    Effect.bind
      (fun allowed ->
        if allowed then Effect.pure config
        else Effect.fail (`Decode [ issue "feature policy rejected config" ]))
      (Effect.sync "feature-policy" (fun () ->
           List.for_all
             (fun feature -> feature_allowed (Flag_key.value feature.key))
             config.features))
  in
  let issues =
    run_effect (Schema.decode_with_policy config policy sample_config_json)
    |> expect_decode_error "policy rejected"
  in
  check_int "policy issue count" 1 (List.length issues)

let test_cause_integration () =
  let seen = ref 0 in
  let program =
    Schema.decode config bad_config_json
    |> Eta.Effect.map (fun _ -> 0)
    |> Eta.Effect.tap_error (function `Decode issues -> seen := List.length issues)
    |> Eta.Effect.catch (function
         | `Decode issues -> Eta.Effect.pure (List.length issues))
  in
  let recovered = run_effect program |> expect_ok "catch decode" in
  check_bool "tap saw issues" (!seen >= 8);
  check_bool "catch recovered" (recovered >= 8)

let test_issue_paths_distinguish_fields_and_indexes () =
  let issues = run_effect (Schema.decode config bad_config_json) |> expect_decode_error "bad config" in
  let user_id_issue =
    match
      List.find_opt
        (fun issue -> issue.path = [ Field "users"; Index 0; Field "id" ])
        issues
    with
    | Some issue -> issue
    | None -> failwith "expected nested user id issue"
  in
  check_string "rendered path" "user_id: Expected user_id at users[0].id"
    (render_issue user_id_issue);
  check_option_string "source schema" (Some "user_id") user_id_issue.schema_name;
  (match user_id_issue.kind with
  | Custom message -> check_string "custom issue" "Expected user_id" message
  | _ -> failwith "expected custom issue");
  check_string "json pointer" "/users/0/id" (issue_to_json_pointer user_id_issue);
  let numeric_key_issue =
    issue ~path:[ Field "users"; Field "0"; Field "id" ] "field key"
  in
  check_string "numeric field path" "field key at users.0.id"
    (render_issue numeric_key_issue)

type named_name = { name : string }

let named_name_equal a b = String.equal a.name b.name

let named_schema schema_name =
  Schema.record1 ~name:schema_name
    (fun name -> { name })
    (Schema.required "name" Schema.string (fun value -> value.name))
    ~equal:named_name_equal ()

let test_issue_source_discriminator () =
  let json = Json.object_ [ ("name", Json.int 42) ] in
  let user_issues =
    run_effect (Schema.decode (named_schema "user") json) |> expect_decode_error "user"
  in
  let admin_issues =
    run_effect (Schema.decode (named_schema "admin") json) |> expect_decode_error "admin"
  in
  let user_issue = List.hd user_issues in
  let admin_issue = List.hd admin_issues in
  check_option_string "user source" (Some "user") user_issue.schema_name;
  check_option_string "admin source" (Some "admin") admin_issue.schema_name;
  (match user_issue.kind with
  | Type_mismatch { expected; got } ->
      check_string "expected string" "string" expected;
      check_string "got int" "42" got
  | _ -> failwith "expected type mismatch");
  check_string "source render" "user: Expected string, got 42 at name"
    (render_issue user_issue)

let test_json_number_rendering () =
  check_string "integer float has no trailing dot" "1" (Json.to_string (Json.number 1.));
  check_string "fractional float" "1.5" (Json.to_string (Json.number 1.5));
  check_string "large integral float does not overflow" "1e+100"
    (Json.to_string (Json.number 1e100));
  check_string "large int literal stays exact" "9007199254740993"
    (Json.to_string (Json.intlit "9007199254740993"));
  ignore
    (run_effect (Schema.decode Schema.int (Json.number 1e100))
    |> expect_decode_error "large integer")

type request_user = { request_id : user_id }
type canonical_user = { canonical_id : user_id; canonical_name : string }

let request_user_equal a b = User_id.equal a.request_id b.request_id

let request_user_schema =
  Schema.record1 ~name:"request_user"
    (fun request_id -> { request_id })
    (Schema.required "id" User_id.schema (fun u -> u.request_id))
    ~equal:request_user_equal ()

type external_json =
  | XNull
  | XBool of bool
  | XInt of int
  | XIntlit of string
  | XFloat of float
  | XString of string
  | XArray of external_json list
  | XObject of (string * external_json) list
  | XBad of string

module Test_adapter = struct
  type nonrec external_json = external_json

  let rec of_external = function
    | XNull -> Ok Json.Null
    | XBool value -> Ok (Json.bool value)
    | XInt value -> Ok (Json.int value)
    | XIntlit value -> Ok (Json.intlit value)
    | XFloat value -> Ok (Json.number value)
    | XString value -> Ok (Json.string value)
    | XArray values ->
        values
        |> List.fold_left
             (fun acc value ->
               match (acc, of_external value) with
               | Ok values, Ok json -> Ok (json :: values)
               | Error issues, Ok _ -> Error issues
               | Ok _, Error issues -> Error issues
               | Error a, Error b -> Error (a @ b))
             (Ok [])
        |> Result.map (fun values -> Json.Array (List.rev values))
    | XObject fields ->
        fields
        |> List.fold_left
             (fun acc (key, value) ->
               match (acc, of_external value) with
               | Ok fields, Ok json -> Ok ((key, json) :: fields)
               | Error issues, Ok _ -> Error issues
               | Ok _, Error issues -> Error issues
               | Error a, Error b -> Error (a @ b))
             (Ok [])
        |> Result.map (fun fields -> Json.Object (List.rev fields))
    | XBad message -> Error [ issue ~schema_name:"test-adapter" message ]

  let rec to_external = function
    | Json.Null -> XNull
    | Json.Bool value -> XBool value
    | Json.Number (Json.Int value) -> XInt value
    | Json.Number (Json.Intlit value) -> XIntlit value
    | Json.Number (Json.Float value) -> XFloat value
    | Json.String value -> XString value
    | Json.Array values -> XArray (List.map to_external values)
    | Json.Object fields ->
        XObject (List.map (fun (key, value) -> (key, to_external value)) fields)
end

module Test_codec = Make (Test_adapter)

let test_decode_with_policy_enriches_type () =
  let lookup_user _ = "Ada" in
  let policy request =
    let open Eta in
    Effect.map
      (fun canonical_name -> { canonical_id = request.request_id; canonical_name })
      (Effect.sync "lookup-user" (fun () -> lookup_user (User_id.value request.request_id)))
  in
  let json = Json.object_ [ ("id", Json.string "usr_999") ] in
  let enriched =
    run_effect (Schema.decode_with_policy request_user_schema policy json)
    |> expect_ok "policy enriched"
  in
  check_string "enriched name" "Ada" enriched.canonical_name

let test_json_adapter_make_functor () =
  let external_json = XObject [ ("id", XString "usr_999") ] in
  let decoded =
    run_effect (Test_codec.decode request_user_schema external_json)
    |> expect_ok "adapter decode"
  in
  check_string "adapter decoded" "usr_999" (User_id.value decoded.request_id);
  let encoded =
    run_effect (Test_codec.encode request_user_schema decoded)
    |> expect_ok "adapter encode"
  in
  (match encoded with
  | XObject [ ("id", XString "usr_999") ] -> ()
  | _ -> failwith "unexpected adapter encode");
  let issues =
    run_effect (Test_codec.decode request_user_schema (XBad "bad external json"))
    |> expect_decode_error "adapter decode failure"
  in
  let issue = List.hd issues in
  check_option_string "adapter source" (Some "test-adapter") issue.schema_name;
  (match issue.kind with
  | Custom message -> check_string "adapter issue" "bad external json" message
  | _ -> failwith "expected adapter custom issue")

let test_encode_failures_are_typed () =
  let one = Schema.enum ~name:"one" [ ("one", 1) ] ~equal:Int.equal in
  let enum_issues = run_effect (Schema.encode one 2) |> expect_encode_error "enum" in
  check_int "enum issue count" 1 (List.length enum_issues);
  let password_only =
    let decode _ = Error [ issue "unused" ] in
    let encode = function
      | Password { min_length } ->
          Ok (Some (Json.object_ [ ("minLength", Json.int min_length) ]))
      | _ -> Ok None
    in
    Schema.tagged_union ~name:"password_only" ~tag:"_tag"
      [ Schema.case ~tag:"Password" ~decode ~encode ] ~equal:auth_equal
  in
  let union_issues =
    run_effect (Schema.encode password_only (OAuth { issuer = "i"; client_id = "c" }))
    |> expect_encode_error "tagged union"
  in
  check_int "tagged union issue count" 1 (List.length union_issues)

let test_lazy_schema_memoizes_thunk () =
  let forced = ref 0 in
  let schema =
    Schema.lazy_ (fun () ->
        incr forced;
        Schema.string)
  in
  ignore (Schema.decode_result schema (Json.string "x") : (string, issue list) result);
  ignore (Schema.encode_result schema "x" : (json, issue list) result);
  check_bool "lazy equal" (Schema.equal schema "x" "x");
  check_int "lazy forced once" 1 !forced

let () =
  test_config_roundtrip ();
  test_many_issues ();
  test_tagged_and_recursive ();
  test_policy_closure_deps ();
  test_cause_integration ();
  test_issue_paths_distinguish_fields_and_indexes ();
  test_issue_source_discriminator ();
  test_json_number_rendering ();
  test_decode_with_policy_enriches_type ();
  test_json_adapter_make_functor ();
  test_encode_failures_are_typed ();
  test_lazy_schema_memoizes_thunk ();
  print_endline "eta-schema tests passed"
