#!/usr/bin/env bash
# 把猫果插件编译为符合 `guo:source` v2 契约的 WASM 组件。
#
# 与模板相同：用 wasm32-unknown-unknown 编译再组件化，避免拖入 wasi:* 导入
# （宿主的能力白名单会直接拒绝）。
set -euo pipefail
cd "$(dirname "$0")"

TARGET=wasm32-unknown-unknown
cargo build --target "$TARGET" --release

RAW="target/$TARGET/release/guo_plugin_maoguo.wasm"
OUT="guo_plugin_maoguo.component.wasm"

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "需要 wasm-tools：cargo install wasm-tools --locked" >&2
  exit 1
fi

wasm-tools component new "$RAW" -o "$OUT"
echo "组件产物：$OUT ($(wc -c < "$OUT") 字节)"
