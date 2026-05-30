module Q = Eta_sql

let _ : int Q.Compiled.select =
  {
    Q.Compiled.sql = "SELECT 1";
    params = [];
    decode = (fun _ -> 1);
  }
