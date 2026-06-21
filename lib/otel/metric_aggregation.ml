module Metric_key = struct
  type t = {
    name : string;
    description : string;
    unit_ : string;
    kind : Eta.Capabilities.metric_kind;
    attrs : (string * string) list;
  }

  let normalize_attrs = function
    | [] | [ _ ] as attrs -> attrs
    | attrs -> List.sort compare attrs

  let normalize (p : Eta.Meter.point) =
    {
      name = p.name;
      description = p.description;
      unit_ = p.unit_;
      kind = p.kind;
      attrs = normalize_attrs p.attrs;
    }

  let equal a b =
    String.equal a.name b.name
    && String.equal a.description b.description
    && String.equal a.unit_ b.unit_
    && a.kind = b.kind && a.attrs = b.attrs
end

type histogram_state = {
  count : int;
  sum : float;
  min : float option;
  max : float option;
  buckets : (float * int) list;
}

type summary_state = {
  count : int;
  sum : float;
  min : float option;
  max : float option;
  quantiles : (float * float) list;
}

type aggregate_value =
  | Sum of Eta.Capabilities.metric_number
  | Gauge of Eta.Capabilities.metric_number
  | Frequency of (string * int) list
  | Histogram of histogram_state
  | Summary of summary_state

let ms_to_ns_saturating ms =
  if ms <= 0 then 0
  else if ms > max_int / 1_000_000 then max_int
  else ms * 1_000_000

let float_of_number = function
  | Eta.Capabilities.Int n -> float_of_int n
  | Float f -> f

let add_number a b =
  match (a, b) with
  | Eta.Capabilities.Int a, Eta.Capabilities.Int b ->
      if (b > 0 && a > max_int - b) || (b < 0 && a < min_int - b) then
        Eta.Capabilities.Float (float_of_int a +. float_of_int b)
      else Eta.Capabilities.Int (a + b)
  | Float a, Float b -> Float (a +. b)
  | Int a, Float b -> Float (float_of_int a +. b)
  | Float a, Int b -> Float (a +. float_of_int b)

let bucket_counts boundaries samples =
  let counts = Array.make (List.length boundaries + 1) 0 in
  List.iter
    (fun sample ->
      let rec bucket index = function
        | [] -> index
        | boundary :: rest ->
            if sample <= boundary then index else bucket (index + 1) rest
      in
      let index = bucket 0 boundaries in
      counts.(index) <- counts.(index) + 1)
    samples;
  let rec attach acc index = function
    | [] -> List.rev ((infinity, counts.(index)) :: acc)
    | boundary :: rest -> attach ((boundary, counts.(index)) :: acc) (index + 1) rest
  in
  attach [] 0 boundaries

let min_max samples =
  let rec loop count sum min_v max_v = function
    | [] -> (count, sum, min_v, max_v)
    | sample :: rest ->
        let min_v =
          match min_v with
          | None -> Some sample
          | Some current -> Some (min current sample)
        in
        let max_v =
          match max_v with
          | None -> Some sample
          | Some current -> Some (max current sample)
        in
        loop (count + 1) (sum +. sample) min_v max_v rest
  in
  loop 0 0.0 None None samples

let histogram_state boundaries samples =
  let count, sum, min, max = min_max samples in
  { count; sum; min; max; buckets = bucket_counts boundaries samples }

let summary_quantile sorted count q =
  if count = 0 then nan
  else
    let q = max 0.0 (min 1.0 q) in
    let index = int_of_float (ceil (q *. float_of_int count)) - 1 in
    let index = max 0 (min (count - 1) index) in
    List.nth sorted index

let summary_state (config : Eta.Capabilities.summary_config) samples =
  let rec take n acc = function
    | _ when n <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: xs -> take (n - 1) (x :: acc) xs
  in
  let samples =
    if List.length samples <= config.max_size then samples
    else
      samples
      |> List.rev
      |> take config.max_size []
      |> List.rev
  in
  let count, sum, min, max = min_max samples in
  let sorted = List.sort Float.compare samples in
  let quantiles =
    List.map
      (fun quantile -> (quantile, summary_quantile sorted count quantile))
      config.quantiles
  in
  { count; sum; min; max; quantiles }

type acc_value =
  | Acc_sum of Eta.Capabilities.metric_number
  | Acc_gauge of Eta.Capabilities.metric_number
  | Acc_frequency of (string, int) Hashtbl.t
  | Acc_histogram of float list
  | Acc_summary of float list

let number_value = function
  | Eta.Capabilities.Number value -> Some value
  | Category _ -> None

let category_value = function
  | Eta.Capabilities.Category value -> Some value
  | Number _ -> None

let add_frequency table category =
  let count = Option.value (Hashtbl.find_opt table category) ~default:0 in
  Hashtbl.replace table category (count + 1)

let start_acc kind value =
  match (kind, value) with
  | Eta.Capabilities.Counter _, Eta.Capabilities.Number value -> Some (Acc_sum value)
  | Gauge, Number value -> Some (Acc_gauge value)
  | Frequency, Category category ->
      let table = Hashtbl.create 8 in
      add_frequency table category;
      Some (Acc_frequency table)
  | Histogram _, Number value -> Some (Acc_histogram [ float_of_number value ])
  | Summary _, Number value -> Some (Acc_summary [ float_of_number value ])
  | (Counter _ | Gauge | Histogram _ | Summary _), Category _
  | Frequency, Number _ ->
      None

let update_acc kind acc value =
  match (kind, acc) with
  | Eta.Capabilities.Counter { monotonic = true }, Acc_sum current -> (
      match number_value value with
      | None -> acc
      | Some value -> Acc_sum (add_number current value))
  | Counter { monotonic = false }, Acc_sum _current -> (
      match number_value value with
      | None -> acc
      | Some value -> Acc_sum value)
  | Gauge, Acc_gauge _ -> (
      match number_value value with
      | None -> acc
      | Some value -> Acc_gauge value)
  | Frequency, Acc_frequency table -> (
      match category_value value with
      | None -> acc
      | Some category ->
          add_frequency table category;
          acc)
  | Histogram _, Acc_histogram samples -> (
      match number_value value with
      | None -> acc
      | Some value -> Acc_histogram (float_of_number value :: samples))
  | Summary _, Acc_summary samples -> (
      match number_value value with
      | None -> acc
      | Some value -> Acc_summary (float_of_number value :: samples))
  | _, _ -> acc

let finish_acc kind acc =
  match (kind, acc) with
  | Eta.Capabilities.Counter _, Acc_sum value -> Sum value
  | Gauge, Acc_gauge value -> Gauge value
  | Frequency, Acc_frequency table ->
      let counts =
        Hashtbl.fold (fun k v acc -> (k, v) :: acc) table []
        |> List.sort compare
      in
      (Frequency counts : aggregate_value)
  | Histogram { boundaries }, Acc_histogram samples ->
      (Histogram (histogram_state boundaries (List.rev samples)) : aggregate_value)
  | Summary config, Acc_summary samples ->
      (Summary (summary_state config (List.rev samples)) : aggregate_value)
  | _, _ -> invalid_arg "Metric_aggregation.finish_acc: kind/acc mismatch"

let aggregate_points_table points =
  let table = Hashtbl.create 16 in
  List.iter
    (fun (p : Eta.Meter.point) ->
      let key = Metric_key.normalize p in
      let ts_ns = ms_to_ns_saturating p.ts_ms in
      match Hashtbl.find_opt table key with
      | None -> (
          match start_acc p.kind p.value with
          | None -> ()
          | Some acc -> Hashtbl.add table key (acc, ts_ns, ts_ns))
      | Some (acc, start_ts, _end_ts) ->
          let acc = update_acc p.kind acc p.value in
          Hashtbl.replace table key (acc, start_ts, ts_ns))
    points;
  Hashtbl.fold
    (fun (key : Metric_key.t) (acc, start_ts, end_ts) out ->
      (key, (finish_acc key.kind acc, start_ts, end_ts)) :: out)
    table []

let aggregate_points points = aggregate_points_table points
