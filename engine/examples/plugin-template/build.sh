#!/usr/bin/env bash
# 把插件编译为符合 `guo:source` 契约的 WASM 组件。
#
# 为什么不经 wasm32-wasip2 直接编译：`wit-bindgen` 的 wasip2 产物会拖入
# `wasi:cli` / `wasi:io` / `wasi:clocks` 一整串导入，宿主的能力白名单会直接拒绝。
# 用 `wasm32-unknown-unknown` 编译再 `wasm-tools component new` 组件化，
# 导入集合只剩 `guo:source/types`（已由 tests/component_host.rs 断言）。
set -euo pipefail
cd "$(dirname "$0")"

TARGET=wasm32-unknown-unknown
cargo build --target "$TARGET" --release

RAW="target/$TARGET/release/guo_plugin_template.wasm"
OUT="guo_plugin_template.component.wasm"

if ! command -v wasm-tools >/dev/null 2>&1; then
  echo "需要 wasm-tools：cargo install wasm-tools --locked" >&2
  exit 1
fi

wasm-tools component new "$RAW" -o "$OUT"
echo "组件产物：$OUT ($(wc -c < "$OUT") 字节)"
echo "导入集合："
wasm-tools component wit "$OUT" | sed -n '1,40p'
