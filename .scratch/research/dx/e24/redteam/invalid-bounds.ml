open Eta

let fetch id = Effect.pure id

let reject label max_concurrent =
  try
    ignore
      (Effect.map_par ~max_concurrent fetch [ 1; 2; 3 ]
        : (int list, string) Effect.t);
    Printf.printf "%s:silently accepted\n" label
  with Invalid_argument message ->
    Printf.printf "%s:Invalid_argument(%S)\n" label message

let () =
  reject "zero" 0;
  reject "negative" (-3)
