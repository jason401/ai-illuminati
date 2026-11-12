#!/bin/zsh
# Builds each app module (app/modules/<Name>/*.swift) on its own into OUT as <Name>.swiftmodule + lib<Name>.a.
# Programs that use a module `import <Name>` and compile with: -I OUT OUT/lib*.a
# A module sees only itself and the modules named in its `dependencies` file (one per line, built first);
# its users see only its `public` declarations.
# Use: zsh tools/build_modules.sh OUT [swiftc options, e.g. -O -target ... -module-cache-path ...]
set -eu
cd "${0:A:h}/.."
OUT=$1; shift
OPTIONS=("$@")
mkdir -p "$OUT"
typeset -A STATE
build() {
  local NAME=$1 DIR=app/modules/$1 DEP SEE=$OUT/.see/$1
  local -a DEPS
  [[ ${STATE[$NAME]-} == built ]] && return
  [[ ${STATE[$NAME]-} == building ]] && { echo "build_modules: modules depend on each other ($NAME)" >&2; exit 1 }
  [[ -d $DIR ]] || { echo "build_modules: no module $NAME" >&2; exit 1 }
  STATE[$NAME]=building
  [[ -f $DIR/dependencies ]] && DEPS=(${(f)"$(<$DIR/dependencies)"})
  # Only the named modules are where the compiler looks, so an import of any other one fails here.
  rm -rf "$SEE"; mkdir -p "$SEE"
  for DEP in $DEPS; do build $DEP; ln -s "$OUT/$DEP.swiftmodule" "$SEE/$DEP.swiftmodule"; done
  xcrun swiftc -swift-version 5 -parse-as-library -module-name "$NAME" -emit-module -emit-module-path "$OUT/$NAME.swiftmodule" \
    -emit-library -static -o "$OUT/lib$NAME.a" -I "$SEE" "${OPTIONS[@]}" "$DIR"/*.swift
  STATE[$NAME]=built
}
for DIR in app/modules/*(/N); do build ${DIR:t}; done
