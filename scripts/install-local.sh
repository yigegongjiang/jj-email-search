#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
built_app="$project_dir/build/Build/Products/Release/jj-email-search.app"
installed_app="/Applications/jj-email-search.app"
executable="$installed_app/Contents/MacOS/jj-email-search"

cd "$project_dir"
xcodebuild -project jj-email-search.xcodeproj -scheme jj-email-search \
  -configuration Release -derivedDataPath build -destination 'platform=macOS' \
  ${1:+CODE_SIGN_STYLE=Automatic} ${1:+"CODE_SIGN_IDENTITY=Apple Development"} ${1:+"DEVELOPMENT_TEAM=$1"} \
  build

test -x "$built_app/Contents/MacOS/jj-email-search"
codesign --verify --strict "$built_app"

instance_pids() {
  ps -axo pid=,comm= | awk -v exe="$executable" '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == exe) print pid }'
}

quit_app() {
  local pids
  pids="$(instance_pids)"
  [ -z "$pids" ] && return 0
  kill $pids
  for _ in $(seq 50); do
    [ -z "$(instance_pids)" ] && return 0
    sleep 0.1
  done
  echo "jj-email-search did not quit: $executable" >&2
  return 1
}

quit_app
rm -rf -- "$installed_app"
ditto "$built_app" "$installed_app"
codesign --verify --strict "$installed_app"
trap quit_app EXIT
open -n -g --env "APP_BACKGROUND=1" "$installed_app"
for _ in $(seq 50); do
  pid="$(instance_pids)"
  if [ -n "$pid" ]; then
    trap - EXIT
    printf '已安装并打开: %s pid=%s\n' "$installed_app" "$pid"
    exit 0
  fi
  sleep 0.1
done
echo "jj-email-search did not start: $executable" >&2
exit 1
