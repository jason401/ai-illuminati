#!/bin/zsh
# Starts a new module the way the guards expect: zsh tools/new_module.sh <Name> [dependencies...]
# Makes app/modules/<Name>/ (dependencies, boundary, a first file), tools/tests/<name>_contract.swift, an empty
# docs/api/<Name>.txt and prints the docs/MODULES.md entry to fill in. It does not change tools/module_graph.txt or
# tools/module_guard.sha256: a new module changes the graph, which the user approves; it prints the lines to add.
set -eu
cd "${0:A:h}/.."
(( $# >= 1 )) || { echo "use: zsh tools/new_module.sh <Name> [dependencies...]" >&2; exit 2 }
NAME=$1; shift
[[ $NAME =~ '^AI[A-Z][A-Za-z]*$' ]] || { echo "new_module: the name is AI + a capitalized word (AIFoo)" >&2; exit 2 }
DIR=app/modules/$NAME; SHORT=${(L)NAME#AI}; CONTRACT=tools/tests/${SHORT}_contract.swift
[[ ! -e $DIR && ! -e $CONTRACT ]] || { echo "new_module: $DIR or $CONTRACT already exists" >&2; exit 1 }
for DEP in "$@"; do [[ -d app/modules/$DEP ]] || { echo "new_module: no module $DEP" >&2; exit 1 }; done
mkdir -p "$DIR" docs/api
print -l -- "$@" > "$DIR/dependencies"; [[ $# -gt 0 ]] || : > "$DIR/dependencies"
cat > "$DIR/boundary" <<B
# Boundary check (S2): one line per check, \`code<TAB>name\`. The code, compiled outside the module with only its
# public names, must fail with "'name' is inaccessible due to 'internal' protection level" and no other error.
# \`code<TAB>name<TAB>hidden\`: the name is an internal type, so the error must be "cannot find 'name' in scope".
# none: replace this line with at least one internal name of $NAME once it has one.
B
{ echo "import Foundation"; for DEP in "$@"; do echo "import $DEP"; done; echo
  echo "// $NAME: what it owns, in one line (docs/MODULES.md \"Module map\")." } > "$DIR/$NAME.swift"
{ echo "import Foundation"; echo "import $NAME"; echo
  echo "// The promises of the $NAME module, checked from outside it with only its public API (run_mode2.sh)."
  echo "// Optional markers: \`// contract needs: app resources\`, \`// contract needs: chat fixtures\`."
  echo 'func expect(_ condition: @autoclosure () -> Bool, _ message: String) {'
  echo '    if !condition() { fatalError("FAIL: " + message) }'
  echo '}'; echo "print(\"PASS: $NAME contract\")" } > "$CONTRACT"
: > docs/api/$NAME.txt
echo "Made $DIR (dependencies, boundary, $NAME.swift), $CONTRACT, docs/api/$NAME.txt."
echo
echo "Put this under \"## Module map\" in docs/MODULES.md and name \`$NAME\` in AGENTS.md \"Module rules\":"
echo "### $NAME (\`$DIR/\`)"
echo "What it owns, who uses it. | Promise | Users | Contract check | App-path test |"
echo
echo "Needs the user's approval (a graph change), then in the same commit:"
echo "  tools/module_graph.txt:  $NAME: $*"
echo "  users of $NAME: add $NAME to their line in tools/module_graph.txt and their dependencies file"
echo "  tools/module_guard.sha256:  zsh tools/check_modules.sh guard > tools/module_guard.sha256"
echo "  docs/api/$NAME.txt:  zsh tools/check_modules.sh snapshot (after its public names have their reasons)"
