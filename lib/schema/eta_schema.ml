module Json = struct
  type number =
    | Int of int
    | Intlit of string
    | Float of float

  type t =
    | Null
    | Bool of bool
    | Number of number
    | String of string
    | Array of t list
    | Object of (string * t) list

  let null = Null
  let bool value = Bool value
  let number value = Number (Float value)
  let int value = Number (Int value)

  let is_digit c = c >= '0' && c <= '9'

  let is_json_number_literal s =
    let len = String.length s in
    let rec digits i =
      if i < len && is_digit s.[i] then digits (i + 1) else i
    in
    let int_part i =
      if i >= len then None
      else if Char.equal s.[i] '0' then Some (i + 1)
      else if s.[i] >= '1' && s.[i] <= '9' then
        let j = digits (i + 1) in
        Some j
      else None
    in
    let frac_part i =
      if i < len && Char.equal s.[i] '.' then
        let j = digits (i + 1) in
        if j = i + 1 then None else Some j
      else Some i
    in
    let exp_part i =
      if i < len && (Char.equal s.[i] 'e' || Char.equal s.[i] 'E') then
        let i =
          if i + 1 < len && (Char.equal s.[i + 1] '+' || Char.equal s.[i + 1] '-')
          then i + 2
          else i + 1
        in
        let j = digits i in
        if j = i then None else Some j
      else Some i
    in
    let start = if len > 0 && Char.equal s.[0] '-' then 1 else 0 in
    match int_part start with
    | None -> false
    | Some i -> (
        match frac_part i with
        | None -> false
        | Some i -> (
            match exp_part i with None -> false | Some i -> i = len))

  let intlit value =
    if is_json_number_literal value then Number (Intlit value)
    else invalid_arg "Eta_schema.Json.intlit: invalid JSON number literal"

  let string value = String value
  let array values = Array values
  let object_ fields = Object fields

  let float_to_string n =
    if Float.is_finite n then Printf.sprintf "%.17g" n
    else invalid_arg "Eta_schema.Json.to_string: non-finite number"

  let number_to_string = function
    | Int n -> string_of_int n
    | Intlit n -> n
    | Float n -> float_to_string n

  let rec find_field key = function
    | [] -> None
    | (name, value) :: rest ->
        if String.equal key name then Some value else find_field key rest

  let find key = function
    | Object fields -> find_field key fields
    | _ -> None

  let rec equal a b =
    match (a, b) with
    | Null, Null -> true
    | Bool a, Bool b -> Bool.equal a b
    | Number (Int a), Number (Int b) -> Int.equal a b
    | Number (Float a), Number (Float b) -> Float.equal a b
    | Number (Intlit a), Number (Intlit b) -> String.equal a b
    | Number (Int a), Number (Float b) | Number (Float b), Number (Int a) ->
        Float.equal (float_of_int a) b
    | Number _, Number _ -> false
    | String a, String b -> String.equal a b
    | Array a, Array b ->
        List.length a = List.length b && List.for_all2 equal a b
    | Object a, Object b ->
        let sort = List.sort (fun (ka, _) (kb, _) -> String.compare ka kb) in
        let a = sort a and b = sort b in
        List.length a = List.length b
        && List.for_all2
             (fun (ka, va) (kb, vb) -> String.equal ka kb && equal va vb)
             a b
    | _ -> false

  let hex_digit n =
    Char.unsafe_chr (if n < 10 then Char.code '0' + n else Char.code 'a' + n - 10)

  let add_json_escape buffer c =
    match c with
    | '"' -> Buffer.add_string buffer "\\\""
    | '\\' -> Buffer.add_string buffer "\\\\"
    | '\b' -> Buffer.add_string buffer "\\b"
    | '\012' -> Buffer.add_string buffer "\\f"
    | '\n' -> Buffer.add_string buffer "\\n"
    | '\r' -> Buffer.add_string buffer "\\r"
    | '\t' -> Buffer.add_string buffer "\\t"
    | c when Char.code c < 0x20 ->
        let code = Char.code c in
        Buffer.add_string buffer "\\u00";
        Buffer.add_char buffer (hex_digit (code lsr 4));
        Buffer.add_char buffer (hex_digit (code land 0xf))
    | c -> Buffer.add_char buffer c

  let add_json_string buffer s =
    Buffer.add_char buffer '"';
    String.iter (add_json_escape buffer) s;
    Buffer.add_char buffer '"'

  let json_string s =
    let buffer = Buffer.create (String.length s + 2) in
    add_json_string buffer s;
    Buffer.contents buffer

  let rec add_to_buffer buffer = function
    | Null -> Buffer.add_string buffer "null"
    | Bool true -> Buffer.add_string buffer "true"
    | Bool false -> Buffer.add_string buffer "false"
    | Number n -> Buffer.add_string buffer (number_to_string n)
    | String s -> add_json_string buffer s
    | Array xs ->
        Buffer.add_char buffer '[';
        add_array_items buffer xs;
        Buffer.add_char buffer ']'
    | Object fields ->
        Buffer.add_char buffer '{';
        add_object_fields buffer fields;
        Buffer.add_char buffer '}'

  and add_array_items buffer = function
    | [] -> ()
    | item :: rest ->
        add_to_buffer buffer item;
        let rec add_rest = function
          | [] -> ()
          | item :: rest ->
            Buffer.add_string buffer ", ";
            add_to_buffer buffer item;
            add_rest rest
        in
        add_rest rest

  and add_object_fields buffer = function
    | [] -> ()
    | (key, value) :: rest ->
        add_json_string buffer key;
        Buffer.add_string buffer ": ";
        add_to_buffer buffer value;
        let rec add_rest = function
          | [] -> ()
          | (key, value) :: rest ->
            Buffer.add_string buffer ", ";
            add_json_string buffer key;
            Buffer.add_string buffer ": ";
            add_to_buffer buffer value;
            add_rest rest
        in
        add_rest rest

  let to_string json =
    let buffer = Buffer.create 128 in
    add_to_buffer buffer json;
    Buffer.contents buffer
end

type json = Json.t

type path_segment =
  | Field of string
  | Index of int

type issue_kind =
  | Type_mismatch of {
      expected : string;
      got : string;
    }
  | Missing_field of string
  | Custom of string
  | Refinement_failed of {
      name : string;
      reason : string;
    }

type issue = {
  path : path_segment list;
  schema_name : string option;
  kind : issue_kind;
}

type error = [ `Decode of issue list | `Encode of issue list ]

let issue ?(path = []) ?schema_name message =
  { path; schema_name; kind = Custom message }

let type_mismatch ?(path = []) ?schema_name ~expected ~got () =
  { path; schema_name; kind = Type_mismatch { expected; got } }

let missing_field ?(path = []) ?schema_name name =
  { path; schema_name; kind = Missing_field name }

let json_got = function
  | Json.Null -> "null"
  | Json.Bool true -> "true"
  | Json.Bool false -> "false"
  | json -> Json.to_string json

let at segment issues =
  List.map (fun issue -> { issue with path = segment :: issue.path }) issues

let at_field name issues = at (Field name) issues
let at_index index issues = at (Index index) issues

let with_schema_name name issues =
  List.map
    (fun issue ->
      match issue.schema_name with
      | Some _ -> issue
      | None -> { issue with schema_name = Some name })
    issues

let with_refinement_name name issues =
  List.map
    (fun issue ->
      match (issue.schema_name, issue.kind) with
      | None, Custom reason ->
          {
            issue with
            schema_name = Some name;
            kind = Refinement_failed { name; reason };
          }
      | Some _, _ -> issue
      | None, _ -> { issue with schema_name = Some name })
    issues

let render_path path =
  let segment first = function
    | Field name -> if first then name else "." ^ name
    | Index index -> "[" ^ string_of_int index ^ "]"
  in
  match path with
  | [] -> ""
  | first :: rest ->
      segment true first ^ String.concat "" (List.map (segment false) rest)

let render_issue issue =
  let message =
    match issue.kind with
    | Type_mismatch { expected; got } -> "Expected " ^ expected ^ ", got " ^ got
    | Missing_field _ -> "Missing key"
    | Custom message -> message
    | Refinement_failed { reason; _ } -> reason
  in
  let message =
    match issue.schema_name with
    | None -> message
    | Some schema_name -> schema_name ^ ": " ^ message
  in
  match issue.path with
  | [] -> message
  | path -> message ^ " at " ^ render_path path

let render_issues issues = String.concat "; " (List.map render_issue issues)

let issue_to_json_pointer issue =
  let escape s =
    let buffer = Buffer.create (String.length s) in
    String.iter
      (function
        | '~' -> Buffer.add_string buffer "~0"
        | '/' -> Buffer.add_string buffer "~1"
        | c -> Buffer.add_char buffer c)
      s;
    Buffer.contents buffer
  in
  match issue.path with
  | [] -> ""
  | path ->
      "/"
      ^ String.concat "/"
          (List.map
             (function Field name -> escape name | Index index -> string_of_int index)
             path)

module Eta_schema = struct
  type 'a t = {
    decode : (Json.t -> ('a, issue list) result);
    encode : ('a -> (Json.t, issue list) result);
    equal : ('a -> 'a -> bool);
    json_schema : (unit -> Json.t);
    object_fields : string list option;
  }

  let schema_type name = Json.Object [ ("type", Json.String name) ]

  let add_keyword name value = function
    | Json.Object fields ->
        Json.Object
          ((name, value) :: List.remove_assoc name fields)
    | schema ->
        Json.Object
          [ ("allOf", Json.Array [ schema ]); (name, value) ]

  let json_schema schema = schema.json_schema ()

  let with_keyword name value schema =
    {
      schema with
      json_schema = (fun () -> add_keyword name value (schema.json_schema ()));
    }

  let describe description schema =
    with_keyword "description" (Json.String description) schema

  type ('record, 'field) field =
    | Required : {
        name : string;
        schema : 'field t;
        get : ('record -> 'field);
      }
        -> ('record, 'field) field
    | Optional : {
        name : string;
        schema : 'field t;
        get : ('record -> 'field option);
      }
        -> ('record, 'field option) field

  let required name schema (get) = Required { name; schema; get }
  let optional name schema (get) = Optional { name; schema; get }

  let int_of_string_exact s =
    match int_of_string_opt s with
    | Some n when String.equal (string_of_int n) s || String.equal s "-0" -> Some n
    | _ -> None

  let int_of_float_exact n =
    if Float.is_finite n && Float.equal n (Float.round n) then
      let upper_exclusive = Float.ldexp 1. (Sys.int_size - 1) in
      let lower_inclusive = -.upper_exclusive in
      if n >= lower_inclusive && n < upper_exclusive then
        let i = int_of_float n in
        if Float.equal n (float_of_int i) then Some i else None
      else None
    else None

  let int_of_number = function
    | Json.Int n -> Some n
    | Json.Intlit s -> int_of_string_exact s
    | Json.Float n -> int_of_float_exact n

  let float_of_number = function
    | Json.Int n -> Some (float_of_int n)
    | Json.Intlit s -> (
        match float_of_string_opt s with
        | Some n when Float.is_finite n -> Some n
        | _ -> None)
    | Json.Float n when Float.is_finite n -> Some n
    | Json.Float _ -> None

  let string =
    {
      decode =
        (function
        | Json.String s -> Ok s
        | json ->
            Error [ type_mismatch ~expected:"string" ~got:(json_got json) () ]);
      encode = (fun s -> Ok (Json.String s));
      equal = String.equal;
      json_schema = (fun () -> schema_type "string");
      object_fields = None;
    }

  let bool =
    {
      decode =
        (function
        | Json.Bool b -> Ok b
        | json ->
            Error [ type_mismatch ~expected:"boolean" ~got:(json_got json) () ]);
      encode = (fun b -> Ok (Json.Bool b));
      equal = Bool.equal;
      json_schema = (fun () -> schema_type "boolean");
      object_fields = None;
    }

  let int =
    {
      decode =
        (function
        | Json.Number n -> (
            match int_of_number n with
            | Some value -> Ok value
            | None ->
                Error
                  [ type_mismatch ~expected:"int" ~got:(Json.to_string (Json.Number n)) () ])
        | json -> Error [ type_mismatch ~expected:"int" ~got:(json_got json) () ]);
      encode = (fun n -> Ok (Json.int n));
      equal = Int.equal;
      json_schema = (fun () -> schema_type "integer");
      object_fields = None;
    }

  let float =
    {
      decode =
        (function
        | Json.Number n -> (
            match float_of_number n with
            | Some value -> Ok value
            | None ->
                Error
                  [ type_mismatch ~expected:"number" ~got:(Json.to_string (Json.Number n)) () ])
        | json ->
            Error [ type_mismatch ~expected:"number" ~got:(json_got json) () ]);
      encode =
        (fun n ->
          if Float.is_finite n then Ok (Json.number n)
          else
            Error
              [
                type_mismatch ~schema_name:"float" ~expected:"finite number"
                  ~got:(string_of_float n) ();
              ]);
      equal = Float.equal;
      json_schema = (fun () -> schema_type "number");
      object_fields = None;
    }

  let array item =
    let decode = function
      | Json.Array xs ->
          let rec loop index values issues = function
            | [] ->
                if issues = [] then Ok (List.rev values)
                else Error (List.rev issues)
            | json :: rest -> (
                match item.decode json with
                | Ok value -> loop (index + 1) (value :: values) issues rest
                | Error item_issues ->
                    loop (index + 1) values
                      (List.rev_append (at_index index item_issues) issues)
                      rest)
          in
          loop 0 [] [] xs
      | json -> Error [ type_mismatch ~expected:"array" ~got:(json_got json) () ]
    in
    {
      decode;
      encode =
        (fun xs ->
          let rec loop index values issues = function
            | [] ->
                if issues = [] then Ok (Json.Array (List.rev values))
                else Error (List.rev issues)
            | value :: rest -> (
                match item.encode value with
                | Ok json -> loop (index + 1) (json :: values) issues rest
                | Error item_issues ->
                    loop (index + 1) values
                      (List.rev_append (at_index index item_issues) issues)
                      rest)
          in
          loop 0 [] [] xs);
      equal = List.equal item.equal;
      json_schema =
        (fun () ->
          Json.Object
            [ ("type", Json.String "array"); ("items", item.json_schema ()) ]);
      object_fields = None;
    }

  let option item =
    {
      decode =
        (function
        | Json.Null -> Ok None
        | json -> Result.map Option.some (item.decode json));
      encode =
        (function
        | None -> Ok Json.Null
        | Some value -> item.encode value);
      equal = Option.equal item.equal;
      json_schema =
        (fun () ->
          Json.Object
            [
              ( "anyOf",
                Json.Array [ item.json_schema (); schema_type "null" ] );
            ]);
      object_fields = None;
    }

  let enum ~name cases ~equal =
    let decode = function
      | Json.String s -> (
          match List.find_opt (fun (label, _) -> String.equal label s) cases with
          | Some (_, value) -> Ok value
          | None ->
              Error
                [
                  type_mismatch ~schema_name:name ~expected:name
                    ~got:(Json.to_string (Json.String s)) ();
                ])
      | json ->
          Error [ type_mismatch ~schema_name:name ~expected:name ~got:(json_got json) () ]
    in
    let encode value =
      match List.find_opt (fun (_, candidate) -> equal value candidate) cases with
      | Some (label, _) -> Ok (Json.String label)
      | None -> Error [ issue ~schema_name:name ("Cannot encode " ^ name) ]
    in
    {
      decode;
      encode;
      equal;
      json_schema =
        (fun () ->
          Json.Object
            [
              ("type", Json.String "string");
              ( "enum",
                Json.Array
                  (List.map (fun (label, _) -> Json.String label) cases) );
            ]);
      object_fields = None;
    }

  type 'a case = {
    tag_value : string;
    decode_case : (Json.t -> ('a, issue list) result);
    encode_case : ('a -> (Json.t option, issue list) result);
  }

  let case ~tag ~(decode) ~(encode) =
    { tag_value = tag; decode_case = decode; encode_case = encode }

  let tagged_union ~name ~tag cases ~equal =
    let decode json =
      match Json.find tag json with
      | Some (Json.String tag_value) -> (
          match List.find_opt (fun case -> String.equal case.tag_value tag_value) cases with
          | Some case -> Result.map_error (with_schema_name name) (case.decode_case json)
          | None -> Error [ issue ~path:[ Field tag ] ~schema_name:name ("Unknown tag " ^ tag_value) ])
      | Some json ->
          Error
            [
              type_mismatch ~path:[ Field tag ] ~schema_name:name ~expected:"string tag"
                ~got:(json_got json) ();
            ]
      | None -> Error [ missing_field ~path:[ Field tag ] ~schema_name:name tag ]
    in
    let encode value =
      let rec loop = function
        | [] -> Error [ issue ~schema_name:name ("Cannot encode " ^ name) ]
        | case :: rest -> (
            match case.encode_case value with
            | Ok None -> loop rest
            | Ok (Some (Json.Object fields)) ->
                Ok (Json.Object ((tag, Json.String case.tag_value) :: fields))
            | Ok (Some json) ->
                Error
                  [
                    type_mismatch ~schema_name:name
                      ~expected:"object case payload"
                      ~got:(Json.to_string json) ();
                  ]
            | Error issues -> Error (with_schema_name name issues))
      in
      loop cases
    in
    {
      decode;
      encode;
      equal;
      json_schema =
        (fun () ->
          Json.Object
            [
              ("type", Json.String "object");
              ( "properties",
                Json.Object
                  [
                    ( tag,
                      Json.Object
                        [
                          ("type", Json.String "string");
                          ( "enum",
                            Json.Array
                              (List.map
                                 (fun case -> Json.String case.tag_value)
                                 cases) );
                        ] );
                  ] );
              ("required", Json.Array [ Json.String tag ]);
            ]);
      object_fields = None;
    }

  let lazy_ f =
    let schema = lazy (f ()) in
    {
      decode = (fun json -> (Lazy.force schema).decode json);
      encode = (fun value -> (Lazy.force schema).encode value);
      equal = (fun a b -> (Lazy.force schema).equal a b);
      json_schema = (fun () -> (Lazy.force schema).json_schema ());
      object_fields = None;
    }

  type 'record any_field = Any_field : ('record, 'a) field -> 'record any_field

  let field_name : type record a. (record, a) field -> string = function
    | Required field -> field.name
    | Optional field -> field.name

  let field_schema : type record a. (record, a) field -> Json.t = function
    | Required field -> field.schema.json_schema ()
    | Optional field -> field.schema.json_schema ()

  let record_json_schema fields =
    let properties, required =
      List.fold_left
        (fun (properties, required) (Any_field field) ->
          let name = field_name field in
          let required =
            match field with Required _ -> name :: required | Optional _ -> required
          in
          ((name, field_schema field) :: properties, required))
        ([], []) fields
    in
    Json.Object
      [
        ("type", Json.String "object");
        ("properties", Json.Object (List.rev properties));
        ("required", Json.Array (List.rev_map (fun name -> Json.String name) required));
      ]

  let emit_field : type record a.
      (record, a) field -> record -> ((string * Json.t) option, issue list) result =
   fun field record ->
    match field with
    | Required f ->
        Result.map
          (fun json -> Some (f.name, json))
          (Result.map_error (at_field f.name) (f.schema.encode (f.get record)))
    | Optional f ->
        (match f.get record with
        | None -> Ok None
        | Some value ->
            Result.map
              (fun json -> Some (f.name, json))
              (Result.map_error (at_field f.name) (f.schema.encode value)))

  let decode_field : type record a.
      Json.t -> (record, a) field -> (a, issue list) result =
   fun json field ->
    match field with
    | Required f -> (
        match Json.find f.name json with
        | None -> Error [ missing_field ~path:[ Field f.name ] f.name ]
        | Some value -> Result.map_error (at_field f.name) (f.schema.decode value))
    | Optional f -> (
        match Json.find f.name json with
        | None -> Ok None
        | Some value ->
            Result.map Option.some
              (Result.map_error (at_field f.name) (f.schema.decode value)))

  let encode_object fields record =
    let rec loop values issues = function
      | [] ->
          if issues = [] then Ok (Json.Object (List.rev values))
          else Error (List.rev issues)
      | Any_field field :: rest -> (
          match emit_field field record with
          | Ok None -> loop values issues rest
          | Ok (Some field) -> loop (field :: values) issues rest
          | Error field_issues ->
              loop values (List.rev_append field_issues issues) rest)
    in
    loop [] [] fields

  let emit_acc : type record a.
      record ->
      (string * Json.t) list ->
      issue list ->
      (record, a) field ->
      (string * Json.t) list * issue list =
   fun record values issues field ->
    match emit_field field record with
    | Ok None -> (values, issues)
    | Ok (Some field) -> (field :: values, issues)
    | Error field_issues -> (values, List.rev_append field_issues issues)

  let finish_object values issues =
    if issues = [] then Ok (Json.Object (List.rev values))
    else Error (List.rev issues)

  let encode_object6 f1 f2 f3 f4 f5 f6 record =
    let values, issues = emit_acc record [] [] f1 in
    let values, issues = emit_acc record values issues f2 in
    let values, issues = emit_acc record values issues f3 in
    let values, issues = emit_acc record values issues f4 in
    let values, issues = emit_acc record values issues f5 in
    let values, issues = emit_acc record values issues f6 in
    finish_object values issues

  let decode_apply decoded_f decoded_value =
    match (decoded_f, decoded_value) with
    | Ok f, Ok value -> Ok (f value)
    | Error issues, Ok _ | Ok _, Error issues -> Error issues
    | Error left, Error right -> Error (left @ right)

  let ( <*> ) = decode_apply

  (* The public v0 product API is arity-specific because OCaml has no variadic
     record builders. Shared encode/decode helpers above hold the object
     invariants; the record1..record6 functions below only sequence fields into
     ordinary curried constructors. *)
  let record ~name ~fields ~(decode) ~(encode) ~(equal) =
    {
      decode =
        (function
        | Json.Object _ as json ->
            Result.map_error (with_schema_name name) (decode json)
        | json ->
            Error
              [
                type_mismatch ~schema_name:name ~expected:("object " ^ name)
                  ~got:(json_got json) ();
              ]);
      encode =
        (fun record ->
          Result.map_error (with_schema_name name) (encode record));
      equal;
      json_schema = (fun () -> record_json_schema fields);
      object_fields = Some (List.map (fun (Any_field field) -> field_name field) fields);
    }

  let record1 ~name (make) f1 ~(equal) () =
    record ~name ~fields:[ Any_field f1 ] ~encode:(encode_object [ Any_field f1 ])
      ~decode:(fun json -> Ok make <*> decode_field json f1)
      ~equal

  let record2 ~name (make) f1 f2 ~(equal) () =
    record ~name ~fields:[ Any_field f1; Any_field f2 ]
      ~encode:(encode_object [ Any_field f1; Any_field f2 ])
      ~decode:(fun json ->
        Ok make <*> decode_field json f1 <*> decode_field json f2)
      ~equal

  let record3 ~name (make) f1 f2 f3 ~(equal) () =
    record ~name ~fields:[ Any_field f1; Any_field f2; Any_field f3 ]
      ~encode:(encode_object [ Any_field f1; Any_field f2; Any_field f3 ])
      ~decode:(fun json ->
        Ok make <*> decode_field json f1 <*> decode_field json f2
        <*> decode_field json f3)
      ~equal

  let record4 ~name (make) f1 f2 f3 f4 ~(equal) () =
    record ~name
      ~fields:[ Any_field f1; Any_field f2; Any_field f3; Any_field f4 ]
      ~encode:
        (encode_object
           [ Any_field f1; Any_field f2; Any_field f3; Any_field f4 ])
      ~decode:(fun json ->
        Ok make <*> decode_field json f1 <*> decode_field json f2
        <*> decode_field json f3 <*> decode_field json f4)
      ~equal

  let record5 ~name (make) f1 f2 f3 f4 f5 ~(equal) () =
    record ~name
      ~fields:
        [
          Any_field f1;
          Any_field f2;
          Any_field f3;
          Any_field f4;
          Any_field f5;
        ]
      ~encode:
        (encode_object
           [
             Any_field f1;
             Any_field f2;
             Any_field f3;
             Any_field f4;
             Any_field f5;
           ])
      ~decode:(fun json ->
        Ok make <*> decode_field json f1 <*> decode_field json f2
        <*> decode_field json f3 <*> decode_field json f4
        <*> decode_field json f5)
      ~equal

  let record6 ~name (make) f1 f2 f3 f4 f5 f6 ~(equal) () =
    record ~name
      ~fields:
        [
          Any_field f1;
          Any_field f2;
          Any_field f3;
          Any_field f4;
          Any_field f5;
          Any_field f6;
        ]
      ~encode:(encode_object6 f1 f2 f3 f4 f5 f6)
      ~decode:(fun json ->
        Ok make <*> decode_field json f1 <*> decode_field json f2
        <*> decode_field json f3 <*> decode_field json f4
        <*> decode_field json f5 <*> decode_field json f6)
      ~equal

  let refine ~name (check) schema =
    {
      schema with
      decode =
        (fun json ->
          match schema.decode json with
          | Error issues -> Error (with_schema_name name issues)
          | Ok value -> (
              match check value with
              | [] -> Ok value
              | issues -> Error (with_refinement_name name issues)));
    }

  let transform ~name ~(equal) ~(decode) ~(encode) schema =
    {
      decode =
        (fun json ->
          match schema.decode json with
          | Ok value -> Result.map_error (with_schema_name name) (decode value)
          | Error issues -> Error (with_schema_name name issues));
      encode = (fun value -> Result.map_error (with_schema_name name) (schema.encode (encode value)));
      equal;
      json_schema = schema.json_schema;
      object_fields = schema.object_fields;
    }

  let closed schema =
    match schema.object_fields with
    | None -> invalid_arg "Eta_schema.closed: expected an object schema"
    | Some allowed ->
        let decode json =
          match json with
          | Json.Object fields ->
              let unknown =
                List.filter_map
                  (fun (name, _) ->
                    if List.mem name allowed then None
                    else
                      Some
                        (issue ~path:[ Field name ]
                           ("Unknown parameter: " ^ name)))
                  fields
              in
              if unknown = [] then schema.decode json else Error unknown
          | _ -> schema.decode json
        in
        {
          schema with
          decode;
          json_schema =
            (fun () ->
              add_keyword "additionalProperties" (Json.Bool false)
                (schema.json_schema ()));
        }

  let decode_result schema json = schema.decode json
  let encode_result schema value = schema.encode value

  let decode :
      type a.
      a t -> json -> (a, [> `Decode of issue list ]) Eta.Effect.t =
   fun schema json ->
    match schema.decode json with
    | Ok value -> Eta.Effect.pure value
    | Error issues -> Eta.Effect.fail (`Decode issues)

  let decode_with_policy :
      type a b.
      a t ->
      (a -> (b, [> `Decode of issue list ]) Eta.Effect.t) ->
      json ->
      (b, [> `Decode of issue list ]) Eta.Effect.t =
   fun schema policy json ->
    Eta.Effect.bind policy (decode schema json)

  let encode :
      type a.
      a t -> a -> (json, [> `Encode of issue list ]) Eta.Effect.t =
   fun schema value ->
    match schema.encode value with
    | Ok json -> Eta.Effect.pure json
    | Error issues -> Eta.Effect.fail (`Encode issues)
  let equal schema = schema.equal
end

module type JSON_ADAPTER = sig
  type external_json

  val of_external : external_json -> (json, issue list) result
  val to_external : json -> external_json
end

module Make (A : JSON_ADAPTER) = struct
  let decode_result schema external_json =
    match A.of_external external_json with
    | Ok json -> Eta_schema.decode_result schema json
    | Error issues -> Error issues

  let decode schema external_json =
    match decode_result schema external_json with
    | Ok value -> Eta.Effect.pure value
    | Error issues -> Eta.Effect.fail (`Decode issues)

  let encode_result schema value =
    Result.map A.to_external (Eta_schema.encode_result schema value)

  let encode schema value =
    match encode_result schema value with
    | Ok external_json -> Eta.Effect.pure external_json
    | Error issues -> Eta.Effect.fail (`Encode issues)
end
