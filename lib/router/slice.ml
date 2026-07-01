type t = {
  src : string;
  off : int;
  len : int;
}

let of_string src = { src; off = 0; len = String.length src }

let of_string_sub src off len =
  if off < 0 || len < 0 || off + len > String.length src then
    invalid_arg "Slice.of_string_sub";
  { src; off; len }

let to_string { src; off; len } = String.sub src off len
let[@inline always][@zero_alloc] length t = t.len
let[@inline always][@zero_alloc] is_empty t = t.len = 0
let[@inline always][@zero_alloc] get t i = String.get t.src (t.off + i)
let[@inline always][@zero_alloc] unsafe_get t i = String.unsafe_get t.src (t.off + i)

let sub t off len =
  if off < 0 || len < 0 || off + len > t.len then
    invalid_arg "Slice.sub";
  { t with off = t.off + off; len }

let drop t n =
  if n < 0 || n > t.len then invalid_arg "Slice.drop";
  { t with off = t.off + n; len = t.len - n }

let take t n =
  if n < 0 || n > t.len then invalid_arg "Slice.take";
  { t with len = n }

let rec common_prefix_loop a_src a_off b_src b_off max_len i =
  if
    i < max_len
    && String.unsafe_get a_src (a_off + i)
       = String.unsafe_get b_src (b_off + i)
  then common_prefix_loop a_src a_off b_src b_off max_len (i + 1)
  else i

let[@zero_alloc] common_prefix a b =
  if a.len = 0 || b.len = 0 then 0
  else
    let max_len = min a.len b.len in
    common_prefix_loop a.src a.off b.src b.off max_len 0
