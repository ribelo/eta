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

let ms_to_ns_saturating ms =
  if ms <= 0 then 0
  else if ms > max_int / 1_000_000 then max_int
  else ms * 1_000_000

let add_int_counter a b =
  if (b > 0 && a > max_int - b) || (b < 0 && a < min_int - b) then
    Eta.Capabilities.Float (float_of_int a +. float_of_int b)
  else Eta.Capabilities.Int (a + b)

let merge_metric_value kind acc value =
  match kind with
  | Eta.Capabilities.Gauge | Counter_cumulative -> value
  | Counter_monotonic -> (
      match (acc, value) with
      | Eta.Capabilities.Int a, Eta.Capabilities.Int b -> add_int_counter a b
      | Float a, Float b -> Float (a +. b)
      | Int a, Float b -> Float (float_of_int a +. b)
      | Float a, Int b -> Float (a +. float_of_int b))

let aggregate_points_table points =
  let table = Hashtbl.create 16 in
  List.iter
    (fun (p : Eta.Meter.point) ->
      let key = Metric_key.normalize p in
      let ts_ns = ms_to_ns_saturating p.ts_ms in
      match Hashtbl.find_opt table key with
      | None -> Hashtbl.add table key (p.value, ts_ns, ts_ns)
      | Some (acc, start_ts, _end_ts) ->
          let new_v = merge_metric_value p.kind acc p.value in
          Hashtbl.replace table key (new_v, start_ts, ts_ns))
    points;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) table []

let aggregate_points = function
  | [] -> []
  | first :: rest as points -> (
      let first_key = Metric_key.normalize first in
      let start_ts = ms_to_ns_saturating first.ts_ms in
      let rec same_key acc end_ts = function
        | [] -> Some [ (first_key, (acc, start_ts, end_ts)) ]
        | point :: points ->
            let key = Metric_key.normalize point in
            if Metric_key.equal first_key key then
              let ts_ns = ms_to_ns_saturating point.ts_ms in
              let acc = merge_metric_value point.kind acc point.value in
              same_key acc ts_ns points
            else None
      in
      match same_key first.value start_ts rest with
      | Some result -> result
      | None -> aggregate_points_table points)
