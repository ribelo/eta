type 'a t = { mutable root : 'a node }

and 'a node = {
  mutable prefix : Escape.t;
  mutable prefix_str : string;
  mutable prefix_len : int;
  mutable priority : int;
  mutable wild_child : bool;
  mutable indices : string;
  mutable node_type : node_type;
  mutable children : 'a node array;
  mutable value : 'a option;
  mutable remapping : Route.remapping;
}

and node_type =
  | Root
  | Param of { suffix : bool }
  | Catch_all
  | Static

let empty_prefix = Escape.make_unescaped ~bytes:"" ~escaped:""

let set_prefix node prefix =
  node.prefix <- prefix;
  node.prefix_str <- Escape.to_string prefix;
  node.prefix_len <- Escape.length prefix

let node_with_prefix prefix node =
  set_prefix node prefix;
  node

let char_to_string c =
  let b = Bytes.create 1 in
  Bytes.unsafe_set b 0 c;
  Bytes.unsafe_to_string b

let append_char s c =
  let len = String.length s in
  let b = Bytes.create (len + 1) in
  Bytes.blit_string s 0 b 0 len;
  Bytes.unsafe_set b len c;
  Bytes.unsafe_to_string b

let default_node () =
  {
    prefix = empty_prefix;
    prefix_str = "";
    prefix_len = 0;
    priority = 0;
    wild_child = false;
    indices = "";
    node_type = Static;
    children = [||];
    value = None;
    remapping = [];
  }

let empty () =
  {
    root =
      {
        prefix = empty_prefix;
        prefix_str = "";
        prefix_len = 0;
        priority = 0;
        wild_child = false;
        indices = "";
        node_type = Root;
        children = [||];
        value = None;
        remapping = [];
      };
  }

(* Slice helpers ---------------------------------------------------------- *)

let[@zero_alloc opt] slice_equal a b =
  Escape.slice_length a = Escape.slice_length b
  && Escape.common_prefix a b = Escape.slice_length a

let[@zero_alloc opt] is_empty_or_slash s =
  let len = Escape.slice_length s in
  len = 0 || (len = 1 && Escape.slice_get s 0 = '/')

let rec slice_index_from_loop s c len i =
  if i < len && Escape.slice_get s i <> c then
    slice_index_from_loop s c len (i + 1)
  else i

let[@zero_alloc opt] slice_index_from s c from =
  let len = Escape.slice_length s in
  let i = slice_index_from_loop s c len from in
  if i = len then -1 else i

let[@zero_alloc opt] prefix_ends_with_slash p =
  let len = Escape.length p in
  len > 0 && Escape.get p (len - 1) = '/'

let rec prefix_contains_slash_loop p len i =
  i < len && (Escape.get p i = '/' || prefix_contains_slash_loop p len (i + 1))

let[@zero_alloc opt] prefix_contains_slash p =
  let len = Escape.length p in
  prefix_contains_slash_loop p len 0

(* Conflict detection helpers -------------------------------------------- *)

let rec prefix_wild_child_in_segment node =
  match node.node_type with
  | Root when Escape.length node.prefix = 0 -> false
  | _ ->
    if prefix_ends_with_slash node.prefix then
      Array.exists prefix_wild_child_in_segment node.children
    else
      Array.exists wild_child_in_segment node.children

and wild_child_in_segment node =
  if prefix_contains_slash node.prefix then false
  else
    match node.node_type with
    | Param _ -> true
    | _ -> Array.exists wild_child_in_segment node.children

and suffix_wild_child_in_segment node =
  match node.node_type with
  | Param { suffix = true } -> true
  | _ ->
    Array.exists
      (fun child ->
        not (prefix_contains_slash child.prefix)
        && suffix_wild_child_in_segment child)
      node.children

(* Child array helpers ---------------------------------------------------- *)

let add_child node child =
  let len = Array.length node.children in
  if node.wild_child && len > 0 then begin
    node.children <-
      Array.init (len + 1) (fun i ->
        if i < len - 1 then node.children.(i)
        else if i = len - 1 then child
        else node.children.(len - 1));
    len - 1
  end else begin
    node.children <- Array.append node.children [| child |];
    len
  end

let add_suffix_child node child =
  let child_len = Escape.length child.prefix in
  let rec find_pos i =
    if i >= Array.length node.children then i
    else if Escape.length node.children.(i).prefix >= child_len then i
    else find_pos (i + 1)
  in
  let pos = find_pos 0 in
  node.children <-
    Array.init (Array.length node.children + 1) (fun i ->
      if i < pos then node.children.(i)
      else if i = pos then child
      else node.children.(i - 1));
  pos

let update_child_priority node i =
  node.children.(i).priority <- node.children.(i).priority + 1;
  let priority = node.children.(i).priority in
  let rec bubble idx =
    if idx > 0 && node.children.(idx - 1).priority < priority then begin
      let tmp = node.children.(idx) in
      node.children.(idx) <- node.children.(idx - 1);
      node.children.(idx - 1) <- tmp;
      bubble (idx - 1)
    end else idx
  in
  let updated = bubble i in
  if updated <> i then begin
    let old = node.indices in
    let len = String.length old in
    let b = Bytes.create len in
    for j = 0 to updated - 1 do
      Bytes.set b j (String.get old j)
    done;
    Bytes.set b updated (String.get old i);
    for j = updated + 1 to i do
      Bytes.set b j (String.get old (j - 1))
    done;
    for j = i + 1 to len - 1 do
      Bytes.set b j (String.get old j)
    done;
    node.indices <- Bytes.to_string b
  end;
  updated

(* Insert a route at a node, starting from an empty-prefix child node.
   Returns the leaf node where the value was stored. *)

let rec insert_route node prefix value =
  match Route.find_wildcard prefix with
  | Error _ as e -> e
  | Ok None ->
    node.value <- Some value;
    set_prefix node (Escape.slice_to_owned prefix);
    Ok node
  | Ok (Some w) -> (
    let wildcard_len = w.end_ - w.start in
    if Escape.slice_get prefix (w.start + 1) = '*' then begin
      if w.end_ <> Escape.slice_length prefix then
        Error (Router_error.Invalid_route "catch-all not at end")
      else begin
        let prefix =
          if w.start > 0 then begin
            set_prefix node (Escape.slice_to_owned (Escape.slice_until prefix w.start));
            Escape.slice_off prefix w.start
          end else prefix
        in
        let child =
          add_child node
            {
              (node_with_prefix (Escape.slice_to_owned prefix) (default_node ())) with
              node_type = Catch_all;
              value = Some value;
              priority = 1;
            }
        in
        node.wild_child <- true;
        Ok node.children.(child)
      end
    end else begin
      let prefix =
        if w.start > 0 then begin
          set_prefix node (Escape.slice_to_owned (Escape.slice_until prefix w.start));
          Escape.slice_off prefix w.start
        end else prefix
      in
      let terminator =
        match slice_index_from prefix '/' 0 with
        | -1 -> Escape.slice_length prefix
        | i -> i + 1
      in
      let wildcard_slice = Escape.slice_until prefix wildcard_len in
      let suffix = Escape.slice_off (Escape.slice_until prefix terminator) wildcard_len in
      let prefix = Escape.slice_off prefix terminator in
      match Route.find_wildcard suffix with
      | Ok (Some _) -> Error (Router_error.Invalid_route "invalid parameter segment")
      | Error _ as e -> e
      | Ok None ->
        let has_suffix = not (is_empty_or_slash suffix) in
        let child =
          add_child node
            {
              (node_with_prefix (Escape.slice_to_owned wildcard_slice) (default_node ())) with
              node_type = Param { suffix = has_suffix };
              priority = 1;
            }
        in
        node.wild_child <- true;
        let node = node.children.(child) in
        let node =
          if Escape.slice_length suffix > 0 then begin
            let child =
              add_suffix_child node
                {
                  (node_with_prefix (Escape.slice_to_owned suffix) (default_node ())) with
                  node_type = Static;
                  priority = 1;
                }
            in
            node.children.(child)
          end else node
        in
        if Escape.slice_length prefix = 0 then begin
          node.value <- Some value;
          Ok node
        end else if Escape.slice_get prefix 0 <> '{' || Escape.slice_is_escaped prefix 0 then begin
          node.indices <- append_char node.indices (Escape.slice_get prefix 0);
          let child = add_child node { (default_node ()) with priority = 1 } in
          insert_route node.children.(child) prefix value
        end else
          insert_route node prefix value
    end)

(* Path compression ------------------------------------------------------- *)

let rec compress node =
  let can_compress_parent =
    match node.node_type with
    | Static | Root -> true
    | _ -> false
  in
  if can_compress_parent && not node.wild_child && Option.is_none node.value && Array.length node.children = 1 then begin
    let child = Array.unsafe_get node.children 0 in
    if child.node_type = Static then begin
      set_prefix node (Escape.append node.prefix child.prefix);
      node.children <- child.children;
      node.indices <- child.indices;
      node.wild_child <- child.wild_child;
      node.value <- child.value;
      node.remapping <- child.remapping;
      compress node
    end else compress child
  end else Array.iter compress node.children

(* Public insertion ------------------------------------------------------- *)

let insert t route value =
  match Route.normalize route with
  | Error _ as e -> e
  | Ok (norm_route, remapping) ->
    let remaining = Escape.full norm_route in
    t.root.priority <- t.root.priority + 1;
    if t.root.value = None && Array.length t.root.children = 0 then begin
      match insert_route t.root remaining value with
      | Ok last ->
        last.remapping <- remapping;
        t.root.node_type <- Root;
        Ok ()
      | Error _ as e -> e
    end else
      let rec walk current parent_opt remaining =
        let current_prefix = Escape.full current.prefix in
        let common_prefix = Escape.common_prefix remaining current_prefix in

        (* Split the current node if its prefix is longer than the common prefix. *)
        if Escape.length current.prefix > common_prefix then begin
          let suffix = Escape.slice_off current_prefix common_prefix in
          let child_prefix = Escape.slice_to_owned suffix in
          let child =
            {
              current with
              prefix = child_prefix;
              prefix_str = Escape.to_string child_prefix;
              prefix_len = Escape.length child_prefix;
              priority = current.priority - 1;
              node_type = Static;
            }
          in
          current.children <- [| child |];
          current.indices <- char_to_string (Escape.slice_get suffix 0);
          set_prefix current (Escape.slice_to_owned (Escape.slice_until current_prefix common_prefix));
          current.wild_child <- false;
          current.value <- None;
          current.remapping <- [];
          walk current parent_opt remaining
        end else if Escape.slice_length remaining = common_prefix then begin
          if current.value <> None then
            Error (Router_error.Conflict (Escape.to_string current.prefix))
          else begin
            current.value <- Some value;
            current.remapping <- remapping;
            Ok ()
          end
        end else begin
          let common_remaining = remaining in
          let remaining = Escape.slice_off remaining common_prefix in
          let next = Escape.slice_get remaining 0 in

          match current.node_type with
          | Param { suffix = has_suffix } ->
            let terminator =
              match slice_index_from remaining '/' 0 with
              | -1 -> Escape.slice_length remaining
              | i -> i + 1
            in
            let suffix = Escape.slice_until remaining terminator in
            let extra_trailing_slash = ref false in
            let matched = ref None in
            for i = 0 to Array.length current.children - 1 do
              let child = current.children.(i) in
              let child_prefix = Escape.full child.prefix in
              if slice_equal child_prefix suffix then matched := Some i
              else if Escape.slice_length child_prefix <= Escape.slice_length suffix then begin
                let common = Escape.slice_until suffix (Escape.slice_length child_prefix) in
                let rem = Escape.slice_off suffix (Escape.slice_length child_prefix) in
                if slice_equal common child_prefix
                   && Escape.slice_length rem = 1
                   && Escape.slice_get rem 0 = '/'
                then extra_trailing_slash := true
              end else begin
                let common = Escape.slice_until child_prefix (Escape.slice_length suffix) in
                let rem = Escape.slice_off child_prefix (Escape.slice_length suffix) in
                if slice_equal common suffix
                   && Escape.slice_length rem = 1
                   && Escape.slice_get rem 0 = '/'
                then extra_trailing_slash := true
              end
            done;

            (match !matched with
            | Some i ->
              current.children.(i).priority <- current.children.(i).priority + 1;
              walk current.children.(i) (Some current) remaining
            | None ->
              let prefix_suffix_ok () =
                if not !extra_trailing_slash && not (is_empty_or_slash suffix) then
                  match parent_opt with
                  | Some parent when prefix_wild_child_in_segment parent ->
                    Error (Router_error.Conflict "prefix-suffix conflict")
                  | _ -> Ok ()
                else Ok ()
              in
              match prefix_suffix_ok () with
              | Error _ as e -> e
              | Ok () -> (
                match Route.find_wildcard suffix with
                | Ok (Some _) -> Error (Router_error.Invalid_route "invalid parameter segment")
                | Error _ as e -> e
                | Ok None ->
                  let child =
                    add_suffix_child current
                      {
                        (node_with_prefix (Escape.slice_to_owned suffix) (default_node ())) with
                        node_type = Static;
                        priority = 1;
                      }
                  in
                  let has_suffix = has_suffix || not (is_empty_or_slash suffix) in
                  current.node_type <- Param { suffix = has_suffix };
                  let current = current.children.(child) in
                  if terminator = Escape.slice_length remaining then begin
                    current.value <- Some value;
                    current.remapping <- remapping;
                    Ok ()
                  end else begin
                    let remaining = Escape.slice_off remaining terminator in
                    if Escape.slice_get remaining 0 <> '{' || Escape.slice_is_escaped remaining 0 then begin
                      let child = add_child current { (default_node ()) with priority = 1 } in
                      current.indices <- append_char current.indices (Escape.slice_get remaining 0);
                      match insert_route current.children.(child) remaining value with
                      | Ok last ->
                        last.remapping <- remapping;
                        Ok ()
                      | Error _ as e -> e
                    end else
                      match insert_route current remaining value with
                      | Ok last ->
                        last.remapping <- remapping;
                        Ok ()
                      | Error _ as e -> e
                  end))
          | _ ->
            (* Find a matching static child. *)
            let matched = ref None in
            for i = 0 to String.length current.indices - 1 do
              if next = String.get current.indices i then
                if not ((next = '{' || next = '}') && not (Escape.slice_is_escaped remaining 0)) then
                  matched := Some i
            done;

            match !matched with
            | Some i ->
              let new_i = update_child_priority current i in
              walk current.children.(new_i) (Some current) remaining
            | None ->
              if
                (next <> '{' || Escape.slice_is_escaped remaining 0)
                && current.node_type <> Catch_all
              then begin
                let terminator =
                  match slice_index_from remaining '/' 0 with
                  | -1 -> Escape.slice_length remaining
                  | i -> i
                in
                (match Route.find_wildcard (Escape.slice_until remaining terminator) with
                | Ok (Some w) ->
                  let suffix = Escape.slice_off (Escape.slice_until remaining terminator) w.end_ in
                  if w.start > 0 && suffix_wild_child_in_segment current then
                    Error (Router_error.Conflict "prefix-suffix conflict")
                  else if
                    not (is_empty_or_slash suffix)
                    && prefix_wild_child_in_segment current
                  then
                    Error (Router_error.Conflict "prefix-suffix conflict")
                  else begin
                    current.indices <- append_char current.indices next;
                    let child = add_child current (default_node ()) in
                    let child = update_child_priority current child in
                    match insert_route current.children.(child) remaining value with
                    | Ok last ->
                      last.remapping <- remapping;
                      Ok ()
                    | Error _ as e -> e
                  end
                | Error _ as e -> e
                | Ok None ->
                  current.indices <- append_char current.indices next;
                  let child = add_child current (default_node ()) in
                  let child = update_child_priority current child in
                  match insert_route current.children.(child) remaining value with
                  | Ok last ->
                    last.remapping <- remapping;
                    Ok ()
                  | Error _ as e -> e)
              end else begin
                (* Inserting a wildcard. *)
                if current.wild_child then begin
                  let wild_child = Array.length current.children - 1 in
                  current.children.(wild_child).priority <- current.children.(wild_child).priority + 1;
                  let wc = current.children.(wild_child) in
                  let wc_prefix = Escape.full wc.prefix in
                  if
                    Escape.slice_length remaining < Escape.slice_length wc_prefix
                    || not (slice_equal wc_prefix (Escape.slice_until remaining (Escape.slice_length wc_prefix)))
                  then
                    Error (Router_error.Conflict "wildcard mismatch")
                  else if wc.node_type = Catch_all then
                    Error (Router_error.Conflict "catch-all conflict")
                  else begin
                    let parent = current in
                    if
                      not (prefix_ends_with_slash parent.prefix)
                      && (match wc.node_type with
                         | Param { suffix = true } -> true
                         | _ -> false)
                    then begin
                      let terminator =
                        match slice_index_from remaining '/' 0 with
                        | -1 -> Escape.slice_length remaining
                        | i -> i + 1
                      in
                      match Route.find_wildcard (Escape.slice_until remaining terminator) with
                      | Ok (Some w) ->
                        let suffix = Escape.slice_off remaining w.end_ in
                        if is_empty_or_slash suffix then
                          Error (Router_error.Conflict "prefix-suffix conflict")
                        else
                          walk wc (Some current) remaining
                      | _ -> walk wc (Some current) remaining
                    end else
                      walk wc (Some current) remaining
                  end
                end else begin
                  let wildcard_conflicts_ok () =
                    match Route.find_wildcard remaining with
                    | Ok (Some w) ->
                      let suffix = Escape.slice_off remaining w.end_ in
                      if not (is_empty_or_slash suffix) && prefix_wild_child_in_segment current then
                        Error (Router_error.Conflict "prefix-suffix conflict")
                      else
                        (match common_prefix with
                        | 0 -> Ok ()
                        | cp ->
                          let i = cp - 1 in
                          if Escape.slice_get common_remaining i <> '/' && suffix_wild_child_in_segment current then
                            Error (Router_error.Conflict "prefix-suffix conflict")
                          else Ok ())
                    | _ -> Ok ()
                  in
                  match wildcard_conflicts_ok () with
                  | Error _ as e -> e
                  | Ok () ->
                    (match insert_route current remaining value with
                    | Ok last ->
                      last.remapping <- remapping;
                      Ok ()
                    | Error _ as e -> e)
                end
              end
        end
      in
      walk t.root None remaining

(* Matching ---------------------------------------------------------------- *)

type 'a skipped = {
  node : 'a node;
  src : string;
  off : int;
  len : int;
  params : (string * int * int) list;
}

type path = {
  src : string;
  mutable off : int;
  mutable len : int;
}

type param_acc = {
  srcs : string array;
  offs : int array;
  lens : int array;
}

let[@inline always][@zero_alloc] path_get p i = String.unsafe_get p.src (p.off + i)
let[@inline always][@zero_alloc] path_length p = p.len

let[@inline always] path_drop p n =
  p.off <- p.off + n;
  p.len <- p.len - n

let path_snapshot p = { src = p.src; off = p.off; len = p.len }

let rec path_prefix_equal_loop p prefix len i =
  i >= len
  || (path_get p i = String.unsafe_get prefix i
      && path_prefix_equal_loop p prefix len (i + 1))

let[@inline always][@zero_alloc opt] path_prefix_equal p prefix len =
  if p.len < len then false
  else if len = 0 then true
  else if len = 1 then path_get p 0 = String.unsafe_get prefix 0
  else if len = 2 then
    path_get p 0 = String.unsafe_get prefix 0
    && path_get p 1 = String.unsafe_get prefix 1
  else path_prefix_equal_loop p prefix len 0

let rec path_index_loop src off len c i =
  if i < len && String.unsafe_get src (off + i) <> c then
    path_index_loop src off len c (i + 1)
  else i

let[@inline always][@zero_alloc opt] path_index p c =
  let off = p.off in
  let src = p.src in
  let len = p.len in
  let i = path_index_loop src off len c 0 in
  if i = len then -1 else i

let rec path_sub_equal_escape_loop p off len prefix i =
  i >= len
  || (path_get p (off + i) = String.unsafe_get prefix i
      && path_sub_equal_escape_loop p off len prefix (i + 1))

let[@zero_alloc opt] path_sub_equal_escape p off len prefix prefix_len =
  if len <> prefix_len then false
  else path_sub_equal_escape_loop p off len prefix 0

let rec path_ends_with_loop a b off i =
  i >= b.len
  || (path_get a (off + i) = path_get b i
      && path_ends_with_loop a b off (i + 1))

let[@zero_alloc opt] path_ends_with a b =
  if a.len < b.len then false
  else
    let off = a.len - b.len in
    path_ends_with_loop a b off 0

let rec find_static_child_loop s len next i =
  if i >= len then -1
  else if String.unsafe_get s i = next then i
  else find_static_child_loop s len next (i + 1)

let[@inline always][@zero_alloc opt] find_static_child node next =
  let s = node.indices in
  let len = String.length s in
  if len = 0 then -1
  else if len = 1 then
    if String.unsafe_get s 0 = next then 0 else -1
  else if len = 2 then
    if String.unsafe_get s 0 = next then 0
    else if String.unsafe_get s 1 = next then 1
    else -1
  else if len = 3 then
    if String.unsafe_get s 0 = next then 0
    else if String.unsafe_get s 1 = next then 1
    else if String.unsafe_get s 2 = next then 2
    else -1
  else find_static_child_loop s len next 0

let catch_all_key prefix_str prefix_len =
  if prefix_len < 3 then ""
  else String.sub prefix_str 2 (prefix_len - 3)

let rec walk node path backtracking params skipped =
  let prefix = node.prefix_str in
  let prefix_len = node.prefix_len in
  if prefix_len > 0 && not (path_prefix_equal path prefix prefix_len) then
    backtrack path params skipped
  else if path.len <= prefix_len then
    match node.value with
    | Some value ->
      Ok (value, Params.of_raw ~params ~remapping:node.remapping ~catch_all:None)
    | None -> backtrack path params skipped
  else if not backtracking then
    if node.wild_child then begin
      let sk = { node; src = path.src; off = path.off; len = path.len; params } in
      path_drop path prefix_len;
      let next = path_get path 0 in
      let i = find_static_child node next in
      if i >= 0 then
        walk (Array.unsafe_get node.children i) path false params
          (sk :: skipped)
      else
        handle_wildcard node path params skipped
    end else begin
      path_drop path prefix_len;
      let next = path_get path 0 in
      let i = find_static_child node next in
      if i >= 0 then
        walk (Array.unsafe_get node.children i) path false params skipped
      else
        handle_wildcard node path params skipped
    end
  else begin
    path_drop path prefix_len;
    handle_wildcard node path params skipped
  end

and[@inline always] handle_wildcard node path params skipped =
  if not node.wild_child then
    backtrack path params skipped
  else
    let wc = Array.unsafe_get node.children (Array.length node.children - 1) in
    match wc.node_type with
    | Param { suffix = false } -> param_no_suffix wc path params skipped
    | Param { suffix = true } -> param_with_suffix wc path params skipped
    | Catch_all -> catch_all wc path params skipped
    | _ -> backtrack path params skipped

and[@inline always] param_no_suffix node path params skipped =
  let idx = path_index path '/' in
  if idx = 0 then backtrack path params skipped
  else if idx > 0 then
    let n = Array.length node.children in
    if n <> 1 then
      backtrack path params skipped
    else begin
      path_drop path idx;
      walk (Array.unsafe_get node.children 0) path false ((path.src, path.off - idx, idx) :: params) skipped
    end
  else
    match node.value with
    | Some value ->
      Ok (value, Params.of_raw ~params:((path.src, path.off, path.len) :: params) ~remapping:node.remapping ~catch_all:None)
    | None -> backtrack path params skipped

and param_with_suffix node path params skipped =
  let slash = path_index path '/' in
  let terminator =
    if slash = 0 then -1
    else if slash > 0 then slash + 1
    else path.len
  in
  if terminator < 0 then
    backtrack path params skipped
  else
    let matched = ref None in
    let n = Array.length node.children in
    for i = 0 to n - 1 do
      let child = Array.unsafe_get node.children i in
      let child_prefix = child.prefix_str in
      let child_prefix_len = child.prefix_len in
      if child_prefix_len >= terminator then ()
      else begin
        let suffix_start = terminator - child_prefix_len in
        if path_sub_equal_escape path suffix_start child_prefix_len child_prefix child_prefix_len then
          matched := Some (suffix_start, i)
      end
    done;
    match !matched with
    | Some (suffix_start, i) ->
      path_drop path suffix_start;
      walk (Array.unsafe_get node.children i) path false ((path.src, path.off - suffix_start, suffix_start) :: params) skipped
    | None ->
      if slash < 0 && Option.is_some node.value then begin
        let value = Option.get node.value in
        Ok (value, Params.of_raw ~params:((path.src, path.off, path.len) :: params) ~remapping:node.remapping ~catch_all:None)
      end else
        backtrack path params skipped

and catch_all node path params skipped =
  match node.value with
  | Some value ->
    let key = catch_all_key node.prefix_str node.prefix_len in
    let catch_all =
      if key = "" then None
      else Some (key, path.src, path.off, path.len)
    in
    Ok (value, Params.of_raw ~params ~remapping:node.remapping ~catch_all)
  | None -> Error Router_error.Not_found

and backtrack path params skipped =
  match skipped with
  | [] -> Error Router_error.Not_found
  | sk :: rest ->
    let sk_path = { src = sk.src; off = sk.off; len = sk.len } in
    if path_ends_with sk_path path then
      walk sk.node sk_path true sk.params rest
    else
      backtrack path params rest

let[@inline always] at_string t path =
  let p = { src = path; off = 0; len = String.length path } in
  walk t.root p false [] []

let[@inline always] at t path = at_string t (Slice.to_string path)

let compress t = compress t.root

(* Removal ---------------------------------------------------------------- *)

let array_remove arr i =
  let len = Array.length arr in
  if i < 0 || i >= len then invalid_arg "Tree.array_remove";
  Array.init (len - 1) (fun j -> if j < i then arr.(j) else arr.(j + 1))

let string_remove_char s i =
  let len = String.length s in
  if i < 0 || i >= len then invalid_arg "Tree.string_remove_char";
  String.init (len - 1) (fun j -> if j < i then String.get s j else String.get s (j + 1))

let is_param_node_type = function
  | Param _ -> true
  | _ -> false

let remove_child node i remapping =
  let child = node.children.(i) in
  if child.remapping <> remapping then None
  else
    let value = child.value in
    if Array.length child.children = 0 then begin
      node.children <- array_remove node.children i;
      (match child.node_type with
      | Static when not (is_param_node_type node.node_type) ->
        node.indices <- string_remove_char node.indices i
      | _ ->
        node.wild_child <- false);
      value
    end else begin
      child.value <- None;
      value
    end

let rec remove_walk node remaining remapping =
  if Escape.slice_length remaining <= Escape.length node.prefix then
    None
  else
    let prefix = Escape.slice_until remaining (Escape.length node.prefix) in
    if not (slice_equal prefix (Escape.full node.prefix)) then
      None
    else
      let rest = Escape.slice_off remaining (Escape.length node.prefix) in
      let next = Escape.slice_get rest 0 in
      match node.node_type with
      | Param { suffix = _ } ->
        let terminator =
          match slice_index_from rest '/' 0 with
          | -1 -> Escape.slice_length rest
          | i -> i + 1
        in
        let suffix = Escape.slice_until rest terminator in
        let rec find_suffix i =
          if i >= Array.length node.children then None
          else if slice_equal (Escape.full node.children.(i).prefix) suffix then Some i
          else find_suffix (i + 1)
        in
        (match find_suffix 0 with
        | None -> None
        | Some i ->
          if terminator = Escape.slice_length rest then
            remove_child node i remapping
          else
            remove_walk node.children.(i) rest remapping)
      | _ ->
        (match find_static_child node next with
        | -1 ->
          if not node.wild_child then
            None
          else
            let wc_i = Array.length node.children - 1 in
            let wc = node.children.(wc_i) in
            if slice_equal (Escape.full wc.prefix) rest then
              remove_child node wc_i remapping
            else
              remove_walk wc rest remapping
        | i ->
          let child = node.children.(i) in
          if slice_equal (Escape.full child.prefix) rest then
            remove_child node i remapping
          else
            remove_walk child rest remapping)

let remove t route =
  match Route.normalize route with
  | Error _ -> None
  | Ok (norm_route, remapping) ->
    let remaining = Escape.full norm_route in
    if slice_equal remaining (Escape.full t.root.prefix) then begin
      let value = t.root.value in
      t.root.value <- None;
      if Array.length t.root.children = 0 then begin
        set_prefix t.root empty_prefix;
        t.root.priority <- 0;
        t.root.wild_child <- false;
        t.root.indices <- "";
        t.root.children <- [||];
        t.root.remapping <- [];
      end;
      value
    end else
      remove_walk t.root remaining remapping

(* Merge ------------------------------------------------------------------ *)

let merge ~into from =
  let errors = ref [] in
  let queue = Queue.create () in
  Queue.add (from.root.prefix, from.root) queue;
  while not (Queue.is_empty queue) do
    let prefix, node = Queue.take queue in
    let prefix = Route.denormalize prefix node.remapping in
    (match node.value with
    | Some value ->
      (match insert into prefix value with
      | Ok () -> ()
      | Error e -> errors := e :: !errors)
    | None -> ());
    Array.iter
      (fun child ->
        let prefix = Escape.append prefix child.prefix in
        Queue.add (prefix, child) queue)
      node.children
  done;
  match !errors with
  | [] -> Ok ()
  | errs -> Error (Router_error.Conflicts (List.rev errs))
