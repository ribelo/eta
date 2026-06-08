let check name expected actual =
  if actual <> expected then
    failwith (Printf.sprintf "%s: expected different result" name)

let () =
  check "scoped_factory"
    ("scoped:select 1", false)
    (Provide_survival.Without_provide_scoped_factory.run ());
  check "mock_injection"
    ("fake:user:42", [ "outer-real"; "before"; "read:fake:user:42"; "outer-real-again" ])
    (Provide_survival.Without_provide_mock_injection.run ());
  check "sandbox"
    ("parent-secret", "sandbox:public")
    (Provide_survival.Without_provide_sandbox.run ());
  Printf.printf "post-provide survival smoke tests passed\n%!"
