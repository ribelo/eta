let rec int_in_range random ~min ~max =
  if max < min then invalid_arg "Eta.Random.int_in_range: min > max"
  else if max = min then min
  else
    let min64 = Int64.of_int min in
    let max64 = Int64.of_int max in
    let diff = Int64.sub max64 min64 in
    if Int64.compare diff (Int64.of_int max_int) < 0 then
      let span = Int64.to_int (Int64.add diff 1L) in
      min + int_of_float (Capabilities.random_float random (float_of_int span))
    else
      let mid = Int64.to_int (Int64.div (Int64.add min64 max64) 2L) in
      let mid64 = Int64.of_int mid in
      let lower_count = Int64.add (Int64.sub mid64 min64) 1L in
      let upper_count = Int64.sub max64 mid64 in
      let lower_weight = Int64.to_float lower_count in
      let total_weight = lower_weight +. Int64.to_float upper_count in
      if Capabilities.random_float random total_weight < lower_weight then
        int_in_range random ~min ~max:mid
      else int_in_range random ~min:(mid + 1) ~max

let float_in_range random ~min ~max =
  if max < min then invalid_arg "Eta.Random.float_in_range: min > max"
  else if max = min then min
  else min +. Capabilities.random_float random (max -. min)

let bool random = int_in_range random ~min:0 ~max:1 = 1

let shuffle random list =
  let array = Array.of_list list in
  for i = Array.length array - 1 downto 1 do
    let j = int_in_range random ~min:0 ~max:i in
    let tmp = array.(i) in
    array.(i) <- array.(j);
    array.(j) <- tmp
  done;
  Array.to_list array

let sample random = function
  | [] -> None
  | list ->
      let index = int_in_range random ~min:0 ~max:(List.length list - 1) in
      Some (List.nth list index)

let weighted_choice random choices =
  let total =
    List.fold_left
      (fun acc (_, weight) -> if weight > 0.0 then acc +. weight else acc)
      0.0 choices
  in
  if total <= 0.0 then None
  else
    let target = Capabilities.random_float random total in
    let rec loop seen = function
      | [] -> None
      | (value, weight) :: rest ->
          if weight <= 0.0 then loop seen rest
          else
            let seen = seen +. weight in
            if target < seen then Some value else loop seen rest
    in
    loop 0.0 choices
