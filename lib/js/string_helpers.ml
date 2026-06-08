let[@zero_alloc] is_trim_space = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false

let[@zero_alloc] lowercase_ascii_char c =
  match c with
  | 'A' .. 'Z' -> Char.unsafe_chr (Char.code c + 32)
  | _ -> c

let[@zero_alloc] ascii_equal_ci left right =
  Char.equal (lowercase_ascii_char left) (lowercase_ascii_char right)

let[@zero_alloc] lower_hex_digit value =
  if value < 10 then Char.unsafe_chr (Char.code '0' + value)
  else Char.unsafe_chr (Char.code 'a' + value - 10)

let[@zero_alloc] upper_hex_digit value =
  if value < 10 then Char.unsafe_chr (Char.code '0' + value)
  else Char.unsafe_chr (Char.code 'A' + value - 10)

let[@zero_alloc] trim_left value start finish =
  let index = ref start in
  while !index < finish && is_trim_space (String.unsafe_get value !index) do
    incr index
  done;
  !index

let[@zero_alloc] trim_right value start finish =
  let index = ref finish in
  while !index > start && is_trim_space (String.unsafe_get value (!index - 1)) do
    decr index
  done;
  !index

let trim_bounds value =
  let len = String.length value in
  let start = trim_left value 0 len in
  (start, trim_right value start len)

let[@zero_alloc] is_blank value =
  let len = String.length value in
  trim_left value 0 len = len

let trim value =
  let start, stop = trim_bounds value in
  if start = 0 && stop = String.length value then value
  else String.sub value start (stop - start)

let[@zero_alloc] has_uppercase_ascii value start stop =
  let index = ref start in
  let found = ref false in
  while (not !found) && !index < stop do
    let c = String.unsafe_get value !index in
    found := c >= 'A' && c <= 'Z';
    incr index
  done;
  !found

let lowercase_ascii_trim value =
  let value_len = String.length value in
  let start = trim_left value 0 value_len in
  let stop = trim_right value start value_len in
  if start = 0 && stop = value_len && not (has_uppercase_ascii value start stop)
  then value
  else
    let len = stop - start in
    let bytes = Bytes.create len in
    for index = 0 to len - 1 do
      Bytes.unsafe_set bytes index
        (lowercase_ascii_char (String.unsafe_get value (start + index)))
    done;
    Bytes.unsafe_to_string bytes

let lowercase_ascii value =
  let len = String.length value in
  if not (has_uppercase_ascii value 0 len) then value
  else
    let bytes = Bytes.create len in
    for index = 0 to len - 1 do
      Bytes.unsafe_set bytes index
        (lowercase_ascii_char (String.unsafe_get value index))
    done;
    Bytes.unsafe_to_string bytes

let[@zero_alloc] contains_ascii_ci haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > haystack_len then false
  else (
    let pos = ref 0 in
    let found = ref false in
    while (not !found) && !pos + needle_len <= haystack_len do
      let index = ref 0 in
      while
        !index < needle_len
        && ascii_equal_ci
             (String.unsafe_get haystack (!pos + !index))
             (String.unsafe_get needle !index)
      do
        incr index
      done;
      found := !index = needle_len;
      incr pos
    done;
    !found)

let[@zero_alloc] is_http_token_space = function
  | ' ' | '\t' -> true
  | _ -> false

let[@zero_alloc] trim_equal_ascii_ci_bounds value start stop token =
  let start = ref start in
  let stop = ref stop in
  while !start < !stop && is_http_token_space (String.unsafe_get value !start) do
    incr start
  done;
  while !stop > !start && is_http_token_space (String.unsafe_get value (!stop - 1)) do
    decr stop
  done;
  let len = !stop - !start in
  let token_len = String.length token in
  if len <> token_len then false
  else (
    let index = ref 0 in
    while
      !index < token_len
      && ascii_equal_ci
           (String.unsafe_get value (!start + !index))
           (String.unsafe_get token !index)
    do
      incr index
    done;
    !index = token_len)

let[@zero_alloc] contains_token_ascii_ci value token =
  let len = String.length value in
  let start = ref 0 in
  let found = ref false in
  while (not !found) && !start <= len do
    let stop =
      match String.index_from_opt value !start ',' with
      | None -> len
      | Some index -> index
    in
    found := trim_equal_ascii_ci_bounds value !start stop token;
    start := stop + 1
  done;
  !found

let[@zero_alloc] starts_with_at value ~offset prefix =
  let value_len = String.length value in
  let prefix_len = String.length prefix in
  if offset < 0 || value_len - offset < prefix_len then false
  else (
    let index = ref 0 in
    while
      !index < prefix_len
      && Char.equal
           (String.unsafe_get value (offset + !index))
           (String.unsafe_get prefix !index)
    do
      incr index
    done;
    !index = prefix_len)

let[@zero_alloc] starts_with value ~prefix = starts_with_at value ~offset:0 prefix

let[@zero_alloc] ends_with value ~suffix =
  let value_len = String.length value in
  let suffix_len = String.length suffix in
  if value_len < suffix_len then false
  else (
    let offset = value_len - suffix_len in
    let index = ref 0 in
    while
      !index < suffix_len
      && Char.equal
           (String.unsafe_get value (offset + !index))
           (String.unsafe_get suffix !index)
    do
      incr index
    done;
    !index = suffix_len)

let[@zero_alloc] ends_with_ascii_ci value ~suffix =
  let value_len = String.length value in
  let suffix_len = String.length suffix in
  if value_len < suffix_len then false
  else (
    let offset = value_len - suffix_len in
    let index = ref 0 in
    while
      !index < suffix_len
      && ascii_equal_ci
           (String.unsafe_get value (offset + !index))
           (String.unsafe_get suffix !index)
    do
      incr index
    done;
    !index = suffix_len)

let[@zero_alloc] trim_equal value literal =
  let value_len = String.length value in
  let value_start = trim_left value 0 value_len in
  let value_stop = trim_right value value_start value_len in
  let len = value_stop - value_start in
  let literal_len = String.length literal in
  if len <> literal_len then false
  else (
    let index = ref 0 in
    while
      !index < literal_len
      && Char.equal
           (String.unsafe_get value (value_start + !index))
           (String.unsafe_get literal !index)
    do
      incr index
    done;
    !index = literal_len)

let[@zero_alloc] trim_equal_ascii_ci value literal =
  let value_len = String.length value in
  let value_start = trim_left value 0 value_len in
  let value_stop = trim_right value value_start value_len in
  let len = value_stop - value_start in
  let literal_len = String.length literal in
  if len <> literal_len then false
  else (
    let index = ref 0 in
    while
      !index < literal_len
      && ascii_equal_ci
           (String.unsafe_get value (value_start + !index))
           (String.unsafe_get literal !index)
    do
      incr index
    done;
    !index = literal_len)

let[@zero_alloc] trim_equal_trimmed_ascii_ci left right =
  let left_len = String.length left in
  let left_start = trim_left left 0 left_len in
  let left_stop = trim_right left left_start left_len in
  let right_len = String.length right in
  let right_start = trim_left right 0 right_len in
  let right_stop = trim_right right right_start right_len in
  let len = left_stop - left_start in
  if len <> right_stop - right_start then false
  else (
    let index = ref 0 in
    while
      !index < len
      && ascii_equal_ci
           (String.unsafe_get left (left_start + !index))
           (String.unsafe_get right (right_start + !index))
    do
      incr index
    done;
    !index = len)
