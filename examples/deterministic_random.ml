open Eta

type profile = {
  dice : int;
  ratio : float;
  coin : bool;
  shuffled : int list;
  weighted : string option;
  sample : int option;
}

let draw random =
  {
    dice = Random.int_in_range random ~min:10 ~max:20;
    ratio = Random.float_in_range random ~min:1.0 ~max:3.0;
    coin = Random.bool random;
    shuffled = Random.shuffle random [ 1; 2; 3; 4 ];
    weighted =
      Random.weighted_choice random [ ("a", 1.0); ("b", 2.0); ("c", 1.0) ];
    sample = Random.sample random [ 10; 20; 30; 40 ];
  }

let format_ints values =
  values |> List.map string_of_int |> String.concat ","

let format_option format = function
  | None -> "none"
  | Some value -> format value

let () =
  let first = Capabilities.random_of_seed 7 in
  let second = Capabilities.random_of_seed 7 in
  let first_profile = draw first in
  let second_profile = draw second in
  Capabilities.random_set_seed first 7;
  let replay = draw first in
  let same_seed_replays =
    first_profile = second_profile && first_profile = replay
  in
  if same_seed_replays then
    Format.printf
      "random:dice=%d ratio=%.3f coin=%b shuffle=%s weighted=%s sample=%s \
       replay=%b@."
      first_profile.dice first_profile.ratio first_profile.coin
      (format_ints first_profile.shuffled)
      (format_option Fun.id first_profile.weighted)
      (format_option string_of_int first_profile.sample)
      same_seed_replays
  else (
    Format.eprintf "random produced non-replayable profile@.";
    exit 1)
