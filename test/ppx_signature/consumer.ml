let () =
  let rendered = Format.asprintf "%a" Derived_error.pp_err (`Db 7) in
  if not (String.equal rendered "db:7") then
    failwith ("unexpected derived error rendering: " ^ rendered)
