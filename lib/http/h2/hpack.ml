(** HPACK codec.

    Direct buffer iteration loop for RFC 7541 header compression, used by the
    in-house HTTP/2 state machine.

    Conforms to RFC 7541 (HPACK: Header Compression for HTTP/2). *)

(* ── Types ────────────────────────────────────────────────────────────── *)

type header = { name : string; value : string; sensitive : bool }

type decode_error = Decode_error

type t = {
  mutable dynamic_table : dynamic_cell array;
  mutable dynamic_count : int;
  mutable dynamic_insert_pos : int;
  mutable max_capacity : int;
  mutable dynamic_capacity : int;
  mutable dynamic_size : int;
}

and dynamic_cell = { dc_name : string; dc_value : string; dc_size : int }

(* ── Static Table (RFC 7541, Appendix A) ───────────────────────────────── *)

let static_table : (string * string) array =
  [| (*  1 *) (":authority", "")
  ;  (*  2 *) (":method", "GET")
  ;  (*  3 *) (":method", "POST")
  ;  (*  4 *) (":path", "/")
  ;  (*  5 *) (":path", "/index.html")
  ;  (*  6 *) (":scheme", "http")
  ;  (*  7 *) (":scheme", "https")
  ;  (*  8 *) (":status", "200")
  ;  (*  9 *) (":status", "204")
  ;  (* 10 *) (":status", "206")
  ;  (* 11 *) (":status", "304")
  ;  (* 12 *) (":status", "400")
  ;  (* 13 *) (":status", "404")
  ;  (* 14 *) (":status", "500")
  ;  (* 15 *) ("accept-charset", "")
  ;  (* 16 *) ("accept-encoding", "gzip, deflate")
  ;  (* 17 *) ("accept-language", "")
  ;  (* 18 *) ("accept-ranges", "")
  ;  (* 19 *) ("accept", "")
  ;  (* 20 *) ("access-control-allow-origin", "")
  ;  (* 21 *) ("age", "")
  ;  (* 22 *) ("allow", "")
  ;  (* 23 *) ("authorization", "")
  ;  (* 24 *) ("cache-control", "")
  ;  (* 25 *) ("content-disposition", "")
  ;  (* 26 *) ("content-encoding", "")
  ;  (* 27 *) ("content-language", "")
  ;  (* 28 *) ("content-length", "")
  ;  (* 29 *) ("content-location", "")
  ;  (* 30 *) ("content-range", "")
  ;  (* 31 *) ("content-type", "")
  ;  (* 32 *) ("cookie", "")
  ;  (* 33 *) ("date", "")
  ;  (* 34 *) ("etag", "")
  ;  (* 35 *) ("expect", "")
  ;  (* 36 *) ("expires", "")
  ;  (* 37 *) ("from", "")
  ;  (* 38 *) ("host", "")
  ;  (* 39 *) ("if-match", "")
  ;  (* 40 *) ("if-modified-since", "")
  ;  (* 41 *) ("if-none-match", "")
  ;  (* 42 *) ("if-range", "")
  ;  (* 43 *) ("if-unmodified-since", "")
  ;  (* 44 *) ("last-modified", "")
  ;  (* 45 *) ("link", "")
  ;  (* 46 *) ("location", "")
  ;  (* 47 *) ("max-forwards", "")
  ;  (* 48 *) ("proxy-authenticate", "")
  ;  (* 49 *) ("proxy-authorization", "")
  ;  (* 50 *) ("range", "")
  ;  (* 51 *) ("referer", "")
  ;  (* 52 *) ("refresh", "")
  ;  (* 53 *) ("retry-after", "")
  ;  (* 54 *) ("server", "")
  ;  (* 55 *) ("set-cookie", "")
  ;  (* 56 *) ("strict-transport-security", "")
  ;  (* 57 *) ("transfer-encoding", "")
  ;  (* 58 *) ("user-agent", "")
  ;  (* 59 *) ("vary", "")
  ;  (* 60 *) ("via", "")
  ;  (* 61 *) ("www-authenticate", "")
  |]

let static_table_size = Array.length static_table

(* ── Huffman Codes (RFC 7541, Appendix B) ──────────────────────────────── *)

type huffman_code = { code : int; len : int; value : int }

let huffman_codes : huffman_code array =
  [| (* 0..255 — value is the ASCII character to encode *)
     { code = 0x1ff8; len = 13; value = 0 }
  ;  { code = 0x7fffd8; len = 23; value = 1 }
  ;  { code = 0xfffffe2; len = 28; value = 2 }
  ;  { code = 0xfffffe3; len = 28; value = 3 }
  ;  { code = 0xfffffe4; len = 28; value = 4 }
  ;  { code = 0xfffffe5; len = 28; value = 5 }
  ;  { code = 0xfffffe6; len = 28; value = 6 }
  ;  { code = 0xfffffe7; len = 28; value = 7 }
  ;  { code = 0xfffffe8; len = 28; value = 8 }
  ;  { code = 0xffffea; len = 24; value = 9 }
  ;  { code = 0x3ffffffc; len = 30; value = 10 }
  ;  { code = 0xfffffe9; len = 28; value = 11 }
  ;  { code = 0xfffffea; len = 28; value = 12 }
  ;  { code = 0x3ffffffd; len = 30; value = 13 }
  ;  { code = 0xfffffeb; len = 28; value = 14 }
  ;  { code = 0xfffffec; len = 28; value = 15 }
  ;  { code = 0xfffffed; len = 28; value = 16 }
  ;  { code = 0xfffffee; len = 28; value = 17 }
  ;  { code = 0xfffffef; len = 28; value = 18 }
  ;  { code = 0xffffff0; len = 28; value = 19 }
  ;  { code = 0xffffff1; len = 28; value = 20 }
  ;  { code = 0xffffff2; len = 28; value = 21 }
  ;  { code = 0x3ffffffe; len = 30; value = 22 }
  ;  { code = 0xffffff3; len = 28; value = 23 }
  ;  { code = 0xffffff4; len = 28; value = 24 }
  ;  { code = 0xffffff5; len = 28; value = 25 }
  ;  { code = 0xffffff6; len = 28; value = 26 }
  ;  { code = 0xffffff7; len = 28; value = 27 }
  ;  { code = 0xffffff8; len = 28; value = 28 }
  ;  { code = 0xffffff9; len = 28; value = 29 }
  ;  { code = 0xffffffa; len = 28; value = 30 }
  ;  { code = 0xffffffb; len = 28; value = 31 }
  ;  { code = 0x14; len = 6; value = 32 }
  ;  { code = 0x3f8; len = 10; value = 33 }
  ;  { code = 0x3f9; len = 10; value = 34 }
  ;  { code = 0xffa; len = 12; value = 35 }
  ;  { code = 0x1ff9; len = 13; value = 36 }
  ;  { code = 0x15; len = 6; value = 37 }
  ;  { code = 0xf8; len = 8; value = 38 }
  ;  { code = 0x7fa; len = 11; value = 39 }
  ;  { code = 0x3fa; len = 10; value = 40 }
  ;  { code = 0x3fb; len = 10; value = 41 }
  ;  { code = 0xf9; len = 8; value = 42 }
  ;  { code = 0x7fb; len = 11; value = 43 }
  ;  { code = 0xfa; len = 8; value = 44 }
  ;  { code = 0x16; len = 6; value = 45 }
  ;  { code = 0x17; len = 6; value = 46 }
  ;  { code = 0x18; len = 6; value = 47 }
  ;  { code = 0x0; len = 5; value = 48 }
  ;  { code = 0x1; len = 5; value = 49 }
  ;  { code = 0x2; len = 5; value = 50 }
  ;  { code = 0x19; len = 6; value = 51 }
  ;  { code = 0x1a; len = 6; value = 52 }
  ;  { code = 0x1b; len = 6; value = 53 }
  ;  { code = 0x1c; len = 6; value = 54 }
  ;  { code = 0x1d; len = 6; value = 55 }
  ;  { code = 0x1e; len = 6; value = 56 }
  ;  { code = 0x1f; len = 6; value = 57 }
  ;  { code = 0x5c; len = 7; value = 58 }
  ;  { code = 0xfb; len = 8; value = 59 }
  ;  { code = 0x7ffc; len = 15; value = 60 }
  ;  { code = 0x20; len = 6; value = 61 }
  ;  { code = 0xffb; len = 12; value = 62 }
  ;  { code = 0x3fc; len = 10; value = 63 }
  ;  { code = 0x1ffa; len = 13; value = 64 }
  ;  { code = 0x21; len = 6; value = 65 }
  ;  { code = 0x5d; len = 7; value = 66 }
  ;  { code = 0x5e; len = 7; value = 67 }
  ;  { code = 0x5f; len = 7; value = 68 }
  ;  { code = 0x60; len = 7; value = 69 }
  ;  { code = 0x61; len = 7; value = 70 }
  ;  { code = 0x62; len = 7; value = 71 }
  ;  { code = 0x63; len = 7; value = 72 }
  ;  { code = 0x64; len = 7; value = 73 }
  ;  { code = 0x65; len = 7; value = 74 }
  ;  { code = 0x66; len = 7; value = 75 }
  ;  { code = 0x67; len = 7; value = 76 }
  ;  { code = 0x68; len = 7; value = 77 }
  ;  { code = 0x69; len = 7; value = 78 }
  ;  { code = 0x6a; len = 7; value = 79 }
  ;  { code = 0x6b; len = 7; value = 80 }
  ;  { code = 0x6c; len = 7; value = 81 }
  ;  { code = 0x6d; len = 7; value = 82 }
  ;  { code = 0x6e; len = 7; value = 83 }
  ;  { code = 0x6f; len = 7; value = 84 }
  ;  { code = 0x70; len = 7; value = 85 }
  ;  { code = 0x71; len = 7; value = 86 }
  ;  { code = 0x72; len = 7; value = 87 }
  ;  { code = 0xfc; len = 8; value = 88 }
  ;  { code = 0x73; len = 7; value = 89 }
  ;  { code = 0xfd; len = 8; value = 90 }
  ;  { code = 0x1ffb; len = 13; value = 91 }
  ;  { code = 0x7fff0; len = 19; value = 92 }
  ;  { code = 0x1ffc; len = 13; value = 93 }
  ;  { code = 0x3ffc; len = 14; value = 94 }
  ;  { code = 0x22; len = 6; value = 95 }
  ;  { code = 0x7ffd; len = 15; value = 96 }
  ;  { code = 0x3; len = 5; value = 97 }
  ;  { code = 0x23; len = 6; value = 98 }
  ;  { code = 0x4; len = 5; value = 99 }
  ;  { code = 0x24; len = 6; value = 100 }
  ;  { code = 0x5; len = 5; value = 101 }
  ;  { code = 0x25; len = 6; value = 102 }
  ;  { code = 0x26; len = 6; value = 103 }
  ;  { code = 0x27; len = 6; value = 104 }
  ;  { code = 0x6; len = 5; value = 105 }
  ;  { code = 0x74; len = 7; value = 106 }
  ;  { code = 0x75; len = 7; value = 107 }
  ;  { code = 0x28; len = 6; value = 108 }
  ;  { code = 0x29; len = 6; value = 109 }
  ;  { code = 0x2a; len = 6; value = 110 }
  ;  { code = 0x7; len = 5; value = 111 }
  ;  { code = 0x2b; len = 6; value = 112 }
  ;  { code = 0x76; len = 7; value = 113 }
  ;  { code = 0x2c; len = 6; value = 114 }
  ;  { code = 0x8; len = 5; value = 115 }
  ;  { code = 0x9; len = 5; value = 116 }
  ;  { code = 0x2d; len = 6; value = 117 }
  ;  { code = 0x77; len = 7; value = 118 }
  ;  { code = 0x78; len = 7; value = 119 }
  ;  { code = 0x79; len = 7; value = 120 }
  ;  { code = 0x7a; len = 7; value = 121 }
  ;  { code = 0x7b; len = 7; value = 122 }
  ;  { code = 0x7ffe; len = 15; value = 123 }
  ;  { code = 0x7fc; len = 11; value = 124 }
  ;  { code = 0x3ffd; len = 14; value = 125 }
  ;  { code = 0x1ffd; len = 13; value = 126 }
  ;  { code = 0xffffffc; len = 28; value = 127 }
  ;  { code = 0xfffe6; len = 20; value = 128 }
  ;  { code = 0x3fffd2; len = 22; value = 129 }
  ;  { code = 0xfffe7; len = 20; value = 130 }
  ;  { code = 0xfffe8; len = 20; value = 131 }
  ;  { code = 0x3fffd3; len = 22; value = 132 }
  ;  { code = 0x3fffd4; len = 22; value = 133 }
  ;  { code = 0x3fffd5; len = 22; value = 134 }
  ;  { code = 0x7fffd9; len = 23; value = 135 }
  ;  { code = 0x3fffd6; len = 22; value = 136 }
  ;  { code = 0x7fffda; len = 23; value = 137 }
  ;  { code = 0x7fffdb; len = 23; value = 138 }
  ;  { code = 0x7fffdc; len = 23; value = 139 }
  ;  { code = 0x7fffdd; len = 23; value = 140 }
  ;  { code = 0x7fffde; len = 23; value = 141 }
  ;  { code = 0xffffeb; len = 24; value = 142 }
  ;  { code = 0x7fffdf; len = 23; value = 143 }
  ;  { code = 0xffffec; len = 24; value = 144 }
  ;  { code = 0xffffed; len = 24; value = 145 }
  ;  { code = 0x3fffd7; len = 22; value = 146 }
  ;  { code = 0x7fffe0; len = 23; value = 147 }
  ;  { code = 0xffffee; len = 24; value = 148 }
  ;  { code = 0x7fffe1; len = 23; value = 149 }
  ;  { code = 0x7fffe2; len = 23; value = 150 }
  ;  { code = 0x7fffe3; len = 23; value = 151 }
  ;  { code = 0x7fffe4; len = 23; value = 152 }
  ;  { code = 0x1fffdc; len = 21; value = 153 }
  ;  { code = 0x3fffd8; len = 22; value = 154 }
  ;  { code = 0x7fffe5; len = 23; value = 155 }
  ;  { code = 0x3fffd9; len = 22; value = 156 }
  ;  { code = 0x7fffe6; len = 23; value = 157 }
  ;  { code = 0x7fffe7; len = 23; value = 158 }
  ;  { code = 0xffffef; len = 24; value = 159 }
  ;  { code = 0x3fffda; len = 22; value = 160 }
  ;  { code = 0x1fffdd; len = 21; value = 161 }
  ;  { code = 0xfffe9; len = 20; value = 162 }
  ;  { code = 0x3fffdb; len = 22; value = 163 }
  ;  { code = 0x3fffdc; len = 22; value = 164 }
  ;  { code = 0x7fffe8; len = 23; value = 165 }
  ;  { code = 0x7fffe9; len = 23; value = 166 }
  ;  { code = 0x1fffde; len = 21; value = 167 }
  ;  { code = 0x7fffea; len = 23; value = 168 }
  ;  { code = 0x3fffdd; len = 22; value = 169 }
  ;  { code = 0x3fffde; len = 22; value = 170 }
  ;  { code = 0xfffff0; len = 24; value = 171 }
  ;  { code = 0x1fffdf; len = 21; value = 172 }
  ;  { code = 0x3fffdf; len = 22; value = 173 }
  ;  { code = 0x7fffeb; len = 23; value = 174 }
  ;  { code = 0x7fffec; len = 23; value = 175 }
  ;  { code = 0x1fffe0; len = 21; value = 176 }
  ;  { code = 0x1fffe1; len = 21; value = 177 }
  ;  { code = 0x3fffe0; len = 22; value = 178 }
  ;  { code = 0x1fffe2; len = 21; value = 179 }
  ;  { code = 0x7fffed; len = 23; value = 180 }
  ;  { code = 0x3fffe1; len = 22; value = 181 }
  ;  { code = 0x7fffee; len = 23; value = 182 }
  ;  { code = 0x7fffef; len = 23; value = 183 }
  ;  { code = 0xfffea; len = 20; value = 184 }
  ;  { code = 0x3fffe2; len = 22; value = 185 }
  ;  { code = 0x3fffe3; len = 22; value = 186 }
  ;  { code = 0x3fffe4; len = 22; value = 187 }
  ;  { code = 0x7ffff0; len = 23; value = 188 }
  ;  { code = 0x3fffe5; len = 22; value = 189 }
  ;  { code = 0x3fffe6; len = 22; value = 190 }
  ;  { code = 0x7ffff1; len = 23; value = 191 }
  ;  { code = 0x3ffffe0; len = 26; value = 192 }
  ;  { code = 0x3ffffe1; len = 26; value = 193 }
  ;  { code = 0xfffeb; len = 20; value = 194 }
  ;  { code = 0x7fff1; len = 19; value = 195 }
  ;  { code = 0x3fffe7; len = 22; value = 196 }
  ;  { code = 0x7ffff2; len = 23; value = 197 }
  ;  { code = 0x3fffe8; len = 22; value = 198 }
  ;  { code = 0x1ffffec; len = 25; value = 199 }
  ;  { code = 0x3ffffe2; len = 26; value = 200 }
  ;  { code = 0x3ffffe3; len = 26; value = 201 }
  ;  { code = 0x3ffffe4; len = 26; value = 202 }
  ;  { code = 0x7ffffde; len = 27; value = 203 }
  ;  { code = 0x7ffffdf; len = 27; value = 204 }
  ;  { code = 0x3ffffe5; len = 26; value = 205 }
  ;  { code = 0xfffff1; len = 24; value = 206 }
  ;  { code = 0x1ffffed; len = 25; value = 207 }
  ;  { code = 0x7fff2; len = 19; value = 208 }
  ;  { code = 0x1fffe3; len = 21; value = 209 }
  ;  { code = 0x3ffffe6; len = 26; value = 210 }
  ;  { code = 0x7ffffe0; len = 27; value = 211 }
  ;  { code = 0x7ffffe1; len = 27; value = 212 }
  ;  { code = 0x3ffffe7; len = 26; value = 213 }
  ;  { code = 0x7ffffe2; len = 27; value = 214 }
  ;  { code = 0xfffff2; len = 24; value = 215 }
  ;  { code = 0x1fffe4; len = 21; value = 216 }
  ;  { code = 0x1fffe5; len = 21; value = 217 }
  ;  { code = 0x3ffffe8; len = 26; value = 218 }
  ;  { code = 0x3ffffe9; len = 26; value = 219 }
  ;  { code = 0xffffffd; len = 28; value = 220 }
  ;  { code = 0x7ffffe3; len = 27; value = 221 }
  ;  { code = 0x7ffffe4; len = 27; value = 222 }
  ;  { code = 0x7ffffe5; len = 27; value = 223 }
  ;  { code = 0xfffec; len = 20; value = 224 }
  ;  { code = 0xfffff3; len = 24; value = 225 }
  ;  { code = 0xfffed; len = 20; value = 226 }
  ;  { code = 0x1fffe6; len = 21; value = 227 }
  ;  { code = 0x3fffe9; len = 22; value = 228 }
  ;  { code = 0x1fffe7; len = 21; value = 229 }
  ;  { code = 0x1fffe8; len = 21; value = 230 }
  ;  { code = 0x7ffff3; len = 23; value = 231 }
  ;  { code = 0x3fffea; len = 22; value = 232 }
  ;  { code = 0x3fffeb; len = 22; value = 233 }
  ;  { code = 0x1ffffee; len = 25; value = 234 }
  ;  { code = 0x1ffffef; len = 25; value = 235 }
  ;  { code = 0xfffff4; len = 24; value = 236 }
  ;  { code = 0xfffff5; len = 24; value = 237 }
  ;  { code = 0x3ffffea; len = 26; value = 238 }
  ;  { code = 0x7ffff4; len = 23; value = 239 }
  ;  { code = 0x3ffffeb; len = 26; value = 240 }
  ;  { code = 0x7ffffe6; len = 27; value = 241 }
  ;  { code = 0x3ffffec; len = 26; value = 242 }
  ;  { code = 0x3ffffed; len = 26; value = 243 }
  ;  { code = 0x7ffffe7; len = 27; value = 244 }
  ;  { code = 0x7ffffe8; len = 27; value = 245 }
  ;  { code = 0x7ffffe9; len = 27; value = 246 }
  ;  { code = 0x7ffffea; len = 27; value = 247 }
  ;  { code = 0x7ffffeb; len = 27; value = 248 }
  ;  { code = 0xffffffe; len = 28; value = 249 }
  ;  { code = 0x7ffffec; len = 27; value = 250 }
  ;  { code = 0x7ffffed; len = 27; value = 251 }
  ;  { code = 0x7ffffee; len = 27; value = 252 }
  ;  { code = 0x7ffffef; len = 27; value = 253 }
  ;  { code = 0x7fffff0; len = 27; value = 254 }
  ;  { code = 0x3ffffee; len = 26; value = 255 }
  |]

(* ── Huffman Decode (4-bit FSM, nghttp2/h2o algorithm) ──────────────────── *)

(* The decoder consumes the input one nibble (4 bits) at a time using a
   precomputed finite-state-machine table, instead of scanning all 256 codes
   per bit. The table is generated once at module load from [huffman_codes]
   (no copied table, correct by construction).

   A "state" is a node in the binary code trie reached at a nibble boundary
   (i.e. an accumulated code prefix that has not yet matched a complete code).
   Because the shortest HPACK Huffman code is 5 bits, a single 4-bit step can
   complete at most one symbol, so each table entry carries at most one output.

   [huffman_table.(state * 16 + nibble)] packs the transition:
     -1                                  -> invalid bit sequence (decode error)
     (next_state lsl 9) lor (sym_present lsl 8) lor sym
   [huffman_accept.(state)] is true when [state] is a valid end-of-input state:
   the path from the root is all 1-bits and at most 7 bits long (RFC 7541 §5.2
   EOS padding), which includes the root itself. *)

let huffman_table, huffman_accept =
  let max_nodes = 1024 in
  let c0 = Array.make max_nodes (-1) in
  let c1 = Array.make max_nodes (-1) in
  let leaf = Array.make max_nodes (-1) in
  (* depth and all-ones-path are used to compute the accept flag. *)
  let depth = Array.make max_nodes 0 in
  let all_ones = Array.make max_nodes true in
  let n_nodes = ref 1 (* node 0 = root *) in
  let new_child parent bit =
    let id = !n_nodes in
    incr n_nodes;
    depth.(id) <- depth.(parent) + 1;
    all_ones.(id) <- all_ones.(parent) && bit = 1;
    id
  in
  (* Build the trie from the canonical codes (MSB-first). *)
  Array.iter
    (fun { code; len; value } ->
      let node = ref 0 in
      for bit = len - 1 downto 0 do
        let b = (code lsr bit) land 1 in
        let child = if b = 0 then c0 else c1 in
        if child.(!node) = -1 then child.(!node) <- new_child !node b;
        node := child.(!node)
      done;
      leaf.(!node) <- value)
    huffman_codes;
  let n = !n_nodes in
  let table = Array.make (n * 16) (-1) in
  let accept = Array.make n false in
  for s = 0 to n - 1 do
    (* A state is only ever a non-leaf trie node (leaves emit and reset). *)
    accept.(s) <- all_ones.(s) && depth.(s) <= 7;
    for nib = 0 to 15 do
      (* Walk the 4 bits of [nib] from state [s]. *)
      let node = ref s in
      let sym = ref (-1) in
      let failed = ref false in
      for bit = 3 downto 0 do
        if not !failed then begin
          let b = (nib lsr bit) land 1 in
          let next = if b = 0 then c0.(!node) else c1.(!node) in
          if next = -1 then failed := true
          else if leaf.(next) >= 0 then begin
            (* Completed a symbol: emit it and return to the root. *)
            sym := leaf.(next);
            node := 0
          end
          else node := next
        end
      done;
      if not !failed then
        table.((s * 16) + nib) <-
          (!node lsl 9) lor (if !sym >= 0 then 0x100 lor !sym else 0)
    done
  done;
  (table, accept)

let huffman_decode bytes pos_ref ~len ~out =
  let end_pos = !pos_ref + len in
  let state = ref 0 in
  while !pos_ref < end_pos do
    let b = Char.code (Bytes.unsafe_get bytes !pos_ref) in
    incr pos_ref;
    (* High nibble. *)
    let v = Array.unsafe_get huffman_table ((!state lsl 4) lor (b lsr 4)) in
    if v < 0 then raise Exit;
    if v land 0x100 <> 0 then Buffer.add_char out (Char.unsafe_chr (v land 0xff));
    state := v lsr 9;
    (* Low nibble. *)
    let v = Array.unsafe_get huffman_table ((!state lsl 4) lor (b land 0xf)) in
    if v < 0 then raise Exit;
    if v land 0x100 <> 0 then Buffer.add_char out (Char.unsafe_chr (v land 0xff));
    state := v lsr 9
  done;
  if not (Array.unsafe_get huffman_accept !state) then raise Exit;
  Buffer.length out

(* ── Dynamic Table ─────────────────────────────────────────────────────── *)
(* Ring buffer with FIFO eviction when capacity exceeded. *)

let cell_size name value = String.length name + String.length value + 32

let max_cells_for_capacity capacity =
  if capacity <= 0 then 0 else max 1 ((capacity + 31) / 32)

let initial_cells_for_capacity capacity =
  min 128 (max_cells_for_capacity capacity)

let empty_cell = { dc_name = ""; dc_value = ""; dc_size = 0 }

let positive_mod n m =
  let r = n mod m in
  if r < 0 then r + m else r

let create max_capacity =
  if max_capacity < 0 then
    invalid_arg "Eta_http_h2.Hpack.create: negative capacity";
  (* Pre-allocate enough cells for the minimum HPACK entry size. *)
  let initial_cells = initial_cells_for_capacity max_capacity in
  { dynamic_table = Array.make initial_cells empty_cell
  ; dynamic_count = 0
  ; dynamic_insert_pos = 0
  ; max_capacity
  ; dynamic_capacity = max_capacity
  ; dynamic_size = 0
  }

let evict_oldest t =
  let len = Array.length t.dynamic_table in
  if len = 0 || t.dynamic_count = 0 then ()
  else
    let evict_pos = positive_mod (t.dynamic_insert_pos - t.dynamic_count) len in
    let evicted = t.dynamic_table.(evict_pos) in
    t.dynamic_table.(evict_pos) <- empty_cell;
    t.dynamic_size <- t.dynamic_size - evicted.dc_size;
    t.dynamic_count <- t.dynamic_count - 1

let evict_to_dynamic_capacity t =
  while t.dynamic_count > 0 && t.dynamic_size > t.dynamic_capacity do
    evict_oldest t
  done

let set_max_table_size t size =
  if size < 0 then
    invalid_arg "Eta_http_h2.Hpack.set_max_table_size: negative capacity";
  t.max_capacity <- size;
  if t.dynamic_capacity > size then t.dynamic_capacity <- size;
  evict_to_dynamic_capacity t

let set_dynamic_table_capacity t capacity =
  if capacity < 0 then
    invalid_arg
      "Eta_http_h2.Hpack.set_dynamic_table_capacity: negative capacity";
  if capacity > t.max_capacity then raise Exit;
  t.dynamic_capacity <- capacity;
  evict_to_dynamic_capacity t

let dynamic_table_get t index =
  (* Index 0 is the most recently inserted entry *)
  let count = t.dynamic_count in
  if index < 0 || index >= count then
    invalid_arg "dynamic_table_get: index out of bounds"
  else
    let pos =
      positive_mod (t.dynamic_insert_pos - 1 - index)
        (Array.length t.dynamic_table)
    in
    let cell = t.dynamic_table.(pos) in
    (cell.dc_name, cell.dc_value)

let ensure_storage t =
  let len = Array.length t.dynamic_table in
  if len = 0 then begin
    let new_len = min 16 (max_cells_for_capacity t.dynamic_capacity) in
    if new_len > 0 then t.dynamic_table <- Array.make new_len empty_cell
  end
  else if t.dynamic_count = len then begin
    let max_cells = max_cells_for_capacity t.dynamic_capacity in
    let new_len = min max_cells (len * 2) in
    if new_len > len then begin
      let new_table = Array.make new_len empty_cell in
      for i = 0 to t.dynamic_count - 1 do
        let src = positive_mod (t.dynamic_insert_pos - t.dynamic_count + i) len in
        new_table.(i) <- t.dynamic_table.(src)
      done;
      t.dynamic_insert_pos <- t.dynamic_count;
      t.dynamic_table <- new_table
    end
  end

let dynamic_table_add t name value =
  let size = cell_size name value in
  (* Evict entries from the back until we have room *)
  while t.dynamic_size + size > t.dynamic_capacity && t.dynamic_count > 0 do
    evict_oldest t
  done;
  (* If no room at all (capacity too small for the entry), drop it *)
  if size > t.dynamic_capacity then ()
  else begin
    ensure_storage t;
    let len = Array.length t.dynamic_table in
    if len = 0 then ()
    else begin
      let pos = t.dynamic_insert_pos mod len in
      t.dynamic_table.(pos) <-
        { dc_name = name; dc_value = value; dc_size = size };
      t.dynamic_insert_pos <- (t.dynamic_insert_pos + 1) mod len;
      t.dynamic_count <- t.dynamic_count + 1;
      t.dynamic_size <- t.dynamic_size + size
    end
  end

let dynamic_table_size t = t.dynamic_count

(* ── Decoder Helpers ───────────────────────────────────────────────────── *)

let[@zero_alloc] [@inline always] decode_int_prefix prefix prefix_bits bytes pos_ref =
  let max_prefix = (1 lsl prefix_bits) - 1 in
  let i = prefix land max_prefix in
  if i < max_prefix then i
  else
    let j = ref i in
    let m = ref 0 in
    let finished = ref false in
    let result = ref 0 in
    let bytes_len = Bytes.length bytes in
    while (not !finished) && !pos_ref < bytes_len do
      let b = Char.code (Bytes.unsafe_get bytes !pos_ref) in
      incr pos_ref;
      j := !j + ((b land 127) lsl !m);
      if b land 128 = 0 then begin
        result := !j;
        finished := true
      end
      else m := !m + 7
    done;
    if !finished then !result else raise Exit

(** Decode a string literal (RFC 7541 §5.2). *)
let decode_string_literal bytes pos_ref =
  if !pos_ref >= Bytes.length bytes then raise Exit;
  let h = Char.code (Bytes.unsafe_get bytes !pos_ref) in
  incr pos_ref;
  let str_len = decode_int_prefix h 7 bytes pos_ref in
  let huffman = h land 128 <> 0 in
  if str_len < 0 || !pos_ref + str_len > Bytes.length bytes then raise Exit;
  if huffman then (
    let out = Buffer.create str_len in
    let decoded_len =
      try huffman_decode bytes pos_ref ~len:str_len ~out
      with Exit -> -1
    in
    if decoded_len < 0 then raise Exit else Buffer.contents out)
  else
    let s = Bytes.sub_string bytes !pos_ref str_len in
    pos_ref := !pos_ref + str_len;
    s

(** Look up an indexed field (RFC 7541 §6.1). *)
let get_indexed_field t index =
  if index = 0 || index > static_table_size + t.dynamic_count then
    raise Exit
  else if index <= static_table_size then
    static_table.(index - 1)
  else
    dynamic_table_get t (index - static_table_size - 1)

(* ── Public decoder entry point ────────────────────────────────────────── *)

let decode_headers (t : t) bytes =
  let pos_ref = ref 0 in
  let len = Bytes.length bytes in

  (* Accumulate plain (name, value) tuples directly. This avoids allocating a
     [header] record per decoded header only to have callers immediately map it
     to a tuple. *)
  let result = ref [] in

  let saw_first_header = ref false in

  try
    while !pos_ref < len do
      let b = Char.code (Bytes.unsafe_get bytes !pos_ref) in

      (* Indexed Header Field (§6.1): 1xxxxxxx *)
      if b land 0x80 <> 0 then begin
        incr pos_ref;
        let index = decode_int_prefix b 7 bytes pos_ref in
        let name, value = get_indexed_field t index in
        result := (name, value) :: !result;
        saw_first_header := true
      end
      (* Literal with Incremental Indexing (§6.2.1): 01xxxxxx *)
      else if b land 0xc0 = 0x40 then begin
        incr pos_ref;
        let index = decode_int_prefix b 6 bytes pos_ref in
        let name, value =
          if index = 0 then
            let name = decode_string_literal bytes pos_ref in
            let value = decode_string_literal bytes pos_ref in
            (name, value)
          else
            let name, _ = get_indexed_field t index in
            let value = decode_string_literal bytes pos_ref in
            (name, value)
        in
        dynamic_table_add t name value;
        result := (name, value) :: !result;
        saw_first_header := true
      end
      (* Literal without Indexing (§6.2.2): 0000xxxx *)
      else if b land 0xf0 = 0 then begin
        incr pos_ref;
        let index = decode_int_prefix b 4 bytes pos_ref in
        let name, value =
          if index = 0 then
            let name = decode_string_literal bytes pos_ref in
            let value = decode_string_literal bytes pos_ref in
            (name, value)
          else
            let name, _ = get_indexed_field t index in
            let value = decode_string_literal bytes pos_ref in
            (name, value)
        in
        result := (name, value) :: !result;
        saw_first_header := true
      end
      (* Literal Never Indexed (§6.2.3): 0001xxxx *)
      else if b land 0xf0 = 0x10 then begin
        incr pos_ref;
        let index = decode_int_prefix b 4 bytes pos_ref in
        let name, value =
          if index = 0 then
            let name = decode_string_literal bytes pos_ref in
            let value = decode_string_literal bytes pos_ref in
            (name, value)
          else
            let name, _ = get_indexed_field t index in
            let value = decode_string_literal bytes pos_ref in
            (name, value)
        in
        result := (name, value) :: !result;
        saw_first_header := true
      end
      (* Dynamic Table Size Update (§6.3): 001xxxxx *)
      else if b land 0xe0 = 0x20 then begin
        if !saw_first_header then raise Exit;
        incr pos_ref;
        let capacity = decode_int_prefix b 5 bytes pos_ref in
        set_dynamic_table_capacity t capacity
      end
      else raise Exit
    done;
    Ok (List.rev !result)
  with Exit -> Error Decode_error

let decode_headers_string t s = decode_headers t (Bytes.of_string s)

(* ── Encoder ─────────────────────────────────────────────────────────── *)

(* Token helpers for encoder *)
let lookup_token_index name = match name with
  | ":authority" -> 0 | ":method" -> 1 | ":path" -> 3 | ":scheme" -> 5
  | ":status" -> 7 | "authorization" -> 22 | "cookie" -> 31
  | "content-length" -> 27 | "content-type" -> 30 | "cache-control" -> 23
  | "accept" -> 18 | "accept-encoding" -> 15 | "accept-language" -> 16
  | "accept-ranges" -> 17 | "access-control-allow-origin" -> 19
  | "age" -> 20 | "allow" -> 21 | "content-disposition" -> 24
  | "content-encoding" -> 25 | "content-language" -> 26
  | "content-location" -> 28 | "content-range" -> 29
  | "date" -> 32 | "etag" -> 33 | "expect" -> 34 | "expires" -> 35
  | "from" -> 36 | "host" -> 37 | "if-match" -> 38
  | "if-modified-since" -> 39 | "if-none-match" -> 40 | "if-range" -> 41
  | "if-unmodified-since" -> 42 | "last-modified" -> 43 | "link" -> 44
  | "location" -> 45 | "max-forwards" -> 46 | "proxy-authenticate" -> 47
  | "proxy-authorization" -> 48 | "range" -> 49 | "referer" -> 50
  | "refresh" -> 51 | "retry-after" -> 52 | "server" -> 53
  | "set-cookie" -> 54 | "strict-transport-security" -> 55
  | "transfer-encoding" -> 56 | "user-agent" -> 57 | "vary" -> 58
  | "via" -> 59 | "www-authenticate" -> 60
  | _ -> -1

let authorization_token = 22
let cookie_token = 31

let never_indexed_token t = match t with
  | 3 | 20 | 27 | 33 | 39 | 40 | 45 | 54 -> true | _ -> false

type encoder = {
  dec_tbl : t;
  mutable next_seq : int;
  mutable pending_min_table_size : int option;
  mutable pending_table_size : int option;
}

let encoder_create capacity =
  {
    dec_tbl = create capacity;
    next_seq = 0;
    pending_min_table_size = None;
    pending_table_size = None;
  }

(* Write integer with N-bit prefix (§5.1) into a pre-allocated bytes buffer. *)
let encoder_write_int buf pos_ref prefix n i =
  let max_prefix = (1 lsl n) - 1 in
  if i < max_prefix then begin
    Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (prefix lor i));
    incr pos_ref
  end else begin
    Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (prefix lor max_prefix));
    incr pos_ref;
    let rem = ref (i - max_prefix) in
    while !rem >= 128 do
      Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (!rem land 127 lor 128));
      incr pos_ref;
      rem := !rem lsr 7
    done;
    Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr !rem);
    incr pos_ref
  end

(* Write a string literal (§5.2). Always uses raw encoding for simplicity. *)
let encoder_write_string buf pos_ref s =
  let slen = String.length s in
  encoder_write_int buf pos_ref 0 7 slen;
  for i = 0 to slen - 1 do
    Bytes.unsafe_set buf !pos_ref (String.unsafe_get s i);
    incr pos_ref
  done

let encoder_can_index enc name value =
  cell_size name value <= enc.dec_tbl.dynamic_capacity

let encoder_write_pending_table_size_updates enc buf pos_ref =
  (match (enc.pending_min_table_size, enc.pending_table_size) with
  | None, None -> ()
  | Some min_size, Some final_size when min_size <> final_size ->
      encoder_write_int buf pos_ref 0x20 5 min_size;
      encoder_write_int buf pos_ref 0x20 5 final_size
  | Some size, _ | None, Some size ->
      encoder_write_int buf pos_ref 0x20 5 size);
  enc.pending_min_table_size <- None;
  enc.pending_table_size <- None

let encoder_write_literal_without_indexing buf pos_ref ~name_index ~name ~value =
  encoder_write_int buf pos_ref 0x00 4 name_index;
  if name_index = 0 then encoder_write_string buf pos_ref name;
  encoder_write_string buf pos_ref value

let encoder_write_literal_never_indexed buf pos_ref ~name_index ~name ~value =
  encoder_write_int buf pos_ref 0x10 4 name_index;
  if name_index = 0 then encoder_write_string buf pos_ref name;
  encoder_write_string buf pos_ref value

let encoder_write_literal_with_indexing enc buf pos_ref ~name_index ~name ~value =
  encoder_write_int buf pos_ref 0x40 6 name_index;
  if name_index = 0 then encoder_write_string buf pos_ref name;
  encoder_write_string buf pos_ref value;
  dynamic_table_add enc.dec_tbl name value;
  enc.next_seq <- enc.next_seq + 1

let encoded_header_bound (h : header) =
  String.length h.name + String.length h.value + 16

let encoded_headers_bound enc headers =
  let table_update_bound =
    match (enc.pending_min_table_size, enc.pending_table_size) with
    | None, None -> 0
    | Some min_size, Some final_size when min_size <> final_size -> 10
    | Some _, _ | None, Some _ -> 5
  in
  List.fold_left
    (fun total header -> total + encoded_header_bound header)
    (32 + table_update_bound) headers

(* Encode one header. *)
let encode_name_value enc buf pos_ref ~name ~value ~sensitive =
  let token = lookup_token_index name in
  (match token with
   | -1 ->
       if sensitive then
         encoder_write_literal_never_indexed buf pos_ref ~name_index:0 ~name
           ~value
       else if encoder_can_index enc name value then
         encoder_write_literal_with_indexing enc buf pos_ref ~name_index:0
           ~name ~value
       else
         encoder_write_literal_without_indexing buf pos_ref ~name_index:0
           ~name ~value
   | t ->
       (* Check for exact static table match first *)
       let rec find_exact i =
         if i >= static_table_size then None
         else
           let n, v = static_table.(i) in
           if n = name && v = value then Some (i + 1)
           else find_exact (i + 1)
       in
       (match find_exact t with
        | Some idx ->
            (* Fully indexed! *)
            encoder_write_int buf pos_ref 0x80 7 idx
        | None ->
            let name_index = t + 1 in
            if sensitive || never_indexed_token t
               || (t = authorization_token && true)
               || (t = cookie_token && String.length value < 20)
            then
              (* Never indexed, name from static table *)
              encoder_write_literal_never_indexed buf pos_ref ~name_index
                ~name ~value
            else if encoder_can_index enc name value then
              encoder_write_literal_with_indexing enc buf pos_ref ~name_index
                ~name ~value
            else
              encoder_write_literal_without_indexing buf pos_ref ~name_index
                ~name ~value))

let encode_single_header enc buf pos_ref (h : header) =
  encode_name_value enc buf pos_ref ~name:h.name ~value:h.value
    ~sensitive:h.sensitive

(* Precomputed decimal strings for HTTP status codes, to avoid a string_of_int
   allocation (caml_format_int / sprintf) on every response. *)
let status_strings = Array.init 600 string_of_int

let status_to_string code =
  if code >= 0 && code < 600 then Array.unsafe_get status_strings code
  else string_of_int code

(* HPACK static-table index (1-based) for a fully-indexed :status value, or -1.
   These map to RFC 7541 Appendix A entries 8..14. *)
let status_full_index = function
  | 200 -> 8 | 204 -> 9 | 206 -> 10 | 304 -> 11
  | 400 -> 12 | 404 -> 13 | 500 -> 14 | _ -> -1

(* Encode a list of headers into a fresh bytes buffer. *)
let encode_headers enc headers =
  let buf = Bytes.create (encoded_headers_bound enc headers) in
  let pos_ref = ref 0 in
  encoder_write_pending_table_size_updates enc buf pos_ref;
  List.iter (fun h -> encode_single_header enc buf pos_ref h) headers;
  Bytes.sub_string buf 0 !pos_ref

(* Response fast path: encode [:status] then plain (name, value) pairs (all
   non-sensitive), without wrapping each pair in a [header] record or building
   the [:status] string for common codes. Avoids the per-response List.map +
   record allocations and the string_of_int for the status line. *)
let encode_response_headers enc ~status headers =
  let table_update_bound =
    match (enc.pending_min_table_size, enc.pending_table_size) with
    | None, None -> 0
    | Some min_size, Some final_size when min_size <> final_size -> 10
    | Some _, _ | None, Some _ -> 5
  in
  let bound =
    List.fold_left
      (fun total (n, v) -> total + String.length n + String.length v + 16)
      (48 + table_update_bound) headers
  in
  let buf = Bytes.create bound in
  let pos_ref = ref 0 in
  encoder_write_pending_table_size_updates enc buf pos_ref;
  (let idx = status_full_index status in
   if idx >= 0 then encoder_write_int buf pos_ref 0x80 7 idx
   else
     encode_name_value enc buf pos_ref ~name:":status"
       ~value:(status_to_string status) ~sensitive:false);
  List.iter
    (fun (n, v) -> encode_name_value enc buf pos_ref ~name:n ~value:v
        ~sensitive:false)
    headers;
  Bytes.sub_string buf 0 !pos_ref

let encoder_set_max_table_size enc size =
  let old_size = enc.dec_tbl.dynamic_capacity in
  set_max_table_size enc.dec_tbl size;
  enc.dec_tbl.dynamic_capacity <- size;
  evict_to_dynamic_capacity enc.dec_tbl;
  if size <> old_size then begin
    if size < old_size then
      enc.pending_min_table_size <-
        Some
          (match enc.pending_min_table_size with
          | None -> size
          | Some pending -> min pending size);
    enc.pending_table_size <- Some size
  end
