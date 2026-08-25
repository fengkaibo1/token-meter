#!/bin/bash
# 编译 TokenMeter 菜单栏应用
set -euo pipefail
cd "$(dirname "$0")"

echo ">>> 编译 Swift ..."
swiftc -O -swift-version 5 -o token-meter Sources/TokenMeter.swift

# 没有配置文件就复制一份模板
if [ ! -f config.json ]; then
  cp config.example.json config.json
  echo ">>> 已生成 config.json（请填入 API Key）"
fi

echo ">>> 完成：$(pwd)/token-meter"
