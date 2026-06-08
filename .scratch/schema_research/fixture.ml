module Json = struct
  type t =
    | Null
    | Bool of bool
    | Number of float
    | String of string
    | Array of t list
    | Object of (string * t) list

  let rec equal a b =
    match (a, b) with
    | Null, Null -> true
    | Bool a, Bool b -> Bool.equal a b
    | Number a, Number b -> Float.equal a b
    | String a, String b -> String.equal a b
    | Array a, Array b -> List.length a = List.length b && List.for_all2 equal a b
    | Object a, Object b ->
        let sort = List.sort (fun (a, _) (b, _) -> String.compare a b) in
        let a = sort a and b = sort b in
        List.length a = List.length b
        && List.for_all2
             (fun (ka, va) (kb, vb) -> String.equal ka kb && equal va vb)
             a b
    | _ -> false

  let object_ fields = Object fields
  let string s = String s
  let number n = Number (float_of_int n)
  let array xs = Array xs
  let bool b = Bool b

  let find key = function
    | Object fields -> List.assoc_opt key fields
    | _ -> None

  let rec to_string = function
    | Null -> "null"
    | Bool true -> "true"
    | Bool false -> "false"
    | Number n ->
        if Float.is_integer n then string_of_int (int_of_float n)
        else string_of_float n
    | String s -> Printf.sprintf "%S" s
    | Array xs -> "[" ^ String.concat ", " (List.map to_string xs) ^ "]"
    | Object fields ->
        let field (k, v) = Printf.sprintf "%S: %s" k (to_string v) in
        "{" ^ String.concat ", " (List.map field fields) ^ "}"
end

type issue = { path : string list; message : string }

let issue ?(path = []) message = { path; message }

let at key issues =
  List.map (fun i -> { i with path = key :: i.path }) issues

let render_issue issue =
  match List.rev issue.path with
  | [] -> issue.message
  | path -> issue.message ^ " at " ^ String.concat "." path

let render_issues issues = String.concat "; " (List.map render_issue issues)

type person = {
  name : string;
  age : int;
  email : string option;
  tags : string list;
}

let person_equal a b =
  String.equal a.name b.name
  && Int.equal a.age b.age
  && Option.equal String.equal a.email b.email
  && List.equal String.equal a.tags b.tags

let person_ok =
  {
    name = "Ada";
    age = 37;
    email = Some "ada@example.test";
    tags = [ "admin"; "founder" ];
  }

let person_ok_json =
  Json.object_
    [
      ("name", Json.string "Ada");
      ("age", Json.number 37);
      ("email", Json.string "ada@example.test");
      ("tags", Json.array [ Json.string "admin"; Json.string "founder" ]);
    ]

let person_no_email_json =
  Json.object_
    [
      ("name", Json.string "Ada");
      ("age", Json.number 37);
      ("tags", Json.array [ Json.string "admin" ]);
    ]

let person_bad_missing =
  Json.object_ [ ("age", Json.number 37); ("tags", Json.array []) ]

let person_bad_refinement =
  Json.object_
    [
      ("name", Json.string "");
      ("age", Json.number 151);
      ("tags", Json.array [ Json.string "admin" ]);
    ]

type color = Red | Green | Blue

let color_equal a b =
  match (a, b) with
  | Red, Red | Green, Green | Blue, Blue -> true
  | _ -> false

let color_to_string = function Red -> "red" | Green -> "green" | Blue -> "blue"

let color_of_string = function
  | "red" -> Ok Red
  | "green" -> Ok Green
  | "blue" -> Ok Blue
  | s -> Error [ issue ("Expected red | green | blue, got " ^ Json.to_string (Json.String s)) ]

let is_int_float n = Float.is_finite n && Float.equal n (Float.round n)

type support = {
  decode : bool;
  encode : bool;
  struct_ : bool;
  array : bool;
  union : bool;
  optional : bool;
  refinement : bool;
  branding : bool;
  transform : bool;
  effectful_decode : bool;
  json_schema : bool;
  arbitrary : bool;
  equivalence : bool;
  cause_integration : bool;
}

let full_support =
  {
    decode = true;
    encode = true;
    struct_ = true;
    array = true;
    union = true;
    optional = true;
    refinement = true;
    branding = true;
    transform = true;
    effectful_decode = true;
    json_schema = true;
    arbitrary = true;
    equivalence = true;
    cause_integration = true;
  }

let no_support =
  {
    decode = false;
    encode = false;
    struct_ = false;
    array = false;
    union = false;
    optional = false;
    refinement = false;
    branding = false;
    transform = false;
    effectful_decode = false;
    json_schema = false;
    arbitrary = false;
    equivalence = false;
    cause_integration = false;
  }

let count_supported s =
  [
    s.decode;
    s.encode;
    s.struct_;
    s.array;
    s.union;
    s.optional;
    s.refinement;
    s.branding;
    s.transform;
    s.effectful_decode;
    s.json_schema;
    s.arbitrary;
    s.equivalence;
    s.cause_integration;
  ]
  |> List.filter Fun.id |> List.length

let check_bool name b = if not b then failwith name

let check_json name expected actual =
  if not (Json.equal expected actual) then
    failwith
      (Printf.sprintf "%s: expected %s got %s" name (Json.to_string expected)
         (Json.to_string actual))

let check_person name expected actual =
  if not (person_equal expected actual) then failwith name
