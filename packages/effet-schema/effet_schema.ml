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
    else invalid_arg "Effet_schema.Json.intlit: invalid JSON number literal"

  let string value = String value
  let array values = Array values
  let object_ fields = Object fields

  let float_to_string n =
    if Float.is_finite n then Printf.sprintf "%.17g" n
    else invalid_arg "Effet_schema.Json.to_string: non-finite number"

  let number_to_string = function
    | Int n -> string_of_int n
    | Intlit n -> n
    | Float n -> float_to_string n

  let find key = function Object fields -> List.assoc_opt key fields | _ -> None

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

  let rec to_string = function
    | Null -> "null"
    | Bool true -> "true"
    | Bool false -> "false"
    | Number n -> number_to_string n
    | String s -> Printf.sprintf "%S" s
    | Array xs -> "[" ^ String.concat ", " (List.map to_string xs) ^ "]"
    | Object fields ->
        let field (key, value) =
          Printf.sprintf "%S: %s" key (to_string value)
        in
        "{" ^ String.concat ", " (List.map field fields) ^ "}"
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

let at segment issues = List.map (fun i -> { i with path = segment :: i.path }) issues
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
    s |> String.split_on_char '~' |> String.concat "~0"
    |> String.split_on_char '/' |> String.concat "~1"
  in
  match issue.path with
  | [] -> ""
  | path ->
      "/"
      ^ String.concat "/"
          (List.map
             (function Field name -> escape name | Index index -> string_of_int index)
             path)

module Schema = struct
  type 'a t = {
    decode : Json.t -> ('a, issue list) result;
    encode : 'a -> (Json.t, issue list) result;
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

  let int_of_string_exact s =
    match int_of_string_opt s with
    | Some n when String.equal (string_of_int n) s || String.equal s "-0" -> Some n
    | _ -> None

  let is_int_float n =
    Float.is_finite n
    && Float.equal n (Float.round n)
    && n >= float_of_int min_int
    && n <= float_of_int max_int

  let int_of_number = function
    | Json.Int n -> Some n
    | Json.Intlit s -> int_of_string_exact s
    | Json.Float n when is_int_float n -> Some (int_of_float n)
    | Json.Float _ -> None

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
            Error [ type_mismatch ~expected:"string" ~got:(Json.to_string json) () ]);
      encode = (fun s -> Ok (Json.String s));
      equal = String.equal;
    }

  let bool =
    {
      decode =
        (function
        | Json.Bool b -> Ok b
        | json ->
            Error [ type_mismatch ~expected:"boolean" ~got:(Json.to_string json) () ]);
      encode = (fun b -> Ok (Json.Bool b));
      equal = Bool.equal;
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
        | json -> Error [ type_mismatch ~expected:"int" ~got:(Json.to_string json) () ]);
      encode = (fun n -> Ok (Json.int n));
      equal = Int.equal;
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
            Error [ type_mismatch ~expected:"number" ~got:(Json.to_string json) () ]);
      encode = (fun n -> Ok (Json.number n));
      equal = Float.equal;
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
      | json -> Error [ type_mismatch ~expected:"array" ~got:(Json.to_string json) () ]
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
          Error [ type_mismatch ~schema_name:name ~expected:name ~got:(Json.to_string json) () ]
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
    }

  type 'a case = {
    tag_value : string;
    decode_case : Json.t -> ('a, issue list) result;
    encode_case : 'a -> (Json.t option, issue list) result;
  }

  let case ~tag ~decode ~encode = { tag_value = tag; decode_case = decode; encode_case = encode }

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
                ~got:(Json.to_string json) ();
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
            | Ok (Some json) -> Ok json
            | Error issues -> Error (with_schema_name name issues))
      in
      loop cases
    in
    {
      decode;
      encode;
      equal;
    }

  let lazy_ thunk =
    let schema = lazy (thunk ()) in
    {
      decode = (fun json -> (Lazy.force schema).decode json);
      encode = (fun value -> (Lazy.force schema).encode value);
      equal = (fun a b -> (Lazy.force schema).equal a b);
    }

  type 'record any_field = Any_field : ('record, 'a) field -> 'record any_field

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

  let collect = function Ok _ -> [] | Error issues -> issues

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

  let record1 ~name make f1 ~equal () =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match decode_field json f1 with
            | Ok a -> Ok (make a)
            | Error issues -> Error (with_schema_name name issues))
        | json ->
            Error
              [ type_mismatch ~schema_name:name ~expected:("object " ^ name) ~got:(Json.to_string json) () ]);
      encode = (fun record -> Result.map_error (with_schema_name name) (encode_object [ Any_field f1 ] record));
      equal;
    }

  let record2 ~name make f1 f2 ~equal () =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match (decode_field json f1, decode_field json f2) with
            | Ok a, Ok b -> Ok (make a b)
            | a, b -> Error (with_schema_name name (collect a @ collect b)))
        | json ->
            Error
              [ type_mismatch ~schema_name:name ~expected:("object " ^ name) ~got:(Json.to_string json) () ]);
      encode =
        (fun record ->
          Result.map_error (with_schema_name name)
            (encode_object [ Any_field f1; Any_field f2 ] record));
      equal;
    }

  let record3 ~name make f1 f2 f3 ~equal () =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match (decode_field json f1, decode_field json f2, decode_field json f3) with
            | Ok a, Ok b, Ok c -> Ok (make a b c)
            | a, b, c -> Error (with_schema_name name (collect a @ collect b @ collect c)))
        | json ->
            Error
              [ type_mismatch ~schema_name:name ~expected:("object " ^ name) ~got:(Json.to_string json) () ]);
      encode =
        (fun record ->
          Result.map_error (with_schema_name name)
            (encode_object [ Any_field f1; Any_field f2; Any_field f3 ] record));
      equal;
    }

  let record4 ~name make f1 f2 f3 f4 ~equal () =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match
              ( decode_field json f1,
                decode_field json f2,
                decode_field json f3,
                decode_field json f4 )
            with
            | Ok a, Ok b, Ok c, Ok d -> Ok (make a b c d)
            | a, b, c, d ->
                Error (with_schema_name name (collect a @ collect b @ collect c @ collect d)))
        | json ->
            Error
              [ type_mismatch ~schema_name:name ~expected:("object " ^ name) ~got:(Json.to_string json) () ]);
      encode =
        (fun record ->
          Result.map_error (with_schema_name name)
            (encode_object [ Any_field f1; Any_field f2; Any_field f3; Any_field f4 ] record));
      equal;
    }

  let record5 ~name make f1 f2 f3 f4 f5 ~equal () =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match
              ( decode_field json f1,
                decode_field json f2,
                decode_field json f3,
                decode_field json f4,
                decode_field json f5 )
            with
            | Ok a, Ok b, Ok c, Ok d, Ok e -> Ok (make a b c d e)
            | a, b, c, d, e ->
                Error
                  (with_schema_name name (collect a @ collect b @ collect c @ collect d @ collect e)))
        | json ->
            Error
              [ type_mismatch ~schema_name:name ~expected:("object " ^ name) ~got:(Json.to_string json) () ]);
      encode =
        (fun record ->
          Result.map_error (with_schema_name name)
            (encode_object
               [ Any_field f1; Any_field f2; Any_field f3; Any_field f4; Any_field f5 ]
               record));
      equal;
    }

  let record6 ~name make f1 f2 f3 f4 f5 f6 ~equal () =
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
                Error
                  (with_schema_name name
                     (collect a @ collect b @ collect c @ collect d @ collect e @ collect f)))
        | json ->
            Error
              [ type_mismatch ~schema_name:name ~expected:("object " ^ name) ~got:(Json.to_string json) () ]);
      encode =
        (fun record ->
          Result.map_error (with_schema_name name)
            (encode_object
               [
                 Any_field f1;
                 Any_field f2;
                 Any_field f3;
                 Any_field f4;
                 Any_field f5;
                 Any_field f6;
               ]
               record));
      equal;
    }

  let refine ~name check schema =
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

  let transform ~name ~equal ~decode ~encode schema =
    {
      decode =
        (fun json ->
          match schema.decode json with
          | Ok value -> Result.map_error (with_schema_name name) (decode value)
          | Error issues -> Error (with_schema_name name issues));
      encode = (fun value -> Result.map_error (with_schema_name name) (schema.encode (encode value)));
      equal;
    }

  let decode_result schema json = schema.decode json
  let encode_result schema value = schema.encode value

  let decode :
      type a.
      a t -> json -> (a, [> `Decode of issue list ]) Effet.Effect.t =
   fun schema json ->
    match schema.decode json with
    | Ok value -> Effet.Effect.pure value
    | Error issues -> Effet.Effect.fail (`Decode issues)

  let decode_with_policy :
      type a b.
      a t ->
      (a -> (b, [> `Decode of issue list ]) Effet.Effect.t) ->
      json ->
      (b, [> `Decode of issue list ]) Effet.Effect.t =
   fun schema policy json ->
    Effet.Effect.bind policy (decode schema json)

  let encode :
      type a.
      a t -> a -> (json, [> `Encode of issue list ]) Effet.Effect.t =
   fun schema value ->
    match schema.encode value with
    | Ok json -> Effet.Effect.pure json
    | Error issues -> Effet.Effect.fail (`Encode issues)
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
    | Ok json -> Schema.decode_result schema json
    | Error issues -> Error issues

  let decode schema external_json =
    match decode_result schema external_json with
    | Ok value -> Effet.Effect.pure value
    | Error issues -> Effet.Effect.fail (`Decode issues)

  let encode_result schema value =
    Result.map A.to_external (Schema.encode_result schema value)

  let encode schema value =
    match encode_result schema value with
    | Ok external_json -> Effet.Effect.pure external_json
    | Error issues -> Effet.Effect.fail (`Encode issues)
end
