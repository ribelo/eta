let percentile samples percentile =
  match samples with
  | [] -> 0
  | _ ->
      let ordered = List.sort compare samples in
      let count = List.length ordered in
      let index =
        int_of_float
          (ceil ((float_of_int percentile /. 100.0) *. float_of_int count))
        - 1
      in
      List.nth ordered (max 0 (min (count - 1) index))

let maximum = function
  | [] -> 0
  | sample :: samples -> List.fold_left max sample samples

let fields name samples =
  Printf.sprintf "%s_n=%d %s_p50_us=%d %s_p95_us=%d %s_p99_us=%d %s_max_us=%d"
    name (List.length samples) name (percentile samples 50) name
    (percentile samples 95) name (percentile samples 99) name (maximum samples)

let value_fields name samples =
  Printf.sprintf "%s_n=%d %s_p50=%d %s_p95=%d %s_p99=%d %s_max=%d" name
    (List.length samples) name (percentile samples 50) name
    (percentile samples 95) name (percentile samples 99) name (maximum samples)
