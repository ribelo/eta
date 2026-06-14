(** OxCaml-optimized HPACK decoder.

    Replaces the upstream hpack library's Angstrom-based parser with a direct
    buffer iteration loop, eliminating per-byte combinator allocation.

    Conforms to RFC 7541 (HPACK: Header Compression for HTTP/2). *)

(* ── Types ────────────────────────────────────────────────────────────── *)

type header = { name : string; value : string; sensitive : bool }

type decode_error = Decode_error

type t = {
  mutable dynamic_table : dynamic_cell array;
  mutable dynamic_count : int;
  mutable dynamic_insert_pos : int;
  mutable max_capacity : int;
  mutable current_capacity : int;
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

(* ── Huffman Decode (simple code-scanner) ───────────────────────────── *)

(** Decode Huffman-encoded bytes. For each bit, check if the accumulated
    prefix matches any Huffman code. Simple but correct and doesn't require
    a large precomputed table. *)
let huffman_decode bytes pos_ref ~len ~out ~out_off =
  let mutable out_pos = out_off in
  let mutable acc = 0 in
  let mutable acc_len = 0 in
  let end_pos = !pos_ref + len in
  while !pos_ref < end_pos do
    let b = Char.code (Bytes.unsafe_get bytes !pos_ref) in
    incr pos_ref;
    for bit = 7 downto 0 do
      acc <- (acc lsl 1) lor ((b lsr bit) land 1);
      acc_len <- acc_len + 1;
      (* Check all 256 codes for a match *)
      let mutable found = false in
      let mutable i = 0 in
      while (not found) && i < 256 do
        let { code; len; value } = huffman_codes.(i) in
        if len = acc_len && code = acc then begin
          let ch = Char.unsafe_chr value in
          if ch <> '\x00' then (
            Bytes.unsafe_set out out_pos ch;
            out_pos <- out_pos + 1);
          acc <- 0;
          acc_len <- 0;
          found <- true
        end;
        i <- i + 1
      done
    done
  done;
  (* EOS padding: remaining bits should be all 1s (EOS prefix) *)
  if acc_len > 0 && acc = (1 lsl acc_len) - 1 then out_pos - out_off
  else if acc_len = 0 then out_pos - out_off
  else raise Exit

(* ── Dynamic Table ─────────────────────────────────────────────────────── *)
(* Ring buffer with FIFO eviction when capacity exceeded. *)

let cell_size name value = String.length name + String.length value + 32

let create max_capacity =
  (* Pre-allocate at a reasonable size; ring buffer grows as needed *)
  let initial_cells = min max_capacity 128 in
  { dynamic_table = Array.make initial_cells { dc_name = ""; dc_value = ""; dc_size = 0 }
  ; dynamic_count = 0
  ; dynamic_insert_pos = 0
  ; max_capacity
  ; current_capacity = 0
  }

let dynamic_table_get t index =
  (* Index 0 is the most recently inserted entry *)
  let count = t.dynamic_count in
  if index < 0 || index >= count then
    invalid_arg "dynamic_table_get: index out of bounds"
  else
    let pos = (t.dynamic_insert_pos - 1 - index) mod count in
    let pos = if pos < 0 then pos + count else pos in
    let cell = t.dynamic_table.(pos) in
    (cell.dc_name, cell.dc_value)

let dynamic_table_add t name value =
  let size = cell_size name value in
  (* Evict entries from the back until we have room *)
  while t.current_capacity + size > t.max_capacity && t.dynamic_count > 0 do
    let evict_pos =
      (t.dynamic_insert_pos - t.dynamic_count) mod (Array.length t.dynamic_table)
    in
    let evict_pos = if evict_pos < 0 then evict_pos + Array.length t.dynamic_table else evict_pos in
    let evicted = t.dynamic_table.(evict_pos) in
    t.current_capacity <- t.current_capacity - evicted.dc_size;
    t.dynamic_count <- t.dynamic_count - 1
  done;
  (* If no room at all (capacity too small for the entry), drop it *)
  if size > t.max_capacity then ()
  else begin
    (* Grow array if full *)
    let len = Array.length t.dynamic_table in
    if t.dynamic_count = len then begin
      let new_len = min (len * 2) t.max_capacity in
      if new_len <= len then () (* can't grow *)
      else begin
        let new_table = Array.make new_len { dc_name = ""; dc_value = ""; dc_size = 0 } in
        for i = 0 to t.dynamic_count - 1 do
          let src =
            (t.dynamic_insert_pos - t.dynamic_count + i) mod len
          in
          let src = if src < 0 then src + len else src in
          new_table.(i) <- t.dynamic_table.(src)
        done;
        t.dynamic_insert_pos <- t.dynamic_count;
        t.dynamic_table <- new_table
      end
    end;
    let pos = t.dynamic_insert_pos mod (Array.length t.dynamic_table) in
    t.dynamic_table.(pos) <- { dc_name = name; dc_value = value; dc_size = size };
    t.dynamic_insert_pos <- (t.dynamic_insert_pos + 1) mod (Array.length t.dynamic_table);
    t.dynamic_count <- t.dynamic_count + 1;
    t.current_capacity <- t.current_capacity + size
  end

let dynamic_table_size t = t.dynamic_count

(* ── Decoder Helpers ───────────────────────────────────────────────────── *)

let[@zero_alloc] [@inline always] decode_int_prefix prefix prefix_bits bytes pos_ref =
  let max_prefix = (1 lsl prefix_bits) - 1 in
  let i = prefix land max_prefix in
  if i < max_prefix then i
  else
    let mutable j = i in
    let mutable m = 0 in
    let mutable finished = false in
    let mutable result = 0 in
    let bytes_len = Bytes.length bytes in
    while (not finished) && !pos_ref < bytes_len do
      let b = Char.code (Bytes.unsafe_get bytes !pos_ref) in
      incr pos_ref;
      j <- j + ((b land 127) lsl m);
      if b land 128 = 0 then begin
        result <- j;
        finished <- true
      end
      else m <- m + 7
    done;
    if finished then result else raise Exit

(** Decode a string literal (RFC 7541 §5.2). *)
let decode_string_literal bytes pos_ref =
  let h = Char.code (Bytes.unsafe_get bytes !pos_ref) in
  incr pos_ref;
  let str_len = decode_int_prefix h 7 bytes pos_ref in
  let huffman = h land 128 <> 0 in
  if huffman then (
    (* Allocate worst-case output (str_len bytes → at most str_len chars) *)
    let out = Bytes.create str_len in
    let decoded_len =
      try huffman_decode bytes pos_ref ~len:str_len ~out ~out_off:0
      with Exit -> -1
    in
    if decoded_len < 0 then raise Exit
    else Bytes.sub_string out 0 decoded_len)
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

  (* Pre-allocate result accumulator. Most requests have < 20 headers. *)
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
        result := ({ name; value; sensitive = false } : header) :: !result;
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
        result := ({ name; value; sensitive = false } : header) :: !result;
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
        result := ({ name; value; sensitive = false } : header) :: !result;
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
        result := ({ name; value; sensitive = true } : header) :: !result;
        saw_first_header := true
      end
      (* Dynamic Table Size Update (§6.3): 001xxxxx *)
      else if b land 0xe0 = 0x20 then begin
        if !saw_first_header then raise Exit;
        incr pos_ref;
        let capacity = decode_int_prefix b 5 bytes pos_ref in
        if capacity > t.max_capacity then raise Exit
        else t.current_capacity <- min t.current_capacity capacity
      end
      else raise Exit
    done;
    Ok (List.rev !result)
  with Exit -> Error Decode_error

let decode_headers_string t s =
  decode_headers t (Bytes.of_string s)

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
}

let encoder_create capacity =
  { dec_tbl = create capacity; next_seq = 0 }

(* Write integer with N-bit prefix (§5.1) into a pre-allocated bytes buffer. *)
let encoder_write_int buf pos_ref prefix n i =
  let max_prefix = (1 lsl n) - 1 in
  if i < max_prefix then begin
    Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (prefix lor i));
    incr pos_ref
  end else begin
    Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (prefix lor max_prefix));
    incr pos_ref;
    let mutable rem = i - max_prefix in
    while rem >= 128 do
      Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (rem land 127 lor 128));
      incr pos_ref;
      rem <- rem lsr 7
    done;
    Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr rem);
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

(* Encode one header. *)
let encode_single_header enc buf pos_ref (h : header) =
  let name = h.name and value = h.value in
  let token = lookup_token_index name in
  (match token with
   | -1 ->
       (* Name not in static table — literal with indexing *)
       encoder_write_int buf pos_ref 0x40 6 0;
       encoder_write_string buf pos_ref name;
       encoder_write_string buf pos_ref value;
       dynamic_table_add enc.dec_tbl name value;
       enc.next_seq <- enc.next_seq + 1
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
            if h.sensitive || never_indexed_token t
               || (t = authorization_token && true)
               || (t = cookie_token && String.length value < 20)
            then
              (* Never indexed, name from static table *)
              let _ = encoder_write_int buf pos_ref 0x10 4 (t + 1) in
              encoder_write_string buf pos_ref value
            else
              (* Literal with incremental indexing, name from static table *)
              let _ = encoder_write_int buf pos_ref 0x40 6 (t + 1) in
              encoder_write_string buf pos_ref value;
              dynamic_table_add enc.dec_tbl name value;
              enc.next_seq <- enc.next_seq + 1))

(* Encode a list of headers into a fresh bytes buffer. *)
let encode_headers enc headers =
  let buf = Bytes.create 4096 in
  let pos_ref = ref 0 in
  List.iter (fun h -> encode_single_header enc buf pos_ref h) headers;
  Bytes.sub_string buf 0 !pos_ref
let decode_headers_string t s = decode_headers t (Bytes.of_string s)
