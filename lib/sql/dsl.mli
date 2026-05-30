include
  Eta_sql_dsl.S
    with type value := Value.t
     and type row := Sqlite.stmt
     and type error := Types.error
     and type 'a typ = 'a Types.typ
