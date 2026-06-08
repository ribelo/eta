open Fixture

module Brand : sig
  type ('a, 'brand) t

  val make : 'a -> ('a, 'brand) t
  val value : ('a, 'brand) t -> 'a
  val equal : ('a -> 'a -> bool) -> ('a, 'brand) t -> ('a, 'brand) t -> bool
end = struct
  type ('a, 'brand) t = Brand of 'a

  let make value = Brand value
  let value (Brand value) = value
  let equal eq a b = eq (value a) (value b)
end

type user_id_brand
type email_brand
type flag_key_brand

type user_id = (string, user_id_brand) Brand.t
type email = (string, email_brand) Brand.t
type flag_key = (string, flag_key_brand) Brand.t

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

let user_id s = Brand.make s
let email s = Brand.make s
let flag_key s = Brand.make s

let role_equal a b =
  match (a, b) with
  | Admin, Admin | Analyst, Analyst | Viewer, Viewer -> true
  | _ -> false

let role_to_string = function
  | Admin -> "admin"
  | Analyst -> "analyst"
  | Viewer -> "viewer"

let role_of_string = function
  | "admin" -> Ok Admin
  | "analyst" -> Ok Analyst
  | "viewer" -> Ok Viewer
  | s -> Error [ issue ("Expected admin | analyst | viewer, got " ^ Json.to_string (Json.String s)) ]

let user_equal a b =
  Brand.equal String.equal a.id b.id
  && String.equal a.name b.name
  && Option.equal (Brand.equal String.equal) a.email b.email
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
  Brand.equal String.equal a.key b.key
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
      Brand.equal String.equal a.key b.key && Bool.equal a.enabled b.enabled
  | Metric a, Metric b -> String.equal a.name b.name && Float.equal a.value b.value
  | _ -> false

let rec menu_equal a b =
  match (a, b) with
  | Item a, Item b -> String.equal a.label b.label && String.equal a.route b.route
  | Group a, Group b ->
      String.equal a.label b.label && List.equal menu_equal a.children b.children
  | _ -> false

let sample_user =
  {
    id = user_id "usr_123";
    name = "Ada";
    email = Some (email "ada@example.test");
    roles = [ Admin; Analyst ];
  }

let sample_config =
  {
    service = "billing";
    db = { host = "db.internal"; port = 5432; ssl = true };
    auth = OAuth { issuer = "https://issuer.example"; client_id = "billing-web" };
    users = [ sample_user ];
    features =
      [
        { key = flag_key "flag.new-checkout"; enabled = true; rollout = Some 25 };
      ];
    retry_after_ms = 500;
  }

let sample_event = User_created sample_user

let sample_menu =
  Group
    {
      label = "root";
      children =
        [
          Item { label = "Home"; route = "/" };
          Group
            {
              label = "Admin";
              children = [ Item { label = "Users"; route = "/admin/users" } ];
            };
        ];
    }

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
            ("port", Json.number 5432);
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
                ("rollout", Json.number 25);
              ];
          ] );
      ("retryAfter", Json.string "500ms");
    ]

let bad_config_many_issues_json =
  Json.object_
    [
      ("service", Json.string "");
      ( "db",
        Json.object_
          [
            ("host", Json.string "");
            ("port", Json.number 70000);
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
                ("rollout", Json.number 200);
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

type support = {
  brands : bool;
  nested_records : bool;
  tagged_unions : bool;
  recursive : bool;
  transforms : bool;
  all_errors : bool;
  effect_policy : bool;
  json_schema : bool;
  arbitrary : bool;
  equivalence : bool;
  no_weak_env_values : bool;
}

let count_support s =
  [
    s.brands;
    s.nested_records;
    s.tagged_unions;
    s.recursive;
    s.transforms;
    s.all_errors;
    s.effect_policy;
    s.json_schema;
    s.arbitrary;
    s.equivalence;
    s.no_weak_env_values;
  ]
  |> List.filter Fun.id |> List.length

let full_support =
  {
    brands = true;
    nested_records = true;
    tagged_unions = true;
    recursive = true;
    transforms = true;
    all_errors = true;
    effect_policy = true;
    json_schema = true;
    arbitrary = true;
    equivalence = true;
    no_weak_env_values = true;
  }
