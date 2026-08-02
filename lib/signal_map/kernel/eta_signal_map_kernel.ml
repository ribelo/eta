(** Clean-room weight-balanced tree based on:
    Nievergelt and Reingold, "Binary search trees of bounded balance", 1973;
    Hirai and Yamamoto, "Balancing weight-balanced trees", 2011.

    Base Map is a behavioral and comparison-count oracle only. This module does
    not use or copy Base source. *)

module type Ordered_type = sig
  type t

  val compare : t -> t -> int
end

type 'a change =
  | Left of 'a
  | Right of 'a
  | Changed of 'a * 'a

module Make (Order : Ordered_type) = struct
  type key = Order.t

  type 'a tree =
    | Empty
    | Node of {
        left : 'a tree;
        key : key;
        data : 'a;
        right : 'a tree;
        size : int;
      }

  type 'a t = 'a tree

  let empty = Empty
  let is_empty = function Empty -> true | Node _ -> false
  let cardinal = function Empty -> 0 | Node node -> node.size
  let weight tree = cardinal tree + 1

  let make left key data right =
    Node { left; key; data; right; size = cardinal left + cardinal right + 1 }

  let singleton key data = make Empty key data Empty

  let too_heavy heavy light = (2 * weight heavy) > (5 * weight light)
  let single_rotation inner outer = (2 * weight inner) < (3 * weight outer)

  let rotate_left left key data = function
    | Empty -> invalid_arg "Eta_signal_map: invalid left rotation"
    | Node right ->
        if single_rotation right.left right.right then
          make (make left key data right.left) right.key right.data right.right
        else
          (match right.left with
          | Empty -> invalid_arg "Eta_signal_map: invalid double left rotation"
          | Node pivot ->
              make
                (make left key data pivot.left)
                pivot.key pivot.data
                (make pivot.right right.key right.data right.right))

  let rotate_right left key data right =
    match left with
    | Empty -> invalid_arg "Eta_signal_map: invalid right rotation"
    | Node left ->
        if single_rotation left.right left.left then
          make left.left left.key left.data (make left.right key data right)
        else
          (match left.right with
          | Empty -> invalid_arg "Eta_signal_map: invalid double right rotation"
          | Node pivot ->
              make
                (make left.left left.key left.data pivot.left)
                pivot.key pivot.data
                (make pivot.right key data right))

  let balance left key data right =
    if too_heavy right left then rotate_left left key data right
    else if too_heavy left right then rotate_right left key data right
    else make left key data right

  let rec join left key data right =
    if too_heavy left right then
      match left with
      | Empty -> make left key data right
      | Node node ->
          balance node.left node.key node.data
            (join node.right key data right)
    else if too_heavy right left then
      match right with
      | Empty -> make left key data right
      | Node node ->
          balance (join left key data node.left) node.key node.data node.right
    else make left key data right

  let rec find_opt key = function
    | Empty -> None
    | Node node ->
        let order = Order.compare key node.key in
        if order = 0 then Some node.data
        else if order < 0 then find_opt key node.left
        else find_opt key node.right

  let mem key map = Option.is_some (find_opt key map)

  let rec set key data = function
    | Empty -> singleton key data
    | (Node node as map) ->
        let order = Order.compare key node.key in
        if order = 0 then
          if data == node.data then map
          else make node.left node.key data node.right
        else if order < 0 then
          let left = set key data node.left in
          if left == node.left then map
          else balance left node.key node.data node.right
        else
          let right = set key data node.right in
          if right == node.right then map
          else balance node.left node.key node.data right

  let rec remove_min = function
    | Empty -> invalid_arg "Eta_signal_map: remove_min on empty map"
    | Node { left = Empty; key; data; right; _ } -> (key, data, right)
    | Node node ->
        let key, data, left = remove_min node.left in
        (key, data, balance left node.key node.data node.right)

  let concat left right =
    match (left, right) with
    | Empty, map | map, Empty -> map
    | _ ->
        let key, data, right = remove_min right in
        join left key data right

  let rec remove key = function
    | Empty as map -> map
    | (Node node as map) ->
        let order = Order.compare key node.key in
        if order = 0 then concat node.left node.right
        else if order < 0 then
          let left = remove key node.left in
          if left == node.left then map
          else balance left node.key node.data node.right
        else
          let right = remove key node.right in
          if right == node.right then map
          else balance node.left node.key node.data right

  let update key f map =
    match f (find_opt key map) with
    | None -> remove key map
    | Some data -> set key data map

  let of_list bindings =
    let add map (key, data) =
      if mem key map then Error (`Duplicate_key key) else Ok (set key data map)
    in
    List.fold_left
      (fun result binding -> Result.bind result (fun map -> add map binding))
      (Ok empty) bindings

  let fold f map init =
    let rec loop map acc =
      match map with
      | Empty -> acc
      | Node node ->
          let acc = loop node.left acc in
          let acc = f node.key node.data acc in
          loop node.right acc
    in
    loop map init

  let to_list map = fold (fun key data tail -> (key, data) :: tail) map [] |> List.rev

  let same_physical left right = Obj.repr left == Obj.repr right

  let rec map f = function
    | Empty -> Empty
    | Node node as old_map ->
        let left = map f node.left in
        let data = f node.data in
        let right = map f node.right in
        if
          same_physical left node.left
          && same_physical data node.data
          && same_physical right node.right
        then Obj.magic old_map
        else make left node.key data right

  let rec filter_mapi f = function
    | Empty -> Empty
    | Node node as old_map ->
        let left = filter_mapi f node.left in
        let choice = f node.key node.data in
        let right = filter_mapi f node.right in
        match choice with
        | None -> concat left right
        | Some data ->
            if
              same_physical left node.left
              && same_physical data node.data
              && same_physical right node.right
            then Obj.magic old_map
            else join left node.key data right

  let equal data_equal left right =
    let rec loop left right =
      match (left, right) with
      | [], [] -> true
      | (left_key, left_data) :: left, (right_key, right_data) :: right ->
          Order.compare left_key right_key = 0
          && data_equal left_data right_data
          && loop left right
      | [], _ | _, [] -> false
    in
    loop (to_list left) (to_list right)

  type 'a token =
    | Tree of 'a tree
    | Item of key * 'a

  let expand tree tail =
    match tree with
    | Empty -> tail
    | Node node ->
        Tree node.left :: Item (node.key, node.data) :: Tree node.right :: tail

  let rec remove_empty = function
    | Tree Empty :: tail -> remove_empty tail
    | tokens -> tokens

  let rec drop_shared left right =
    let left = remove_empty left in
    let right = remove_empty right in
    match (left, right) with
    | Tree left_tree :: left_tail, Tree right_tree :: right_tail ->
        if left_tree == right_tree then drop_shared left_tail right_tail
        else
          let left_weight = weight left_tree in
          let right_weight = weight right_tree in
          if left_weight = right_weight then
            drop_shared (expand left_tree left_tail) (expand right_tree right_tail)
          else if left_weight > right_weight then
            drop_shared (expand left_tree left_tail) right
          else drop_shared left (expand right_tree right_tail)
    | Tree tree :: tail, _ -> drop_shared (expand tree tail) right
    | _, Tree tree :: tail -> drop_shared left (expand tree tail)
    | _ -> (left, right)

  let rec next_item tokens =
    match remove_empty tokens with
    | [] -> None
    | Item (key, data) :: tail -> Some (key, data, tail)
    | Tree tree :: tail -> next_item (expand tree tail)

  let cursor_diff compare left right ~init ~f =
    let rec loop left right acc =
      let left, right = drop_shared left right in
      match (next_item left, next_item right) with
      | None, None -> acc
      | Some (key, data, left), None ->
          loop left [] (f acc key (Left data))
      | None, Some (key, data, right) ->
          loop [] right (f acc key (Right data))
      | ( Some (left_key, left_data, left_tail),
          Some (right_key, right_data, right_tail) ) ->
          let order = compare left_key right_key in
          if order = 0 then
            let acc =
              if left_data == right_data then acc
              else f acc left_key (Changed (left_data, right_data))
            in
            loop left_tail right_tail acc
          else if order < 0 then
            loop left_tail right (f acc left_key (Left left_data))
          else loop left right_tail (f acc right_key (Right right_data))
    in
    loop [ Tree left ] [ Tree right ] init

  let fold_symmetric_diff_with compare left right ~init ~f =
    let add_all map change acc =
      fold (fun key data acc -> f acc key (change data)) map acc
    in
    let rec loop left right acc =
      if left == right then acc
      else
        match (left, right) with
        | Empty, right -> add_all right (fun data -> Right data) acc
        | left, Empty -> add_all left (fun data -> Left data) acc
        | Node left_node, Node right_node ->
            let order = compare left_node.key right_node.key in
            if order = 0 then
              let acc = loop left_node.left right_node.left acc in
              let acc =
                if left_node.data == right_node.data then acc
                else
                  f acc left_node.key
                    (Changed (left_node.data, right_node.data))
              in
              loop left_node.right right_node.right acc
            else cursor_diff compare left right ~init:acc ~f
    in
    loop left right init

  let fold_symmetric_diff left right ~init ~f =
    fold_symmetric_diff_with Order.compare left right ~init ~f

  let fold_symmetric_diff_counted left right ~on_compare ~init ~f =
    let compare left right =
      on_compare ();
      Order.compare left right
    in
    fold_symmetric_diff_with compare left right ~init ~f

  let check_invariants map =
    let fail path message = Error (Printf.sprintf "%s: %s" path message) in
    let rec loop path lower upper = function
      | Empty -> Ok 0
      | Node node ->
          let above_lower =
            match lower with
            | None -> true
            | Some key -> Order.compare key node.key < 0
          in
          let below_upper =
            match upper with
            | None -> true
            | Some key -> Order.compare node.key key < 0
          in
          if not above_lower then fail path "key is not above its lower bound"
          else if not below_upper then fail path "key is not below its upper bound"
          else
            match loop (path ^ "L") lower (Some node.key) node.left with
            | Error _ as error -> error
            | Ok left_size ->
                (match loop (path ^ "R") (Some node.key) upper node.right with
                | Error _ as error -> error
                | Ok right_size ->
                    let expected = left_size + right_size + 1 in
                    if node.size <> expected then
                      fail path
                        (Printf.sprintf "stored size %d, expected %d" node.size
                           expected)
                    else if too_heavy node.left node.right then
                      fail path "left subtree violates delta = 5/2"
                    else if too_heavy node.right node.left then
                      fail path "right subtree violates delta = 5/2"
                    else Ok expected)
    in
    match loop "root" None None map with
    | Ok _ -> Ok ()
    | Error _ as error -> error

  let node_count = cardinal

  let node_tokens map =
    let rec collect acc = function
      | Empty -> acc
      | Node node as tree ->
          collect (Obj.repr tree :: collect acc node.right) node.left
    in
    collect [] map

  let shared_node_count left right =
    let left = node_tokens left in
    node_tokens right
    |> List.fold_left
         (fun count token ->
           if List.exists (fun candidate -> candidate == token) left then count + 1
           else count)
         0
end
