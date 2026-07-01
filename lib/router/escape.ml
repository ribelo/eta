module Int_set = Set.Make (Int)

type t = {
  bytes : string;
  escaped : string;
}

type slice = {
  src : t;
  off : int;
  len : int;
}

let of_string s =
  let len = String.length s in
  let buf = Bytes.create len in
  let esc = Bytes.make len '\000' in
  let src = ref 0 in
  let dst = ref 0 in
  while !src < len do
    let c = String.unsafe_get s !src in
    if
      (c = '{' || c = '}')
      && !src + 1 < len
      && String.unsafe_get s (!src + 1) = c
    then begin
      Bytes.unsafe_set buf !dst c;
      Bytes.unsafe_set esc !dst '\001';
      src := !src + 2
    end else begin
      Bytes.unsafe_set buf !dst c;
      incr src
    end;
    incr dst
  done;
  { bytes = Bytes.sub_string buf 0 !dst; escaped = Bytes.sub_string esc 0 !dst }

let of_unescaped bytes escaped =
  let len = String.length bytes in
  let esc = Bytes.make len '\000' in
  Int_set.iter
    (fun i -> if i >= 0 && i < len then Bytes.unsafe_set esc i '\001')
    escaped;
  { bytes; escaped = Bytes.unsafe_to_string esc }

let make_unescaped ~bytes ~escaped =
  { bytes; escaped }

let to_string t = t.bytes
let[@inline always][@zero_alloc] length t = String.length t.bytes
let[@inline always][@zero_alloc] get t i = String.get t.bytes i
let[@inline always][@zero_alloc] unsafe_get t i = String.unsafe_get t.bytes i
let[@inline always][@zero_alloc] is_escaped t i = String.unsafe_get t.escaped i = '\001'
let full t = { src = t; off = 0; len = String.length t.bytes }

let slice s ~off ~len =
  if off < 0 || len < 0 || off + len > s.len then invalid_arg "Escape.slice";
  { s with off = s.off + off; len }

let slice_off s n =
  if n < 0 || n > s.len then invalid_arg "Escape.slice_off";
  { s with off = s.off + n; len = s.len - n }

let slice_until s n =
  if n < 0 || n > s.len then invalid_arg "Escape.slice_until";
  { s with len = n }

let[@inline always][@zero_alloc] slice_length s = s.len
let[@inline always][@zero_alloc] slice_get s i = String.get s.src.bytes (s.off + i)
let[@inline always][@zero_alloc] slice_unsafe_get s i = String.unsafe_get s.src.bytes (s.off + i)

let[@inline always][@zero_alloc] slice_is_escaped s i =
  String.unsafe_get s.src.escaped (s.off + i) = '\001'

let slice_to_string s = String.sub s.src.bytes s.off s.len

let slice_to_owned s =
  let bytes = slice_to_string s in
  let len = s.len in
  let esc = Bytes.create len in
  let src_off = s.off in
  let src_esc = s.src.escaped in
  for i = 0 to len - 1 do
    Bytes.unsafe_set esc i (String.unsafe_get src_esc (src_off + i))
  done;
  { bytes; escaped = Bytes.unsafe_to_string esc }

let rec common_prefix_loop a_bytes a_escaped a_off b_bytes b_escaped b_off
    max_len i =
  if
    i < max_len
    && String.unsafe_get a_bytes (a_off + i)
       = String.unsafe_get b_bytes (b_off + i)
    && String.unsafe_get a_escaped (a_off + i)
       = String.unsafe_get b_escaped (b_off + i)
  then common_prefix_loop a_bytes a_escaped a_off b_bytes b_escaped b_off
         max_len (i + 1)
  else i

let[@zero_alloc] common_prefix a b =
  if a.len = 0 || b.len = 0 then 0
  else
    let max_len = min a.len b.len in
    common_prefix_loop a.src.bytes a.src.escaped a.off b.src.bytes
      b.src.escaped b.off max_len 0

let append a b =
  let bytes = a.bytes ^ b.bytes in
  let escaped = a.escaped ^ b.escaped in
  { bytes; escaped }
