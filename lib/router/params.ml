type t =
  | Named of (string * string * int * int) list
  | Raw of {
      params : (string * int * int) list;
      remapping : string list;
      catch_all : (string * string * int * int) option;
    }

let empty = Named []

let is_empty = function
  | Named [] -> true
  | Raw { params = []; catch_all = None } -> true
  | _ -> false

let make_value src off len =
  String.sub src off len

let build_named = function
  | Named ps -> ps
  | Raw { params; remapping; catch_all } ->
      (* [params] is stored in reverse match order (newest first), so pairing
         it with [List.rev remapping] and consing yields forward order without
         a second reversal of the parameter list. *)
      let rec zip names params acc =
        match names, params with
        | name :: ns, (src, off, len) :: ps ->
            zip ns ps ((name, src, off, len) :: acc)
        | _ -> acc
      in
      let named = zip (List.rev remapping) params [] in
      (match catch_all with
      | Some v -> named @ [ v ]
      | None -> named)

let get params name =
  let rec loop = function
    | [] -> None
    | (k, src, off, len) :: rest ->
        if k = name then Some (make_value src off len) else loop rest
  in
  loop (build_named params)

let mem params name =
  List.exists (fun (k, _, _, _) -> k = name) (build_named params)

let to_list params =
  List.map (fun (k, src, off, len) -> (k, make_value src off len)) (build_named params)

let iter f params =
  List.iter (fun (k, src, off, len) -> f k (make_value src off len)) (build_named params)

let fold f params acc =
  List.fold_left
    (fun acc (k, src, off, len) -> f k (make_value src off len) acc)
    acc (build_named params)

let of_list params =
  Named
    (List.map
       (fun (k, slice) ->
         (k, slice.Slice.src, slice.Slice.off, slice.Slice.len))
       params)

let of_offsets params = Named params

let of_raw ~params ~remapping ~catch_all =
  match params, catch_all with
  | [], None -> empty
  | _ -> Raw { params; remapping; catch_all }
