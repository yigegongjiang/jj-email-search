#!/bin/bash
set -euo pipefail
cd "${SRCROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
archs="${ARCHS:-$(uname -m)}"
libs=()
for arch in $archs; do
  case "$arch" in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
  esac
  if ! rustup target list --installed | rg -qx "$target"; then
    rustup target add "$target"
  fi
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release --manifest-path Engine/Cargo.toml --target "$target" --lib
  libs+=("Engine/target/$target/release/libjj_email_engine.a")
done
mkdir -p Engine/target/universal
if [ "${#libs[@]}" = 1 ]; then
  cp "${libs[0]}" Engine/target/universal/libjj_email_engine.a
else
  lipo -create "${libs[@]}" -output Engine/target/universal/libjj_email_engine.a
fi
