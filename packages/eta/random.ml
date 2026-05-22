let int_in_range random ~min ~max =
  if max <= min then min
  else
    let span = max - min + 1 in
    min + int_of_float (Capabilities.random_float random (float_of_int span))

let float_in_range random ~min ~max =
  if max <= min then min
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
  let choices = List.filter (fun (_, weight) -> weight > 0.0) choices in
  let total = List.fold_left (fun acc (_, weight) -> acc +. weight) 0.0 choices in
  if total <= 0.0 then None
  else
    let target = Capabilities.random_float random total in
    let rec loop seen = function
      | [] -> None
      | (value, weight) :: rest ->
          let seen = seen +. weight in
          if target < seen then Some value else loop seen rest
    in
    loop 0.0 choices
