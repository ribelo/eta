module Json = struct
  type t =
    | Null
    | Bool of bool
    | Number of float
    | String of string
    | Array of t list
    | Object of (string * t) list

  let null = Null
  let bool value = Bool value
  let number value = Number value
  let int value = Number (float_of_int value)
  let string value = String value
  let array values = Array values
  let object_ fields = Object fields

  let find key = function Object fields -> List.assoc_opt key fields | _ -> None

  let rec equal a b =
    match (a, b) with
    | Null, Null -> true
    | Bool a, Bool b -> Bool.equal a b
    | Number a, Number b -> Float.equal a b
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
    | Number n ->
        if Float.is_finite n && Float.equal n (Float.round n) then
          string_of_int (int_of_float n)
        else string_of_float n
    | String s -> Printf.sprintf "%S" s
    | Array xs -> "[" ^ String.concat ", " (List.map to_string xs) ^ "]"
    | Object fields ->
        let field (key, value) =
          Printf.sprintf "%S: %s" key (to_string value)
        in
        "{" ^ String.concat ", " (List.map field fields) ^ "}"
end

type json = Json.t

type issue = {
  path : string list;
  message : string;
}

type error = [ `Decode of issue list ]

let issue ?(path = []) message = { path; message }
let at segment issues = List.map (fun i -> { i with path = segment :: i.path }) issues

let render_issue issue =
  match issue.path with
  | [] -> issue.message
  | path -> issue.message ^ " at " ^ String.concat "." path

let render_issues issues = String.concat "; " (List.map render_issue issues)

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

  let is_int_float n = Float.is_finite n && Float.equal n (Float.round n)

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
      encode = Json.int;
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
      encode = Json.number;
      json_schema = Json.object_ [ ("type", Json.String "number") ];
      samples = [ 0.; 1. ];
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
                      (List.rev_append (at (string_of_int index) item_issues) issues)
                      rest)
          in
          loop 0 [] [] xs
      | json -> Error [ issue ("Expected array, got " ^ Json.to_string json) ]
    in
    {
      decode;
      encode = (fun xs -> Json.Array (List.map item.encode xs));
      json_schema =
        Json.object_ [ ("type", Json.String "array"); ("items", item.json_schema) ];
      samples = [ []; item.samples ];
      equal = List.equal item.equal;
    }

  let option item =
    {
      decode =
        (function
        | Json.Null -> Ok None
        | json -> Result.map Option.some (item.decode json));
      encode = (function None -> Json.Null | Some value -> item.encode value);
      json_schema =
        Json.object_
          [
            ( "anyOf",
              Json.Array
                [ item.json_schema; Json.object_ [ ("type", Json.String "null") ] ] );
          ];
      samples = None :: List.map Option.some item.samples;
      equal = Option.equal item.equal;
    }

  let enum ~name cases ~equal =
    let decode = function
      | Json.String s -> (
          match List.find_opt (fun (label, _) -> String.equal label s) cases with
          | Some (_, value) -> Ok value
          | None -> Error [ issue ("Expected " ^ name ^ ", got " ^ Json.to_string (Json.String s)) ])
      | json -> Error [ issue ("Expected " ^ name ^ ", got " ^ Json.to_string json) ]
    in
    let encode value =
      match List.find_opt (fun (_, candidate) -> equal value candidate) cases with
      | Some (label, _) -> Json.String label
      | None -> invalid_arg ("Effet_schema.Schema.enum: cannot encode " ^ name)
    in
    {
      decode;
      encode;
      json_schema =
        Json.object_
          [
            ("title", Json.String name);
            ("enum", Json.Array (List.map (fun (label, _) -> Json.String label) cases));
          ];
      samples = List.map snd cases;
      equal;
    }

  type 'a case = {
    tag_value : string;
    decode_case : Json.t -> ('a, issue list) result;
    encode_case : 'a -> Json.t option;
  }

  let case ~tag ~decode ~encode = { tag_value = tag; decode_case = decode; encode_case = encode }

  let tagged_union ~name ~tag cases ~equal =
    let decode json =
      match Json.find tag json with
      | Some (Json.String tag_value) -> (
          match List.find_opt (fun case -> String.equal case.tag_value tag_value) cases with
          | Some case -> case.decode_case json
          | None -> Error [ issue ~path:[ tag ] ("Unknown tag " ^ tag_value) ])
      | Some json -> Error [ issue ~path:[ tag ] ("Expected string tag, got " ^ Json.to_string json) ]
      | None -> Error [ issue ~path:[ tag ] "Missing tag" ]
    in
    let encode value =
      let rec loop = function
        | [] -> invalid_arg ("Effet_schema.Schema.tagged_union: cannot encode " ^ name)
        | case :: rest -> (
            match case.encode_case value with
            | None -> loop rest
            | Some (Json.Object fields) ->
                Json.Object ((tag, Json.String case.tag_value) :: fields)
            | Some json -> json)
      in
      loop cases
    in
    {
      decode;
      encode;
      json_schema =
        Json.object_
          [
            ("title", Json.String name);
            ( "oneOf",
              Json.Array
                (List.map
                   (fun case ->
                     Json.object_
                       [
                         ("title", Json.String case.tag_value);
                         ( "properties",
                           Json.object_
                             [ (tag, Json.object_ [ ("const", Json.String case.tag_value) ]) ] );
                       ])
                   cases) );
          ];
      samples = [];
      equal;
    }

  let lazy_ thunk =
    {
      decode = (fun json -> (thunk ()).decode json);
      encode = (fun value -> (thunk ()).encode value);
      json_schema = Json.object_ [ ("$ref", Json.String "#/recursive") ];
      samples = [];
      equal = (fun a b -> (thunk ()).equal a b);
    }

  let field_name : type record a. (record, a) field -> string = function
    | Required f -> f.name
    | Optional f -> f.name

  let field_schema_json : type record a. (record, a) field -> Json.t =
    function Required f -> f.schema.json_schema | Optional f -> f.schema.json_schema

  let field_required_json : type record a. (record, a) field -> Json.t option =
    function Required f -> Some (Json.String f.name) | Optional _ -> None

  type 'record any_field = Any_field : ('record, 'a) field -> 'record any_field

  let emit_field : type record a.
      (record, a) field -> record -> (string * Json.t) option =
   fun field record ->
    match field with
    | Required f -> Some (f.name, f.schema.encode (f.get record))
    | Optional f ->
        Option.map (fun value -> (f.name, f.schema.encode value)) (f.get record)

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
            Result.map Option.some
              (Result.map_error (at f.name) (f.schema.decode value)))

  let collect = function Ok _ -> [] | Error issues -> issues

  let json_schema_for_record name fields =
    Json.object_
      [
        ("type", Json.String "object");
        ("title", Json.String name);
        ( "properties",
          Json.Object
            (List.map
               (fun (Any_field field) -> (field_name field, field_schema_json field))
               fields) );
        ( "required",
          Json.Array
            (List.filter_map
               (fun (Any_field field) -> field_required_json field)
               fields) );
      ]

  let record1 ~name make f1 ~equal ?(samples = []) () =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match decode_field json f1 with
            | Ok a -> Ok (make a)
            | Error issues -> Error issues)
        | json -> Error [ issue ("Expected object " ^ name ^ ", got " ^ Json.to_string json) ]);
      encode = (fun record -> Json.Object (List.filter_map Fun.id [ emit_field f1 record ]));
      json_schema = json_schema_for_record name [ Any_field f1 ];
      samples;
      equal;
    }

  let record2 ~name make f1 f2 ~equal ?(samples = []) () =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match (decode_field json f1, decode_field json f2) with
            | Ok a, Ok b -> Ok (make a b)
            | a, b -> Error (collect a @ collect b))
        | json -> Error [ issue ("Expected object " ^ name ^ ", got " ^ Json.to_string json) ]);
      encode =
        (fun record -> Json.Object (List.filter_map Fun.id [ emit_field f1 record; emit_field f2 record ]));
      json_schema = json_schema_for_record name [ Any_field f1; Any_field f2 ];
      samples;
      equal;
    }

  let record3 ~name make f1 f2 f3 ~equal ?(samples = []) () =
    {
      decode =
        (function
        | Json.Object _ as json -> (
            match (decode_field json f1, decode_field json f2, decode_field json f3) with
            | Ok a, Ok b, Ok c -> Ok (make a b c)
            | a, b, c -> Error (collect a @ collect b @ collect c))
        | json -> Error [ issue ("Expected object " ^ name ^ ", got " ^ Json.to_string json) ]);
      encode =
        (fun record ->
          Json.Object
            (List.filter_map Fun.id
               [ emit_field f1 record; emit_field f2 record; emit_field f3 record ]));
      json_schema =
        json_schema_for_record name [ Any_field f1; Any_field f2; Any_field f3 ];
      samples;
      equal;
    }

  let record4 ~name make f1 f2 f3 f4 ~equal ?(samples = []) () =
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
            | a, b, c, d -> Error (collect a @ collect b @ collect c @ collect d))
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
               ]));
      json_schema =
        json_schema_for_record name
          [ Any_field f1; Any_field f2; Any_field f3; Any_field f4 ];
      samples;
      equal;
    }

  let record5 ~name make f1 f2 f3 f4 f5 ~equal ?(samples = []) () =
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
            | a, b, c, d, e -> Error (collect a @ collect b @ collect c @ collect d @ collect e))
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
               ]));
      json_schema =
        json_schema_for_record name
          [ Any_field f1; Any_field f2; Any_field f3; Any_field f4; Any_field f5 ];
      samples;
      equal;
    }

  let record6 ~name make f1 f2 f3 f4 f5 f6 ~equal ?(samples = []) () =
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
        json_schema_for_record name
          [
            Any_field f1;
            Any_field f2;
            Any_field f3;
            Any_field f4;
            Any_field f5;
            Any_field f6;
          ];
      samples;
      equal;
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

  let transform ~name ?(equal = Stdlib.( = )) ~decode ~encode schema =
    {
      decode =
        (fun json ->
          match schema.decode json with
          | Ok value -> decode value
          | Error issues -> Error issues);
      encode = (fun value -> schema.encode (encode value));
      json_schema =
        Json.object_
          [ ("allOf", Json.Array [ schema.json_schema ]); ("description", Json.String name) ];
      samples =
        List.filter_map
          (fun value -> match decode value with Ok decoded -> Some decoded | Error _ -> None)
          schema.samples;
      equal;
    }

  let decode_result schema json = schema.decode json

  let decode :
      type env a. a t -> json -> (env, [> error ], a) Effet.Effect.t =
   fun schema json ->
    match schema.decode json with
    | Ok value -> Effet.Effect.pure value
    | Error issues -> Effet.Effect.fail (`Decode issues)

  let decode_with_policy :
      type env a.
      a t ->
      (a -> (env, [> error ], a) Effet.Effect.t) ->
      json ->
      (env, [> error ], a) Effet.Effect.t =
   fun schema policy json ->
    Effet.Effect.bind policy (decode schema json)

  let encode schema value = schema.encode value
  let json_schema schema = schema.json_schema
  let samples schema = schema.samples
  let equal schema = schema.equal
end

module type JSON_ADAPTER = sig
  type external_json

  val of_external : external_json -> (json, issue list) result
  val to_external : json -> external_json
end
