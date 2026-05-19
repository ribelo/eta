type 'a fake_file = {
  name : string;
  values : 'a list;
  mutable closed : bool;
}

let open_log : string list ref = ref []
let close_log : string list ref = ref []

let reset () =
  open_log := [];
  close_log := []

let open_file name values =
  open_log := name :: !open_log;
  { name; values; closed = false }

let close_file file =
  file.closed <- true;
  close_log := file.name :: !close_log

let close_count name =
  List.length (List.filter (String.equal name) !close_log)

let default_chunk_size = 4096

let chunks_of_list size xs =
  if size <= 0 then invalid_arg "chunks_of_list: size must be positive";
  let rec loop current current_len acc = function
    | [] ->
        let acc =
          match List.rev current with
          | [] -> acc
          | chunk -> chunk :: acc
        in
        List.rev acc
    | x :: rest when current_len = size ->
        loop [ x ] 1 (List.rev current :: acc) rest
    | x :: rest -> loop (x :: current) (current_len + 1) acc rest
  in
  loop [] 0 [] xs

let take n xs =
  let rec loop n acc = function
    | _ when n <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> loop (n - 1) (x :: acc) rest
  in
  loop n [] xs

let range start stop =
  let rec loop acc n =
    if n < start then acc else loop (n :: acc) (n - 1)
  in
  loop [] stop
