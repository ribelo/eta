# P-Gqa-6 Parameter Ergonomics

Captured log: p_gqa_6.log
Command: nix develop -c dune exec scratch/eta_research/graph_query_api/p_gqa_6.exe

| Type | Call shape | Mismatch caught | Verdict |
| --- | --- | --- | --- |
| string | Graph.Param.string "name" name | runtime if wrong constructor used | Clean |
| int64 | Graph.Param.int "id" id | runtime if wrong constructor used | Clean |
| double | Graph.Param.float "score" score | runtime if wrong constructor used | Clean |
| bool | Graph.Param.bool "active" active | runtime if wrong constructor used | Clean |
| null | Graph.Param.null "nickname" | runtime nullable policy | Awkward |
| list | Graph.Param.list "ids" Graph.Param.int ids | runtime element compatibility | Awkward |
| map | Graph.Param.map "filter" [field "country" string; field "active" bool] | runtime field mismatch | Awkward |
| bytes | Graph.Param.bytes "blob" bytes | blocked by LadybugDB C API | Untested |

Verdict: primitive params are clean. Null/list/map need helper APIs but are acceptable. Bytes remains Untested until the driver finds a blob bind path.
