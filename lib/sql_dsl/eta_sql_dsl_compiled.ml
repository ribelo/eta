module Make
    (Backend : sig
      type value
      type row
    end)
    (Param : sig
      type t

      val value : t -> Backend.value
    end) =
struct
  type param = Param.t

  type 'a select = {
    sql : string;
    params : param list;
    width : int;
    decode : Backend.row -> 'a;
  }

  type 'a returning = {
    sql : string;
    params : param list;
    decode : Backend.row -> 'a;
  }

  type change = {
    sql : string;
    params : param list;
  }

  type schema = { sql : string } [@@unboxed]

  let value_of_param = Param.value
  let values_of_params params = List.map value_of_param params

  let select_sql (query : _ select) = query.sql
  let select_width (query : _ select) = query.width
  let select_params (query : _ select) = values_of_params query.params
  let select_decode (query : _ select) = query.decode
  let returning_sql (query : _ returning) = query.sql
  let returning_params (query : _ returning) = values_of_params query.params
  let returning_decode (query : _ returning) = query.decode
  let change_sql (query : change) = query.sql
  let change_params (query : change) = values_of_params query.params
  let schema_sql (schema : schema) = schema.sql
end
