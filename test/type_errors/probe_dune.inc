(rule
 (alias probe2)
 (action
  (system "echo PWD=$(pwd); echo ROOT=%{root}; echo PROOT=%{project_root}; echo SRC=%{workspace_root}; env | grep -i dune | head -20")))
