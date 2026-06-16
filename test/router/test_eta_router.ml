open Alcotest

let escape_tests =
  [ ( "unescape doubled braces",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/{{hello}}/{{world}}" in
        check string "bytes" "/{hello}/{world}" (Eta_router.Escape.to_string r);
        check bool "0" false (Eta_router.Escape.is_escaped r 0);
        (* '/' *)
        check bool "1" true (Eta_router.Escape.is_escaped r 1);
        (* '{' *)
        check bool "9" true (Eta_router.Escape.is_escaped r 9) );
    ( "slice preserves escaping",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/{{a}}/{b}" in
        let s = Eta_router.Escape.slice_off (Eta_router.Escape.full r) 1 in
        check string "slice" "{a}/{b}" (Eta_router.Escape.slice_to_string s);
        check bool "0 escaped" true (Eta_router.Escape.slice_is_escaped s 0);
        check bool "2 escaped" true (Eta_router.Escape.slice_is_escaped s 2);
        check bool "4 not escaped" false
          (Eta_router.Escape.slice_is_escaped s 4) );
    ( "common prefix with escapes",
      `Quick,
      fun () ->
        let a = Eta_router.Escape.of_string "/{{x}}" in
        let b = Eta_router.Escape.of_string "/{x}" in
        let pa = Eta_router.Escape.full a in
        let pb = Eta_router.Escape.full b in
        (* Both have '/' as first byte, but the second byte differs in escape
           status, so the common prefix is 1. *)
        check int "prefix" 1 (Eta_router.Escape.common_prefix pa pb) );
  ]

let route_tests =
  [ ( "find simple parameter",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/users/{id}" in
        match Eta_router.Route.find_wildcard (Eta_router.Escape.full r) with
        | Ok (Some w) ->
            check int "start" 7 w.start;
            check int "end" 11 w.end_
        | _ -> fail "expected wildcard" );
    ( "find catch-all",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/{*path}" in
        match Eta_router.Route.find_wildcard (Eta_router.Escape.full r) with
        | Ok (Some w) ->
            check int "start" 1 w.start;
            check int "end" 8 w.end_
        | _ -> fail "expected wildcard" );
    ( "reject empty parameter",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/users/{}" in
        check bool "error" true
          (match Eta_router.Route.find_wildcard (Eta_router.Escape.full r) with
          | Error (Eta_router.Error.Invalid_route _) -> true
          | _ -> false) );
    ( "reject slash in parameter",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/users/{a/b}" in
        check bool "error" true
          (match Eta_router.Route.find_wildcard (Eta_router.Escape.full r) with
          | Error (Eta_router.Error.Invalid_route _) -> true
          | _ -> false) );
    ( "normalize replaces names",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/users/{id}/posts/{slug}" in
        match Eta_router.Route.normalize r with
        | Ok (norm, remapping) ->
            check string "normalized" "/users/{a}/posts/{b}"
              (Eta_router.Escape.to_string norm);
            check (list string) "remapping" [ "id"; "slug" ] remapping
        | Error _ -> fail "expected ok" );
    ( "normalize preserves catch-all",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/{*path}" in
        match Eta_router.Route.normalize r with
        | Ok (norm, remapping) ->
            check string "normalized" "/{*path}" (Eta_router.Escape.to_string norm);
            check (list string) "remapping" [] remapping
        | Error _ -> fail "expected ok" );
    ( "denormalize restores names",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/users/{a}/posts/{b}" in
        let restored = Eta_router.Route.denormalize r [ "id"; "slug" ] in
        check string "denormalized" "/users/{id}/posts/{slug}"
          (Eta_router.Escape.to_string restored) );
    ( "escaped braces are not wildcards",
      `Quick,
      fun () ->
        let r = Eta_router.Escape.of_string "/{{hello}}" in
        match Eta_router.Route.find_wildcard (Eta_router.Escape.full r) with
        | Ok None -> ()
        | _ -> fail "expected no wildcard" );
  ]

(* Insertion test helpers ------------------------------------------------- *)

type expect =
  | Ok
  | Conflict
  | Invalid

let check_insert router route expected =
  let got = Eta_router.Router.insert router route route in
  let ok =
    match got, expected with
    | Ok (), Ok -> true
    | Error (Eta_router.Error.Conflict _), Conflict -> true
    | Error (Eta_router.Error.Invalid_route _), Invalid -> true
    | _ -> false
  in
  check bool route true ok

let run_insert_tests cases () =
  let router = Eta_router.Router.create () in
  List.iter (fun (route, expected) -> check_insert router route expected) cases

(* Ported from matchit tests/insert.rs ------------------------------------ *)

let wildcard_conflict_tests =
  [
    ("/cmd/{tool}/{sub}", Ok);
    ("/cmd/vet", Ok);
    ("/foo/bar", Ok);
    ("/foo/{name}", Ok);
    ("/foo/{names}", Conflict);
    ("/cmd/{*path}", Conflict);
    ("/cmd/{xxx}/names", Ok);
    ("/cmd/{tool}/{xxx}/foo", Ok);
    ("/src/{*filepath}", Ok);
    ("/src/{file}", Conflict);
    ("/src/static.json", Ok);
    ("/src/$filepathx", Ok);
    ("/src/", Ok);
    ("/src/foo/bar", Ok);
    ("/src1/", Ok);
    ("/src1/{*filepath}", Ok);
    ("/src2{*filepath}", Ok);
    ("/src2/{*filepath}", Ok);
    ("/src2/", Ok);
    ("/src2", Ok);
    ("/src3", Ok);
    ("/src3/{*filepath}", Ok);
    ("/search/{query}", Ok);
    ("/search/valid", Ok);
    ("/user_{name}", Ok);
    ("/user_x", Ok);
    ("/user_{bar}", Conflict);
    ("/id{id}", Ok);
    ("/id/{id}", Ok);
    ("/x/{id}", Ok);
    ("/x/{id}/", Ok);
    ("/x/{id}y", Ok);
    ("/x/{id}y/", Ok);
    ("/x/{id}y", Conflict);
    ("/x/x{id}", Conflict);
    ("/x/x{id}y", Conflict);
    ("/y/{id}", Ok);
    ("/y/{id}/", Ok);
    ("/y/y{id}", Ok);
    ("/y/y{id}/", Ok);
    ("/y/{id}y", Conflict);
    ("/y/{id}y/", Conflict);
    ("/y/x{id}y", Conflict);
    ("/z/x{id}y", Ok);
    ("/z/{id}", Ok);
    ("/z/{id}y", Conflict);
    ("/z/x{id}", Conflict);
    ("/z/y{id}", Conflict);
    ("/z/x{id}z", Conflict);
    ("/z/z{id}y", Conflict);
    ("/bar/{id}", Ok);
    ("/bar/x{id}y", Ok);
  ]

let prefix_suffix_conflict_tests =
  [
    ("/x1/{a}suffix", Ok);
    ("/x1/prefix{a}", Conflict);
    ("/x1/prefix{a}suffix", Conflict);
    ("/x1/suffix{a}prefix", Conflict);
    ("/x1", Ok);
    ("/x1/", Ok);
    ("/x1/{a}", Ok);
    ("/x1/{a}/", Ok);
    ("/x1/{a}suffix/", Ok);
    ("/x2/{a}suffix", Ok);
    ("/x2/{a}", Ok);
    ("/x2/prefix{a}", Conflict);
    ("/x2/prefix{a}suff", Conflict);
    ("/x2/prefix{a}suffix", Conflict);
    ("/x2/prefix{a}suffixy", Conflict);
    ("/x2", Ok);
    ("/x2/", Ok);
    ("/x2/{a}suffix/", Ok);
    ("/x3/prefix{a}", Ok);
    ("/x3/{a}suffix", Conflict);
    ("/x3/prefix{a}suffix", Conflict);
    ("/x3/prefix{a}/", Ok);
    ("/x3/{a}", Ok);
    ("/x3/{a}/", Ok);
    ("/x4/prefix{a}", Ok);
    ("/x4/{a}", Ok);
    ("/x4/{a}suffix", Conflict);
    ("/x4/suffix{a}p", Conflict);
    ("/x4/suffix{a}prefix", Conflict);
    ("/x4/prefix{a}/", Ok);
    ("/x4/{a}/", Ok);
    ("/x5/prefix1{a}", Ok);
    ("/x5/prefix2{a}", Ok);
    ("/x5/{a}suffix", Conflict);
    ("/x5/prefix{a}suffix", Conflict);
    ("/x5/prefix1{a}suffix", Conflict);
    ("/x5/prefix2{a}suffix", Conflict);
    ("/x5/prefix3{a}suffix", Conflict);
    ("/x5/prefix1{a}/", Ok);
    ("/x5/prefix2{a}/", Ok);
    ("/x5/prefix3{a}/", Ok);
    ("/x5/{a}", Ok);
    ("/x5/{a}/", Ok);
    ("/x6/prefix1{a}", Ok);
    ("/x6/prefix2{a}", Ok);
    ("/x6/{a}", Ok);
    ("/x6/{a}suffix", Conflict);
    ("/x6/prefix{a}suffix", Conflict);
    ("/x6/prefix1{a}suffix", Conflict);
    ("/x6/prefix2{a}suffix", Conflict);
    ("/x6/prefix3{a}suffix", Conflict);
    ("/x6/prefix1{a}/", Ok);
    ("/x6/prefix2{a}/", Ok);
    ("/x6/prefix3{a}/", Ok);
    ("/x6/{a}/", Ok);
    ("/x7/prefix{a}suffix", Ok);
    ("/x7/{a}suff", Conflict);
    ("/x7/{a}suffix", Conflict);
    ("/x7/{a}suffixy", Conflict);
    ("/x7/{a}prefix", Conflict);
    ("/x7/suffix{a}prefix", Conflict);
    ("/x7/prefix{a}", Conflict);
    ("/x7/another{a}", Conflict);
    ("/x7/suffix{a}", Conflict);
    ("/x7/prefix{a}/", Conflict);
    ("/x7/prefix{a}suff", Conflict);
    ("/x7/prefix{a}suffix", Conflict);
    ("/x7/prefix{a}suffixy", Conflict);
    ("/x7/prefix1{a}", Conflict);
    ("/x7/prefix{a}/", Conflict);
    ("/x7/{a}suffix/", Conflict);
    ("/x7/prefix{a}suffix/", Ok);
    ("/x7/{a}", Ok);
    ("/x7/{a}/", Ok);
    ("/x8/prefix{a}suffix", Ok);
    ("/x8/{a}", Ok);
    ("/x8/{a}suff", Conflict);
    ("/x8/{a}suffix", Conflict);
    ("/x8/{a}suffixy", Conflict);
    ("/x8/prefix{a}", Conflict);
    ("/x8/prefix{a}/", Conflict);
    ("/x8/prefix{a}suff", Conflict);
    ("/x8/prefix{a}suffix", Conflict);
    ("/x8/prefix{a}suffixy", Conflict);
    ("/x8/prefix1{a}", Conflict);
    ("/x8/prefix{a}/", Conflict);
    ("/x8/{a}suffix/", Conflict);
    ("/x8/prefix{a}suffix/", Ok);
    ("/x8/{a}/", Ok);
    ("/x9/prefix{a}", Ok);
    ("/x9/{a}suffix", Conflict);
    ("/x9/prefix{a}suffix", Conflict);
    ("/x9/prefixabc{a}suffix", Conflict);
    ("/x9/pre{a}suffix", Conflict);
    ("/x10/{a}", Ok);
    ("/x10/prefix{a}", Ok);
    ("/x10/{a}suffix", Conflict);
    ("/x10/prefix{a}suffix", Conflict);
    ("/x10/prefixabc{a}suffix", Conflict);
    ("/x10/pre{a}suffix", Conflict);
    ("/x11/{a}", Ok);
    ("/x11/{a}suffix", Ok);
    ("/x11/prx11fix{a}", Conflict);
    ("/x11/prx11fix{a}suff", Conflict);
    ("/x11/prx11fix{a}suffix", Conflict);
    ("/x11/prx11fix{a}suffixabc", Conflict);
    ("/x12/prefix{a}suffix", Ok);
    ("/x12/pre{a}", Conflict);
    ("/x12/prefix{a}", Conflict);
    ("/x12/prefixabc{a}", Conflict);
    ("/x12/pre{a}suffix", Conflict);
    ("/x12/prefix{a}suffix", Conflict);
    ("/x12/prefixabc{a}suffix", Conflict);
    ("/x12/prefix{a}suff", Conflict);
    ("/x12/prefix{a}suffix", Conflict);
    ("/x12/prefix{a}suffixabc", Conflict);
    ("/x12/{a}suff", Conflict);
    ("/x12/{a}suffix", Conflict);
    ("/x12/{a}suffixabc", Conflict);
    ("/x13/{a}", Ok);
    ("/x13/prefix{a}suffix", Ok);
    ("/x13/pre{a}", Conflict);
    ("/x13/prefix{a}", Conflict);
    ("/x13/prefixabc{a}", Conflict);
    ("/x13/pre{a}suffix", Conflict);
    ("/x13/prefix{a}suffix", Conflict);
    ("/x13/prefixabc{a}suffix", Conflict);
    ("/x13/prefix{a}suff", Conflict);
    ("/x13/prefix{a}suffix", Conflict);
    ("/x13/prefix{a}suffixabc", Conflict);
    ("/x13/{a}suff", Conflict);
    ("/x13/{a}suffix", Conflict);
    ("/x13/{a}suffixabc", Conflict);
    ("/x15/{*rest}", Ok);
    ("/x15/{a}suffix", Conflict);
    ("/x15/{a}suffix", Conflict);
    ("/x15/prefix{a}", Ok);
    ("/x16/{*rest}", Ok);
    ("/x16/prefix{a}suffix", Ok);
    ("/x17/prefix{a}/z", Ok);
    ("/x18/prefix{a}/z", Ok);
    ("/x19/f{a}o", Ok);
    ("/x19/f{a}o/{*path}", Ok);
    ("/x20/f{a}o/{*path}", Ok);
    ("/x20/f{a}o", Ok);
  ]

let missing_leading_slash_suffix_tests () =
  run_insert_tests
    [
      ("/{foo}", Ok);
      ("/{foo}suffix", Ok);
    ]
    ();
  run_insert_tests
    [
      ("{foo}", Ok);
      ("{foo}suffix", Ok);
    ]
    ()

let missing_leading_slash_conflict_tests () =
  run_insert_tests
    [
      ("{foo}/", Ok);
      ("foo/", Ok);
    ]
    ();
  run_insert_tests
    [
      ("foo/", Ok);
      ("{foo}/", Ok);
    ]
    ()

let child_conflict_tests =
  [
    ("/cmd/vet", Ok);
    ("/cmd/{tool}", Ok);
    ("/cmd/{tool}/{sub}", Ok);
    ("/cmd/{tool}/misc", Ok);
    ("/cmd/{tool}/{bad}", Conflict);
    ("/src/AUTHORS", Ok);
    ("/src/{*filepath}", Ok);
    ("/user_x", Ok);
    ("/user_{name}", Ok);
    ("/id/{id}", Ok);
    ("/id{id}", Ok);
    ("/{id}", Ok);
    ("/{*filepath}", Conflict);
  ]

let duplicates_tests =
  [
    ("/", Ok);
    ("/", Conflict);
    ("/doc/", Ok);
    ("/doc/", Conflict);
    ("/src/{*filepath}", Ok);
    ("/src/{*filepath}", Conflict);
    ("/search/{query}", Ok);
    ("/search/{query}", Conflict);
    ("/user_{name}", Ok);
    ("/user_{name}", Conflict);
  ]

let invalid_catchall_tests =
  [
    ("/non-leading-{*catchall}", Ok);
    ("/foo/bar{*catchall}", Ok);
    ("/src/{*filepath}x", Invalid);
    ("/src/{*filepath}/x", Invalid);
    ("/src2/", Ok);
    ("/src2/{*filepath}/x", Invalid);
  ]

let catchall_root_conflict_tests =
  [
    ("/", Ok);
    ("/{*filepath}", Ok);
  ]

let normalized_conflict_tests =
  [
    ("/x/{foo}/bar", Ok);
    ("/x/{bar}/bar", Conflict);
    ("/{y}/bar/baz", Ok);
    ("/{y}/baz/baz", Ok);
    ("/{z}/bar/bat", Ok);
    ("/{z}/bar/baz", Conflict);
  ]

let more_conflicts_tests =
  [
    ("/con{tact}", Ok);
    ("/who/are/{*you}", Ok);
    ("/who/foo/hello", Ok);
    ("/whose/{users}/{name}", Ok);
    ("/who/are/foo", Ok);
    ("/who/are/foo/bar", Ok);
    ("/con{nection}", Conflict);
    ("/whose/{users}/{user}", Conflict);
  ]

let catchall_static_overlap_tests () =
  run_insert_tests
    [
      ("/bar", Ok);
      ("/bar/", Ok);
      ("/bar/{*foo}", Ok);
    ]
    ();
  run_insert_tests
    [
      ("/foo", Ok);
      ("/{*bar}", Ok);
      ("/bar", Ok);
      ("/baz", Ok);
      ("/baz/{split}", Ok);
      ("/", Ok);
      ("/{*bar}", Conflict);
      ("/{*zzz}", Conflict);
      ("/{xxx}", Conflict);
    ]
    ();
  run_insert_tests
    [
      ("/{*bar}", Ok);
      ("/bar", Ok);
      ("/bar/x", Ok);
      ("/bar_{x}", Ok);
      ("/bar_{x}", Conflict);
      ("/bar_{x}/y", Ok);
      ("/bar/{x}", Ok);
    ]
    ()

let duplicate_conflict_tests =
  [
    ("/hey", Ok);
    ("/hey/users", Ok);
    ("/hey/user", Ok);
    ("/hey/user", Conflict);
  ]

let invalid_param_tests =
  [
    ("{", Invalid);
    ("}", Invalid);
    ("x{y", Invalid);
    ("x}", Invalid);
  ]

let unnamed_param_tests =
  [
    ("/{}", Invalid);
    ("/user{}/", Invalid);
    ("/cmd/{}/", Invalid);
    ("/src/{*}", Invalid);
  ]

let double_params_tests =
  [
    ("/{foo}{bar}", Invalid);
    ("/{foo}{bar}/", Invalid);
    ("/{foo}{{*bar}/", Invalid);
  ]

let escaped_param_tests =
  [
    ("{{", Ok);
    ("}}", Ok);
    ("xx}}", Ok);
    ("}}yy", Ok);
    ("}}yy{{}}", Ok);
    ("}}yy{{}}{{}}y{{", Ok);
    ("}}yy{{}}{{}}y{{", Conflict);
    ("/{{yy", Ok);
    ("/{yy}", Ok);
    ("/foo", Ok);
    ("/foo/{{", Ok);
    ("/foo/{{/{x}", Ok);
    ("/foo/{ba{{r}", Ok);
    ("/bar/{ba}}r}", Ok);
    ("/xxx/{x{{}}y}", Ok);
  ]

let bare_catchall_tests =
  [
    ("{*foo}", Ok);
    ("foo/{*bar}", Ok);
  ]

(* Match test helpers ----------------------------------------------------- *)

type match_expect =
  | Found of string * (string * string) list
  | Not_found

let check_match router path expected =
  match Eta_router.Router.at router path with
  | Ok m ->
    (match expected with
    | Not_found ->
      fail (Printf.sprintf "expected no match for %s, got value %s" path m.value)
    | Found (route, params) ->
      check string "route" route m.value;
      check (list (pair string string)) "params" params
        (Eta_router.Params.to_list m.params))
  | Error _ ->
    (match expected with
    | Found _ -> fail (Printf.sprintf "expected match for %s" path)
    | Not_found -> ())

let run_match_tests routes matches () =
  let router = Eta_router.Router.create () in
  List.iter
    (fun route ->
      match Eta_router.Router.insert router route route with
      | Ok () -> ()
      | Error _ -> fail (Printf.sprintf "insert %s failed" route))
    routes;
  List.iter (fun (path, expected) -> check_match router path expected) matches

let m route params = Found (route, params)
let nf = Not_found

(* Ported from matchit tests/match.rs -------------------------------------- *)

let partial_overlap_tests =
  [
    ([ "/foo_bar"; "/foo/bar" ], [ ("/foo/", nf) ]);
    ([ "/foo"; "/foo/bar" ], [ ("/foo/", nf) ]);
  ]

let wildcard_overlap_tests =
  [
    ( [ "/path/foo"; "/path/{*rest}" ],
      [
        ("/path/foo", m "/path/foo" []);
        ("/path/bar", m "/path/{*rest}" [ ("rest", "bar") ]);
        ("/path/foo/", m "/path/{*rest}" [ ("rest", "foo/") ]);
      ] );
    ( [ "/path/foo/{arg}"; "/path/{*rest}" ],
      [
        ("/path/foo/myarg", m "/path/foo/{arg}" [ ("arg", "myarg") ]);
        ("/path/foo/myarg/", m "/path/{*rest}" [ ("rest", "foo/myarg/") ]);
        ( "/path/foo/myarg/bar/baz",
          m "/path/{*rest}" [ ("rest", "foo/myarg/bar/baz") ] );
      ] );
  ]

let overlapping_param_backtracking_tests =
  [
    ( [
        "/{object}/{id}";
        "/secret/{id}/path";
      ],
      [
        ("/secret/978/path", m "/secret/{id}/path" [ ("id", "978") ]);
        ( "/something/978",
          m "/{object}/{id}"
            [ ("object", "something"); ("id", "978") ] );
        ("/secret/978", m "/{object}/{id}" [ ("object", "secret"); ("id", "978") ]);
      ] );
  ]

let empty_route_tests =
  [ ([ ""; "/foo" ], [ ("", m "" []); ("/foo", m "/foo" []) ]) ]

let match_bare_catchall_tests =
  [
    ( [ "{*foo}"; "foo/{*bar}" ],
      [
        ("x/y", m "{*foo}" [ ("foo", "x/y") ]);
        ("/x/y", m "{*foo}" [ ("foo", "/x/y") ]);
        ("/foo/x/y", m "{*foo}" [ ("foo", "/foo/x/y") ]);
        ("foo/x/y", m "foo/{*bar}" [ ("bar", "x/y") ]);
      ] );
  ]

let param_suffix_flag_issue_tests =
  [
    ( [ "/foo/{foo}suffix"; "/foo/{foo}/bar" ],
      [ ("/foo/barsuffix", m "/foo/{foo}suffix" [ ("foo", "bar") ]) ] );
  ]

let normalized_tests =
  [
    ( [
        "/x/{foo}/bar";
        "/x/{bar}/baz";
        "/{foo}/{baz}/bax";
        "/{foo}/{bar}/baz";
        "/{fod}/{baz}/{bax}/foo";
        "/{fod}/baz/bax/foo";
        "/{foo}/baz/bax";
        "/{bar}/{bay}/bay";
        "/s";
        "/s/s";
        "/s/s/s";
        "/s/s/s/s";
        "/s/s/{s}/x";
        "/s/s/{y}/d";
      ],
      [
        ("/x/foo/bar", m "/x/{foo}/bar" [ ("foo", "foo") ]);
        ("/x/foo/baz", m "/x/{bar}/baz" [ ("bar", "foo") ]);
        ("/y/foo/baz", m "/{foo}/{bar}/baz" [ ("foo", "y"); ("bar", "foo") ]);
        ("/y/foo/bax", m "/{foo}/{baz}/bax" [ ("foo", "y"); ("baz", "foo") ]);
        ("/y/baz/baz", m "/{foo}/{bar}/baz" [ ("foo", "y"); ("bar", "baz") ]);
        ("/y/baz/bax/foo", m "/{fod}/baz/bax/foo" [ ("fod", "y") ]);
        ("/y/baz/b/foo", m "/{fod}/{baz}/{bax}/foo" [ ("fod", "y"); ("baz", "baz"); ("bax", "b") ]);
        ("/y/baz/bax", m "/{foo}/baz/bax" [ ("foo", "y") ]);
        ("/z/bar/bay", m "/{bar}/{bay}/bay" [ ("bar", "z"); ("bay", "bar") ]);
        ("/s", m "/s" []);
        ("/s/s", m "/s/s" []);
        ("/s/s/s", m "/s/s/s" []);
        ("/s/s/s/s", m "/s/s/s/s" []);
        ("/s/s/s/x", m "/s/s/{s}/x" [ ("s", "s") ]);
        ("/s/s/s/d", m "/s/s/{y}/d" [ ("y", "s") ]);
      ] );
  ]

let blog_tests =
  [
    ( [
        "/{page}";
        "/posts/{year}/{month}/{post}";
        "/posts/{year}/{month}/index";
        "/posts/{year}/top";
        "/static/{*path}";
        "/favicon.ico";
      ],
      [
        ("/about", m "/{page}" [ ("page", "about") ]);
        ( "/posts/2021/01/rust",
          m "/posts/{year}/{month}/{post}"
            [ ("year", "2021"); ("month", "01"); ("post", "rust") ] );
        ( "/posts/2021/01/index",
          m "/posts/{year}/{month}/index"
            [ ("year", "2021"); ("month", "01") ] );
        ("/posts/2021/top", m "/posts/{year}/top" [ ("year", "2021") ]);
        ("/static/foo.png", m "/static/{*path}" [ ("path", "foo.png") ]);
        ("/favicon.ico", m "/favicon.ico" []);
      ] );
  ]

let double_overlap_tests =
  [
    ( [
        "/{object}/{id}";
        "/secret/{id}/path";
        "/secret/978";
        "/other/{object}/{id}/";
        "/other/an_object/{id}";
        "/other/static/path";
        "/other/long/static/path/";
      ],
      [
        ("/secret/978/path", m "/secret/{id}/path" [ ("id", "978") ]);
        ( "/some_object/978",
          m "/{object}/{id}" [ ("object", "some_object"); ("id", "978") ] );
        ("/secret/978", m "/secret/978" []);
        ("/super_secret/978/", nf);
        ( "/other/object/1/",
          m "/other/{object}/{id}/"
            [ ("object", "object"); ("id", "1") ] );
        ("/other/object/1/2", nf);
        ("/other/an_object/1", m "/other/an_object/{id}" [ ("id", "1") ]);
        ("/other/static/path", m "/other/static/path" []);
        ("/other/long/static/path/", m "/other/long/static/path/" []);
      ] );
  ]

let catchall_off_by_one_tests =
  [
    ( [ "/foo/{*catchall}"; "/bar"; "/bar/"; "/bar/{*catchall}" ],
      [
        ("/foo", nf);
        ("/foo/", nf);
        ("/foo/x", m "/foo/{*catchall}" [ ("catchall", "x") ]);
        ("/bar", m "/bar" []);
        ("/bar/", m "/bar/" []);
        ("/bar/x", m "/bar/{*catchall}" [ ("catchall", "x") ]);
      ] );
  ]

let overlap_tests =
  [
    ( [
        "/foo";
        "/bar";
        "/{*bar}";
        "/baz";
        "/baz/";
        "/baz/x";
        "/baz/{xxx}";
        "/";
        "/xxx/{*x}";
        "/xxx/";
      ],
      [
        ("/foo", m "/foo" []);
        ("/bar", m "/bar" []);
        ("/baz", m "/baz" []);
        ("/baz/", m "/baz/" []);
        ("/baz/x", m "/baz/x" []);
        ("/???", m "/{*bar}" [ ("bar", "???") ]);
        ("/", m "/" []);
        ("", nf);
        ("/xxx/y", m "/xxx/{*x}" [ ("x", "y") ]);
        ("/xxx/", m "/xxx/" []);
        ("/xxx", m "/{*bar}" [ ("bar", "xxx") ]);
      ] );
  ]

let missing_trailing_slash_param_tests =
  [
    ( [ "/foo/{object}/{id}"; "/foo/bar/baz"; "/foo/secret/978/" ],
      [
        ("/foo/secret/978/", m "/foo/secret/978/" []);
        ( "/foo/secret/978",
          m "/foo/{object}/{id}"
            [ ("object", "secret"); ("id", "978") ] );
      ] );
  ]

let extra_trailing_slash_param_tests =
  [
    ( [ "/foo/{object}/{id}"; "/foo/bar/baz"; "/foo/secret/978" ],
      [
        ("/foo/secret/978/", nf);
        ("/foo/secret/978", m "/foo/secret/978" []);
      ] );
  ]

let missing_trailing_slash_catch_all_tests =
  [
    ( [ "/foo/{*bar}"; "/foo/bar/baz"; "/foo/secret/978/" ],
      [
        ("/foo/secret/978", m "/foo/{*bar}" [ ("bar", "secret/978") ]);
        ("/foo/secret/978/", m "/foo/secret/978/" []);
      ] );
  ]

let extra_trailing_slash_catch_all_tests =
  [
    ( [ "/foo/{*bar}"; "/foo/bar/baz"; "/foo/secret/978" ],
      [
        ("/foo/secret/978/", m "/foo/{*bar}" [ ("bar", "secret/978/") ]);
        ("/foo/secret/978", m "/foo/secret/978" []);
      ] );
  ]

let double_overlap_trailing_slash_tests =
  [
    ( [
        "/{object}/{id}";
        "/secret/{id}/path";
        "/secret/978/";
        "/other/{object}/{id}/";
        "/other/an_object/{id}";
        "/other/static/path";
        "/other/long/static/path/";
      ],
      [
        ("/secret/978/path/", nf);
        ("/object/id/", nf);
        ("/object/id/path", nf);
        ("/other/object/1", nf);
        ("/other/object/1/2", nf);
        ( "/other/an_object/1/",
          m "/other/{object}/{id}/"
            [ ("object", "an_object"); ("id", "1") ] );
        ( "/other/static/path/",
          m "/other/{object}/{id}/"
            [ ("object", "static"); ("id", "path") ] );
        ("/other/long/static/path", nf);
        ("/other/object/static/path", nf);
      ] );
  ]

let trailing_slash_overlap_tests =
  [
    ( [ "/foo/{x}/baz/"; "/foo/{x}/baz"; "/foo/bar/bar" ],
      [
        ("/foo/x/baz/", m "/foo/{x}/baz/" [ ("x", "x") ]);
        ("/foo/x/baz", m "/foo/{x}/baz" [ ("x", "x") ]);
        ("/foo/bar/bar", m "/foo/bar/bar" []);
      ] );
  ]

let trailing_slash_tests =
  [
    ( [
        "/hi";
        "/b/";
        "/search/{query}";
        "/cmd/{tool}/";
        "/src/{*filepath}";
        "/x";
        "/x/y";
        "/y/";
        "/y/z";
        "/0/{id}";
        "/0/{id}/1";
        "/1/{id}/";
        "/1/{id}/2";
        "/aa";
        "/a/";
        "/admin";
        "/admin/static";
        "/admin/{category}";
        "/admin/{category}/{page}";
        "/doc";
        "/doc/rust_faq.html";
        "/doc/rust1.26.html";
        "/no/a";
        "/no/b";
        "/no/a/b/{*other}";
        "/api/{page}/{name}";
        "/api/hello/{name}/bar/";
        "/api/bar/{name}";
        "/api/baz/foo";
        "/api/baz/foo/bar";
        "/foo/{p}";
      ],
      [
        ("/hi/", nf);
        ("/b", nf);
        ("/search/rustacean/", nf);
        ("/cmd/vet", nf);
        ("/src", nf);
        ("/src/", nf);
        ("/x/", nf);
        ("/y", nf);
        ("/0/rust/", nf);
        ("/1/rust", nf);
        ("/a", nf);
        ("/admin/", nf);
        ("/doc/", nf);
        ("/admin/static/", nf);
        ("/admin/cfg/", nf);
        ("/admin/cfg/users/", nf);
        ("/api/hello/x/bar", nf);
        ("/api/baz/foo/", nf);
        ("/api/baz/bax/", nf);
        ("/api/bar/huh/", nf);
        ("/api/baz/foo/bar/", nf);
        ("/api/world/abc/", nf);
        ("/foo/pp/", nf);
        ("/", nf);
        ("/no", nf);
        ("/no/", nf);
        ("/no/a/b", nf);
        ("/no/a/b/", nf);
        ("/_/", nf);
        ("/api", nf);
        ("/api/", nf);
        ("/api/hello/x/foo", nf);
        ("/api/baz/foo/bad", nf);
        ("/foo/p/p", nf);
      ] );
  ]

let backtracking_trailing_slash_tests =
  [
    ( [ "/a/{b}/{c}"; "/a/b/{c}/d/" ], [ ("/a/b/c/d", nf) ] );
  ]

let root_trailing_slash_tests =
  [ ([ "/foo"; "/bar"; "/{baz}" ], [ ("/", nf) ]) ]

let catchall_overlap_tests =
  [
    ( [ "/yyy/{*x}"; "/yyy{*x}" ],
      [
        ("/yyy/y", m "/yyy/{*x}" [ ("x", "y") ]);
        ("/yyy/", m "/yyy{*x}" [ ("x", "/") ]);
      ] );
  ]

let escaped_tests =
  [
    ( [
        "/";
        "/{{";
        "/}}";
        "/{{x";
        "/}}y{{";
        "/xy{{";
        "/{{/xyz";
        "/{ba{{r}";
        "/{ba{{r}/";
        "/{ba{{r}/x";
        "/baz/{xxx}";
        "/baz/{xxx}/xy{{";
        "/baz/{xxx}/}}xy{{{{";
        "/{{/{x}";
        "/xxx/";
        "/xxx/{x}}{{}}}}{{}}{{{{}}y}";
      ],
      [
        ("/", m "/" []);
        ("/{", m "/{{" []);
        ("/}", m "/}}" []);
        ("/{x", m "/{{x" []);
        ("/}y{", m "/}}y{{" []);
        ("/xy{", m "/xy{{" []);
        ("/{/xyz", m "/{{/xyz" []);
        ("/foo", m "/{ba{{r}" [ ("ba{r", "foo") ]);
        ("/{{", m "/{ba{{r}" [ ("ba{r", "{{") ]);
        ("/{{}}/", m "/{ba{{r}/" [ ("ba{r", "{{}}") ]);
        ("/{{}}{{/x", m "/{ba{{r}/x" [ ("ba{r", "{{}}{{") ]);
        ("/baz/x", m "/baz/{xxx}" [ ("xxx", "x") ]);
        ("/baz/x/xy{", m "/baz/{xxx}/xy{{" [ ("xxx", "x") ]);
        ("/baz/x/xy{{", nf);
        ("/baz/x/}xy{{", m "/baz/{xxx}/}}xy{{{{" [ ("xxx", "x") ]);
        ("/{/{{", m "/{{/{x}" [ ("x", "{{") ]);
        ("/xxx", m "/{ba{{r}" [ ("ba{r", "xxx") ]);
        ("/xxx/", m "/xxx/" []);
        ( "/xxx/foo",
          m "/xxx/{x}}{{}}}}{{}}{{{{}}y}"
            [ ("x}{}}{}{{}y", "foo") ] );
      ] );
  ]

let empty_param_tests =
  [
    ( [ "/y/{foo}"; "/x/{foo}/z"; "/z/{*foo}"; "/a/x{foo}"; "/b/{foo}x" ],
      [
        ("/y/", nf);
        ("/x//z", nf);
        ("/z/", nf);
        ("/a/x", nf);
        ("/b/x", nf);
      ] );
  ]

let wildcard_suffix_tests =
  [
    ( [
        "/";
        "/{foo}x";
        "/foox";
        "/{foo}x/bar";
        "/{foo}x/bar/baz";
      ],
      [
        ("/", m "/" []);
        ("/foox", m "/foox" []);
        ("/barx", m "/{foo}x" [ ("foo", "bar") ]);
        ("/mx", m "/{foo}x" [ ("foo", "m") ]);
        ("/mx/", nf);
        ("/mxm", nf);
        ("/mx/bar", m "/{foo}x/bar" [ ("foo", "m") ]);
        ("/mxm/bar", nf);
        ("/x", nf);
        ("/xfoo", nf);
        ("/xfoox", m "/{foo}x" [ ("foo", "xfoo") ]);
        ("/xfoox/bar", m "/{foo}x/bar" [ ("foo", "xfoo") ]);
        ("/xfoox/bar/baz", m "/{foo}x/bar/baz" [ ("foo", "xfoo") ]);
      ] );
  ]

let mixed_wildcard_suffix_tests =
  [
    ( [
        "/";
        "/{f}o/b";
        "/{f}oo/b";
        "/{f}ooo/b";
        "/{f}oooo/b";
        "/foo/b";
        "/foo/{b}";
        "/foo/{b}one";
        "/foo/{b}one/";
        "/foo/{b}two";
        "/foo/{b}/one";
        "/foo/{b}one/one";
        "/foo/{b}two/one";
        "/foo/{b}one/one/";
        "/bar/{b}one";
        "/bar/{b}";
        "/bar/{b}/baz";
        "/bar/{b}one/baz";
        "/baz/{b}/bar";
        "/baz/{b}one/bar";
      ],
      [
        ("/", m "/" []);
        ("/o/b", nf);
        ("/fo/b", m "/{f}o/b" [ ("f", "f") ]);
        ("/foo/b", m "/foo/b" []);
        ("/fooo/b", m "/{f}ooo/b" [ ("f", "f") ]);
        ("/foooo/b", m "/{f}oooo/b" [ ("f", "f") ]);
        ("/foo/b/", nf);
        ("/foooo/b/", nf);
        ("/foo/bb", m "/foo/{b}" [ ("b", "bb") ]);
        ("/foo/bone", m "/foo/{b}one" [ ("b", "b") ]);
        ("/foo/bone/", m "/foo/{b}one/" [ ("b", "b") ]);
        ("/foo/btwo", m "/foo/{b}two" [ ("b", "b") ]);
        ("/foo/btwo/", nf);
        ("/foo/b/one", m "/foo/{b}/one" [ ("b", "b") ]);
        ("/foo/bone/one", m "/foo/{b}one/one" [ ("b", "b") ]);
        ("/foo/bone/one/", m "/foo/{b}one/one/" [ ("b", "b") ]);
        ("/foo/btwo/one", m "/foo/{b}two/one" [ ("b", "b") ]);
        ("/bar/b", m "/bar/{b}" [ ("b", "b") ]);
        ("/bar/b/baz", m "/bar/{b}/baz" [ ("b", "b") ]);
        ("/bar/bone", m "/bar/{b}one" [ ("b", "b") ]);
        ("/bar/bone/baz", m "/bar/{b}one/baz" [ ("b", "b") ]);
        ("/baz/b/bar", m "/baz/{b}/bar" [ ("b", "b") ]);
        ("/baz/bone/bar", m "/baz/{b}one/bar" [ ("b", "b") ]);
      ] );
  ]

let basic_tests =
  [
    ( [
        "/hi";
        "/contact";
        "/co";
        "/c";
        "/a";
        "/ab";
        "/doc/";
        "/doc/rust_faq.html";
        "/doc/rust1.26.html";
        "/ʯ";
        "/β";
        "/sd!here";
        "/sd$here";
        "/sd&here";
        "/sd'here";
        "/sd(here";
        "/sd)here";
        "/sd+here";
        "/sd,here";
        "/sd;here";
        "/sd=here";
      ],
      [
        ("/a", m "/a" []);
        ("", nf);
        ("/hi", m "/hi" []);
        ("/contact", m "/contact" []);
        ("/co", m "/co" []);
        ("", nf);
        ("", nf);
        ("", nf);
        ("/ab", m "/ab" []);
        ("/ʯ", m "/ʯ" []);
        ("/β", m "/β" []);
        ("/sd!here", m "/sd!here" []);
        ("/sd$here", m "/sd$here" []);
        ("/sd&here", m "/sd&here" []);
        ("/sd'here", m "/sd'here" []);
        ("/sd(here", m "/sd(here" []);
        ("/sd)here", m "/sd)here" []);
        ("/sd+here", m "/sd+here" []);
        ("/sd,here", m "/sd,here" []);
        ("/sd;here", m "/sd;here" []);
        ("/sd=here", m "/sd=here" []);
      ] );
  ]

let wildcard_tests =
  [
    ( [
        "/";
        "/cmd/{tool}/";
        "/cmd/{tool2}/{sub}";
        "/cmd/whoami";
        "/cmd/whoami/root";
        "/cmd/whoami/root/";
        "/src";
        "/src/";
        "/src/{*filepath}";
        "/search/";
        "/search/{query}";
        "/search/actix-web";
        "/search/google";
        "/user_{name}";
        "/user_{name}/about";
        "/files/{dir}/{*filepath}";
        "/doc/";
        "/doc/rust_faq.html";
        "/doc/rust1.26.html";
        "/info/{user}/public";
        "/info/{user}/project/{project}";
        "/info/{user}/project/rustlang";
        "/aa/{*xx}";
        "/ab/{*xx}";
        "/ab/hello{*xx}";
        "/{cc}";
        "/c1/{dd}/e";
        "/c1/{dd}/e1";
        "/{cc}/cc";
        "/{cc}/{dd}/ee";
        "/{cc}/{dd}/{ee}/ff";
        "/{cc}/{dd}/{ee}/{ff}/gg";
        "/{cc}/{dd}/{ee}/{ff}/{gg}/hh";
        "/get/test/abc/";
        "/get/{param}/abc/";
        "/something/{paramname}/thirdthing";
        "/something/secondthing/test";
        "/get/abc";
        "/get/{param}";
        "/get/abc/123abc";
        "/get/abc/{param}";
        "/get/abc/123abc/xxx8";
        "/get/abc/123abc/{param}";
        "/get/abc/123abc/xxx8/1234";
        "/get/abc/123abc/xxx8/{param}";
        "/get/abc/123abc/xxx8/1234/ffas";
        "/get/abc/123abc/xxx8/1234/{param}";
        "/get/abc/123abc/xxx8/1234/kkdd/12c";
        "/get/abc/123abc/xxx8/1234/kkdd/{param}";
        "/get/abc/{param}/test";
        "/get/abc/123abd/{param}";
        "/get/abc/123abddd/{param}";
        "/get/abc/123/{param}";
        "/get/abc/123abg/{param}";
        "/get/abc/123abf/{param}";
        "/get/abc/123abfff/{param}";
      ],
      [
        ("/", m "/" []);
        ("/cmd/test", nf);
        ("/cmd/test/", m "/cmd/{tool}/" [ ("tool", "test") ]);
        ("/cmd/test/3", m "/cmd/{tool2}/{sub}" [ ("tool2", "test"); ("sub", "3") ]);
        ("/cmd/who", nf);
        ("/cmd/who/", m "/cmd/{tool}/" [ ("tool", "who") ]);
        ("/cmd/whoami", m "/cmd/whoami" []);
        ("/cmd/whoami/", m "/cmd/{tool}/" [ ("tool", "whoami") ]);
        ("/cmd/whoami/r", m "/cmd/{tool2}/{sub}" [ ("tool2", "whoami"); ("sub", "r") ]);
        ("/cmd/whoami/r/", nf);
        ("/cmd/whoami/root", m "/cmd/whoami/root" []);
        ("/cmd/whoami/root/", m "/cmd/whoami/root/" []);
        ("/src", m "/src" []);
        ("/src/", m "/src/" []);
        ("/src/some/file.png", m "/src/{*filepath}" [ ("filepath", "some/file.png") ]);
        ("/search/", m "/search/" []);
        ("/search/actix", m "/search/{query}" [ ("query", "actix") ]);
        ("/search/actix-web", m "/search/actix-web" []);
        ("/search/someth!ng+in+ünìcodé", m "/search/{query}" [ ("query", "someth!ng+in+ünìcodé") ]);
        ("/search/someth!ng+in+ünìcodé/", nf);
        ("/user_rustacean", m "/user_{name}" [ ("name", "rustacean") ]);
        ("/user_rustacean/about", m "/user_{name}/about" [ ("name", "rustacean") ]);
        ("/files/js/inc/framework.js", m "/files/{dir}/{*filepath}" [ ("dir", "js"); ("filepath", "inc/framework.js") ]);
        ("/info/gordon/public", m "/info/{user}/public" [ ("user", "gordon") ]);
        ("/info/gordon/project/rust", m "/info/{user}/project/{project}" [ ("user", "gordon"); ("project", "rust") ]);
        ("/info/gordon/project/rustlang", m "/info/{user}/project/rustlang" [ ("user", "gordon") ]);
        ("/aa/", nf);
        ("/aa/aa", m "/aa/{*xx}" [ ("xx", "aa") ]);
        ("/ab/ab", m "/ab/{*xx}" [ ("xx", "ab") ]);
        ("/ab/hello-world", m "/ab/hello{*xx}" [ ("xx", "-world") ]);
        ("/a", m "/{cc}" [ ("cc", "a") ]);
        ("/all", m "/{cc}" [ ("cc", "all") ]);
        ("/d", m "/{cc}" [ ("cc", "d") ]);
        ("/ad", m "/{cc}" [ ("cc", "ad") ]);
        ("/dd", m "/{cc}" [ ("cc", "dd") ]);
        ("/dddaa", m "/{cc}" [ ("cc", "dddaa") ]);
        ("/aa", m "/{cc}" [ ("cc", "aa") ]);
        ("/aaa", m "/{cc}" [ ("cc", "aaa") ]);
        ("/aaa/cc", m "/{cc}/cc" [ ("cc", "aaa") ]);
        ("/ab", m "/{cc}" [ ("cc", "ab") ]);
        ("/abb", m "/{cc}" [ ("cc", "abb") ]);
        ("/abb/cc", m "/{cc}/cc" [ ("cc", "abb") ]);
        ("/allxxxx", m "/{cc}" [ ("cc", "allxxxx") ]);
        ("/alldd", m "/{cc}" [ ("cc", "alldd") ]);
        ("/all/cc", m "/{cc}/cc" [ ("cc", "all") ]);
        ("/a/cc", m "/{cc}/cc" [ ("cc", "a") ]);
        ("/c1/d/e", m "/c1/{dd}/e" [ ("dd", "d") ]);
        ("/c1/d/e1", m "/c1/{dd}/e1" [ ("dd", "d") ]);
        ("/c1/d/ee", m "/{cc}/{dd}/ee" [ ("cc", "c1"); ("dd", "d") ]);
        ("/cc/cc", m "/{cc}/cc" [ ("cc", "cc") ]);
        ("/ccc/cc", m "/{cc}/cc" [ ("cc", "ccc") ]);
        ("/deedwjfs/cc", m "/{cc}/cc" [ ("cc", "deedwjfs") ]);
        ("/acllcc/cc", m "/{cc}/cc" [ ("cc", "acllcc") ]);
        ("/get/test/abc/", m "/get/test/abc/" []);
        ("/get/te/abc/", m "/get/{param}/abc/" [ ("param", "te") ]);
        ("/get/testaa/abc/", m "/get/{param}/abc/" [ ("param", "testaa") ]);
        ("/get/xx/abc/", m "/get/{param}/abc/" [ ("param", "xx") ]);
        ("/get/tt/abc/", m "/get/{param}/abc/" [ ("param", "tt") ]);
        ("/get/a/abc/", m "/get/{param}/abc/" [ ("param", "a") ]);
        ("/get/t/abc/", m "/get/{param}/abc/" [ ("param", "t") ]);
        ("/get/aa/abc/", m "/get/{param}/abc/" [ ("param", "aa") ]);
        ("/get/abas/abc/", m "/get/{param}/abc/" [ ("param", "abas") ]);
        ("/something/secondthing/test", m "/something/secondthing/test" []);
        ("/something/abcdad/thirdthing", m "/something/{paramname}/thirdthing" [ ("paramname", "abcdad") ]);
        ("/something/secondthingaaaa/thirdthing", m "/something/{paramname}/thirdthing" [ ("paramname", "secondthingaaaa") ]);
        ("/something/se/thirdthing", m "/something/{paramname}/thirdthing" [ ("paramname", "se") ]);
        ("/something/s/thirdthing", m "/something/{paramname}/thirdthing" [ ("paramname", "s") ]);
        ("/c/d/ee", m "/{cc}/{dd}/ee" [ ("cc", "c"); ("dd", "d") ]);
        ("/c/d/e/ff", m "/{cc}/{dd}/{ee}/ff" [ ("cc", "c"); ("dd", "d"); ("ee", "e") ]);
        ("/c/d/e/f/gg", m "/{cc}/{dd}/{ee}/{ff}/gg" [ ("cc", "c"); ("dd", "d"); ("ee", "e"); ("ff", "f") ]);
        ("/c/d/e/f/g/hh", m "/{cc}/{dd}/{ee}/{ff}/{gg}/hh" [ ("cc", "c"); ("dd", "d"); ("ee", "e"); ("ff", "f"); ("gg", "g") ]);
        ("/cc/dd/ee/ff/gg/hh", m "/{cc}/{dd}/{ee}/{ff}/{gg}/hh" [ ("cc", "cc"); ("dd", "dd"); ("ee", "ee"); ("ff", "ff"); ("gg", "gg") ]);
        ("/get/abc", m "/get/abc" []);
        ("/get/a", m "/get/{param}" [ ("param", "a") ]);
        ("/get/abz", m "/get/{param}" [ ("param", "abz") ]);
        ("/get/12a", m "/get/{param}" [ ("param", "12a") ]);
        ("/get/abcd", m "/get/{param}" [ ("param", "abcd") ]);
        ("/get/abc/123abc", m "/get/abc/123abc" []);
        ("/get/abc/12", m "/get/abc/{param}" [ ("param", "12") ]);
        ("/get/abc/123ab", m "/get/abc/{param}" [ ("param", "123ab") ]);
        ("/get/abc/xyz", m "/get/abc/{param}" [ ("param", "xyz") ]);
        ("/get/abc/123abcddxx", m "/get/abc/{param}" [ ("param", "123abcddxx") ]);
        ("/get/abc/123abc/xxx8", m "/get/abc/123abc/xxx8" []);
        ("/get/abc/123abc/x", m "/get/abc/123abc/{param}" [ ("param", "x") ]);
        ("/get/abc/123abc/xxx", m "/get/abc/123abc/{param}" [ ("param", "xxx") ]);
        ("/get/abc/123abc/abc", m "/get/abc/123abc/{param}" [ ("param", "abc") ]);
        ("/get/abc/123abc/xxx8xxas", m "/get/abc/123abc/{param}" [ ("param", "xxx8xxas") ]);
        ("/get/abc/123abc/xxx8/1234", m "/get/abc/123abc/xxx8/1234" []);
        ("/get/abc/123abc/xxx8/1", m "/get/abc/123abc/xxx8/{param}" [ ("param", "1") ]);
        ("/get/abc/123abc/xxx8/123", m "/get/abc/123abc/xxx8/{param}" [ ("param", "123") ]);
        ("/get/abc/123abc/xxx8/78k", m "/get/abc/123abc/xxx8/{param}" [ ("param", "78k") ]);
        ("/get/abc/123abc/xxx8/1234xxxd", m "/get/abc/123abc/xxx8/{param}" [ ("param", "1234xxxd") ]);
        ("/get/abc/123abc/xxx8/1234/ffas", m "/get/abc/123abc/xxx8/1234/ffas" []);
        ("/get/abc/123abc/xxx8/1234/f", m "/get/abc/123abc/xxx8/1234/{param}" [ ("param", "f") ]);
        ("/get/abc/123abc/xxx8/1234/ffa", m "/get/abc/123abc/xxx8/1234/{param}" [ ("param", "ffa") ]);
        ("/get/abc/123abc/xxx8/1234/kka", m "/get/abc/123abc/xxx8/1234/{param}" [ ("param", "kka") ]);
        ("/get/abc/123abc/xxx8/1234/ffas321", m "/get/abc/123abc/xxx8/1234/{param}" [ ("param", "ffas321") ]);
        ("/get/abc/123abc/xxx8/1234/kkdd/12c", m "/get/abc/123abc/xxx8/1234/kkdd/12c" []);
        ("/get/abc/123abc/xxx8/1234/kkdd/1", m "/get/abc/123abc/xxx8/1234/kkdd/{param}" [ ("param", "1") ]);
        ("/get/abc/123abc/xxx8/1234/kkdd/12", m "/get/abc/123abc/xxx8/1234/kkdd/{param}" [ ("param", "12") ]);
        ("/get/abc/123abc/xxx8/1234/kkdd/12b", m "/get/abc/123abc/xxx8/1234/kkdd/{param}" [ ("param", "12b") ]);
        ("/get/abc/123abc/xxx8/1234/kkdd/34", m "/get/abc/123abc/xxx8/1234/kkdd/{param}" [ ("param", "34") ]);
        ("/get/abc/123abc/xxx8/1234/kkdd/12c2e3", m "/get/abc/123abc/xxx8/1234/kkdd/{param}" [ ("param", "12c2e3") ]);
        ("/get/abc/12/test", m "/get/abc/{param}/test" [ ("param", "12") ]);
        ("/get/abc/123abdd/test", m "/get/abc/{param}/test" [ ("param", "123abdd") ]);
        ("/get/abc/123abdddf/test", m "/get/abc/{param}/test" [ ("param", "123abdddf") ]);
        ("/get/abc/123ab/test", m "/get/abc/{param}/test" [ ("param", "123ab") ]);
        ("/get/abc/123abgg/test", m "/get/abc/{param}/test" [ ("param", "123abgg") ]);
        ("/get/abc/123abff/test", m "/get/abc/{param}/test" [ ("param", "123abff") ]);
        ("/get/abc/123abffff/test", m "/get/abc/{param}/test" [ ("param", "123abffff") ]);
        ("/get/abc/123abd/test", m "/get/abc/123abd/{param}" [ ("param", "test") ]);
        ("/get/abc/123abddd/test", m "/get/abc/123abddd/{param}" [ ("param", "test") ]);
        ("/get/abc/123/test22", m "/get/abc/123/{param}" [ ("param", "test22") ]);
        ("/get/abc/123abg/test", m "/get/abc/123abg/{param}" [ ("param", "test") ]);
        ("/get/abc/123abf/testss", m "/get/abc/123abf/{param}" [ ("param", "testss") ]);
        ("/get/abc/123abfff/te", m "/get/abc/123abfff/{param}" [ ("param", "te") ]);
      ] );
  ]

let match_test name cases =
  ( name,
    List.mapi
      (fun i (routes, matches) ->
        (Printf.sprintf "%s %d" name i, `Quick, run_match_tests routes matches))
      cases )

(* Remove / merge test helpers -------------------------------------------- *)

type remove_op =
  | Insert of string
  | Remove of string * string option

let run_remove_test ~routes ~ops ~remaining () =
  let router = Eta_router.Router.create () in
  List.iter
    (fun route ->
      match Eta_router.Router.insert router route route with
      | Ok () -> ()
      | Error _ -> fail (Printf.sprintf "insert %s failed" route))
    routes;
  List.iter
    (fun op ->
      match op with
      | Insert route ->
        (match Eta_router.Router.insert router route route with
        | Ok () -> ()
        | Error _ -> fail (Printf.sprintf "insert %s failed" route))
      | Remove (route, expected) ->
        let got = Eta_router.Router.remove router route in
        check (option string) route expected got)
    ops;
  List.iter
    (fun route ->
      match Eta_router.Router.at router route with
      | Ok _ -> ()
      | Error _ -> fail (Printf.sprintf "remaining %s not found" route))
    remaining

let remove_test name routes ops remaining =
  ( name,
    `Quick,
    run_remove_test ~routes ~ops ~remaining )

(* Ported from matchit tests/remove.rs ------------------------------------- *)

let remove_normalized_test =
  remove_test "normalized"
    [
      "/x/{foo}/bar";
      "/x/{bar}/baz";
      "/{foo}/{baz}/bax";
      "/{foo}/{bar}/baz";
      "/{fod}/{baz}/{bax}/foo";
      "/{fod}/baz/bax/foo";
      "/{foo}/baz/bax";
      "/{bar}/{bay}/bay";
      "/s";
      "/s/s";
      "/s/s/s";
      "/s/s/s/s";
      "/s/s/{s}/x";
      "/s/s/{y}/d";
    ]
    [
      Remove ("/x/{foo}/bar", Some "/x/{foo}/bar");
      Remove ("/x/{bar}/baz", Some "/x/{bar}/baz");
      Remove ("/{foo}/{baz}/bax", Some "/{foo}/{baz}/bax");
      Remove ("/{foo}/{bar}/baz", Some "/{foo}/{bar}/baz");
      Remove ("/{fod}/{baz}/{bax}/foo", Some "/{fod}/{baz}/{bax}/foo");
      Remove ("/{fod}/baz/bax/foo", Some "/{fod}/baz/bax/foo");
      Remove ("/{foo}/baz/bax", Some "/{foo}/baz/bax");
      Remove ("/{bar}/{bay}/bay", Some "/{bar}/{bay}/bay");
      Remove ("/s", Some "/s");
      Remove ("/s/s", Some "/s/s");
      Remove ("/s/s/s", Some "/s/s/s");
      Remove ("/s/s/s/s", Some "/s/s/s/s");
      Remove ("/s/s/{s}/x", Some "/s/s/{s}/x");
      Remove ("/s/s/{y}/d", Some "/s/s/{y}/d");
    ]
    []

let remove_basic_test =
  remove_test "basic"
    [ "/home"; "/home/{id}" ]
    [
      Remove ("/home", Some "/home");
      Remove ("/home", None);
      Remove ("/home/{id}", Some "/home/{id}");
      Remove ("/home/{id}", None);
    ]
    []

let remove_blog_test =
  remove_test "blog"
    [
      "/{page}";
      "/posts/{year}/{month}/{post}";
      "/posts/{year}/{month}/index";
      "/posts/{year}/top";
      "/static/{*path}";
      "/favicon.ico";
    ]
    [
      Remove ("/{page}", Some "/{page}");
      Remove ("/posts/{year}/{month}/{post}", Some "/posts/{year}/{month}/{post}");
      Remove ("/posts/{year}/{month}/index", Some "/posts/{year}/{month}/index");
      Remove ("/posts/{year}/top", Some "/posts/{year}/top");
      Remove ("/static/{*path}", Some "/static/{*path}");
      Remove ("/favicon.ico", Some "/favicon.ico");
    ]
    []

let remove_catchall_test =
  remove_test "catchall"
    [ "/foo/{*catchall}"; "/bar"; "/bar/"; "/bar/{*catchall}" ]
    [
      Remove ("/foo/{catchall}", None);
      Remove ("/foo/{*catchall}", Some "/foo/{*catchall}");
      Remove ("/bar/", Some "/bar/");
      Insert "/foo/*catchall";
      Remove ("/bar/{*catchall}", Some "/bar/{*catchall}");
    ]
    [ "/bar"; "/foo/*catchall" ]

let remove_overlapping_routes_test =
  remove_test "overlapping routes"
    [
      "/home";
      "/home/{id}";
      "/users";
      "/users/{id}";
      "/users/{id}/posts";
      "/users/{id}/posts/{post_id}";
      "/articles";
      "/articles/{category}";
      "/articles/{category}/{id}";
    ]
    [
      Remove ("/home", Some "/home");
      Insert "/home";
      Remove ("/home/{id}", Some "/home/{id}");
      Insert "/home/{id}";
      Remove ("/users", Some "/users");
      Insert "/users";
      Remove ("/users/{id}", Some "/users/{id}");
      Insert "/users/{id}";
      Remove ("/users/{id}/posts", Some "/users/{id}/posts");
      Insert "/users/{id}/posts";
      Remove ("/users/{id}/posts/{post_id}", Some "/users/{id}/posts/{post_id}");
      Insert "/users/{id}/posts/{post_id}";
      Remove ("/articles", Some "/articles");
      Insert "/articles";
      Remove ("/articles/{category}", Some "/articles/{category}");
      Insert "/articles/{category}";
      Remove ("/articles/{category}/{id}", Some "/articles/{category}/{id}");
      Insert "/articles/{category}/{id}";
    ]
    [
      "/home";
      "/home/{id}";
      "/users";
      "/users/{id}";
      "/users/{id}/posts";
      "/users/{id}/posts/{post_id}";
      "/articles";
      "/articles/{category}";
      "/articles/{category}/{id}";
    ]

let remove_trailing_slash_test =
  remove_test "trailing slash"
    [ "/{home}/"; "/foo" ]
    [
      Remove ("/", None);
      Remove ("/{home}", None);
      Remove ("/foo/", None);
      Remove ("/foo", Some "/foo");
      Remove ("/{home}", None);
      Remove ("/{home}/", Some "/{home}/");
    ]
    []

let remove_root_test =
  remove_test "remove root"
    [ "/" ]
    [ Remove ("/", Some "/") ]
    []

let remove_check_escaped_params_test =
  remove_test "check escaped params"
    [
      "/foo/{id}";
      "/foo/{id}/bar";
      "/bar/{user}/{id}";
      "/bar/{user}/{id}/baz";
      "/baz/{product}/{user}/{id}";
    ]
    [
      Remove ("/foo/{a}", None);
      Remove ("/foo/{a}/bar", None);
      Remove ("/bar/{a}/{b}", None);
      Remove ("/bar/{a}/{b}/baz", None);
      Remove ("/baz/{a}/{b}/{c}", None);
    ]
    [
      "/foo/{id}";
      "/foo/{id}/bar";
      "/bar/{user}/{id}";
      "/bar/{user}/{id}/baz";
      "/baz/{product}/{user}/{id}";
    ]

let remove_wildcard_suffix_test =
  remove_test "wildcard suffix"
    [
      "/foo/{id}";
      "/foo/{id}/bar";
      "/foo/{id}bar";
      "/foo/{id}bar/baz";
      "/foo/{id}bar/baz/bax";
      "/bar/x{id}y";
      "/bar/x{id}y/";
      "/baz/x{id}y";
      "/baz/x{id}y/";
    ]
    [
      Remove ("/foo/{id}", Some "/foo/{id}");
      Remove ("/foo/{id}bar", Some "/foo/{id}bar");
      Remove ("/foo/{id}bar/baz", Some "/foo/{id}bar/baz");
      Insert "/foo/{id}bax";
      Insert "/foo/{id}bax/baz";
      Remove ("/foo/{id}bax/baz", Some "/foo/{id}bax/baz");
      Remove ("/bar/x{id}y", Some "/bar/x{id}y");
      Remove ("/baz/x{id}y/", Some "/baz/x{id}y/");
    ]
    [
      "/foo/{id}/bar";
      "/foo/{id}bar/baz/bax";
      "/foo/{id}bax";
      "/bar/x{id}y/";
      "/baz/x{id}y";
    ]

(* Ported from matchit tests/merge.rs ------------------------------------- *)

let merge_ok_test () =
  let root = Eta_router.Router.create () in
  let child = Eta_router.Router.create () in
  check bool "insert /foo" true
    (match Eta_router.Router.insert root "/foo" "foo" with Ok () -> true | _ -> false);
  check bool "insert /bar/{id}" true
    (match Eta_router.Router.insert root "/bar/{id}" "bar" with Ok () -> true | _ -> false);
  check bool "child /baz" true
    (match Eta_router.Router.insert child "/baz" "baz" with Ok () -> true | _ -> false);
  check bool "child /xyz/{id}" true
    (match Eta_router.Router.insert child "/xyz/{id}" "xyz" with Ok () -> true | _ -> false);
  check bool "merge ok" true
    (match Eta_router.Router.merge ~into:root child with Ok () -> true | _ -> false);
  check (option string) "/foo" (Some "foo")
    (match Eta_router.Router.at root "/foo" with Ok m -> Some m.value | _ -> None);
  check (option string) "/bar/1" (Some "bar")
    (match Eta_router.Router.at root "/bar/1" with Ok m -> Some m.value | _ -> None);
  check (option string) "/baz" (Some "baz")
    (match Eta_router.Router.at root "/baz" with Ok m -> Some m.value | _ -> None);
  check (option string) "/xyz/2" (Some "xyz")
    (match Eta_router.Router.at root "/xyz/2" with Ok m -> Some m.value | _ -> None)

let merge_conflict_test () =
  let root = Eta_router.Router.create () in
  let child = Eta_router.Router.create () in
  check bool "insert /foo" true
    (match Eta_router.Router.insert root "/foo" "foo" with Ok () -> true | _ -> false);
  check bool "insert /bar" true
    (match Eta_router.Router.insert root "/bar" "bar" with Ok () -> true | _ -> false);
  check bool "child /foo" true
    (match Eta_router.Router.insert child "/foo" "changed" with Ok () -> true | _ -> false);
  check bool "child /bar" true
    (match Eta_router.Router.insert child "/bar" "changed" with Ok () -> true | _ -> false);
  check bool "child /baz" true
    (match Eta_router.Router.insert child "/baz" "baz" with Ok () -> true | _ -> false);
  check bool "merge conflict" true
    (match Eta_router.Router.merge ~into:root child with
    | Error (Eta_router.Error.Conflicts _) -> true
    | _ -> false);
  check (option string) "/foo unchanged" (Some "foo")
    (match Eta_router.Router.at root "/foo" with Ok m -> Some m.value | _ -> None);
  check (option string) "/bar unchanged" (Some "bar")
    (match Eta_router.Router.at root "/bar" with Ok m -> Some m.value | _ -> None);
  check (option string) "/baz merged" (Some "baz")
    (match Eta_router.Router.at root "/baz" with Ok m -> Some m.value | _ -> None)

let merge_nested_test () =
  let root = Eta_router.Router.create () in
  let child = Eta_router.Router.create () in
  check bool "insert /foo" true
    (match Eta_router.Router.insert root "/foo" "foo" with Ok () -> true | _ -> false);
  check bool "child /foo/bar" true
    (match Eta_router.Router.insert child "/foo/bar" "bar" with Ok () -> true | _ -> false);
  check bool "merge ok" true
    (match Eta_router.Router.merge ~into:root child with Ok () -> true | _ -> false);
  check (option string) "/foo" (Some "foo")
    (match Eta_router.Router.at root "/foo" with Ok m -> Some m.value | _ -> None);
  check (option string) "/foo/bar" (Some "bar")
    (match Eta_router.Router.at root "/foo/bar" with Ok m -> Some m.value | _ -> None)

let () =
  run "eta_router"
    [
      ("escape", escape_tests);
      ("route", route_tests);
      ("insert wildcard conflict", [ ("wildcard conflict", `Quick, run_insert_tests wildcard_conflict_tests) ]);
      ("insert prefix suffix conflict", [ ("prefix suffix conflict", `Quick, run_insert_tests prefix_suffix_conflict_tests) ]);
      ("insert missing leading slash suffix", [ ("missing leading slash suffix", `Quick, missing_leading_slash_suffix_tests) ]);
      ("insert missing leading slash conflict", [ ("missing leading slash conflict", `Quick, missing_leading_slash_conflict_tests) ]);
      ("insert child conflict", [ ("child conflict", `Quick, run_insert_tests child_conflict_tests) ]);
      ("insert duplicates", [ ("duplicates", `Quick, run_insert_tests duplicates_tests) ]);
      ("insert invalid catchall", [ ("invalid catchall", `Quick, run_insert_tests invalid_catchall_tests) ]);
      ("insert catchall root conflict", [ ("catchall root conflict", `Quick, run_insert_tests catchall_root_conflict_tests) ]);
      ("insert normalized conflict", [ ("normalized conflict", `Quick, run_insert_tests normalized_conflict_tests) ]);
      ("insert more conflicts", [ ("more conflicts", `Quick, run_insert_tests more_conflicts_tests) ]);
      ("insert catchall static overlap", [ ("catchall static overlap", `Quick, catchall_static_overlap_tests) ]);
      ("insert duplicate conflict", [ ("duplicate conflict", `Quick, run_insert_tests duplicate_conflict_tests) ]);
      ("insert invalid param", [ ("invalid param", `Quick, run_insert_tests invalid_param_tests) ]);
      ("insert unnamed param", [ ("unnamed param", `Quick, run_insert_tests unnamed_param_tests) ]);
      ("insert double params", [ ("double params", `Quick, run_insert_tests double_params_tests) ]);
      ("insert escaped param", [ ("escaped param", `Quick, run_insert_tests escaped_param_tests) ]);
      ("insert bare catchall", [ ("bare catchall", `Quick, run_insert_tests bare_catchall_tests) ]);
      match_test "match partial overlap" partial_overlap_tests;
      match_test "match wildcard overlap" wildcard_overlap_tests;
      match_test "match overlapping param backtracking" overlapping_param_backtracking_tests;
      match_test "match empty route" empty_route_tests;
      match_test "match bare catchall" match_bare_catchall_tests;
      match_test "match param suffix flag issue" param_suffix_flag_issue_tests;
      match_test "match normalized" normalized_tests;
      match_test "match blog" blog_tests;
      match_test "match double overlap" double_overlap_tests;
      match_test "match catchall off by one" catchall_off_by_one_tests;
      match_test "match overlap" overlap_tests;
      match_test "match missing trailing slash param" missing_trailing_slash_param_tests;
      match_test "match extra trailing slash param" extra_trailing_slash_param_tests;
      match_test "match missing trailing slash catch all" missing_trailing_slash_catch_all_tests;
      match_test "match extra trailing slash catch all" extra_trailing_slash_catch_all_tests;
      match_test "match double overlap trailing slash" double_overlap_trailing_slash_tests;
      match_test "match trailing slash overlap" trailing_slash_overlap_tests;
      match_test "match trailing slash" trailing_slash_tests;
      match_test "match backtracking trailing slash" backtracking_trailing_slash_tests;
      match_test "match root trailing slash" root_trailing_slash_tests;
      match_test "match catchall overlap" catchall_overlap_tests;
      match_test "match escaped" escaped_tests;
      match_test "match empty param" empty_param_tests;
      match_test "match wildcard suffix" wildcard_suffix_tests;
      match_test "match mixed wildcard suffix" mixed_wildcard_suffix_tests;
      match_test "match basic" basic_tests;
      match_test "match wildcard" wildcard_tests;
      ("remove", [
        remove_normalized_test;
        remove_basic_test;
        remove_blog_test;
        remove_catchall_test;
        remove_overlapping_routes_test;
        remove_trailing_slash_test;
        remove_root_test;
        remove_check_escaped_params_test;
        remove_wildcard_suffix_test;
      ]);
      ("merge", [
        ("merge ok", `Quick, merge_ok_test);
        ("merge conflict", `Quick, merge_conflict_test);
        ("merge nested", `Quick, merge_nested_test);
      ]);
    ]
