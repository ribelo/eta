val is_trim_space : char -> bool [@@zero_alloc]

val lowercase_ascii_char : char -> char [@@zero_alloc]

val ascii_equal_ci : char -> char -> bool [@@zero_alloc]

val lower_hex_digit : int -> char [@@zero_alloc]

val upper_hex_digit : int -> char [@@zero_alloc]

val trim_left : string -> int -> int -> int [@@zero_alloc]

val trim_right : string -> int -> int -> int [@@zero_alloc]

val trim_bounds : string -> int * int

val is_blank : string -> bool [@@zero_alloc]

val trim : string -> string

val lowercase_ascii_trim : string -> string

val lowercase_ascii : string -> string

val contains_ascii_ci : string -> string -> bool [@@zero_alloc]

val trim_equal_ascii_ci_bounds : string -> int -> int -> string -> bool
[@@zero_alloc]

val contains_token_ascii_ci : string -> string -> bool [@@zero_alloc]

val starts_with_at : string -> offset:int -> string -> bool [@@zero_alloc]

val starts_with : string -> prefix:string -> bool [@@zero_alloc]

val ends_with : string -> suffix:string -> bool [@@zero_alloc]

val ends_with_ascii_ci : string -> suffix:string -> bool [@@zero_alloc]

val trim_equal : string -> string -> bool [@@zero_alloc]

val trim_equal_ascii_ci : string -> string -> bool [@@zero_alloc]

val trim_equal_trimmed_ascii_ci : string -> string -> bool [@@zero_alloc]
