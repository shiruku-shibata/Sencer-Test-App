#!/bin/sh
# ============================================================
# ブラウザ版（お試し用）を作る
#
#   sh tools/package_web.sh
#
# できるもの: build/web-page/
#   index.html     起動ページ（tools/dist/web_page.html から生成。<html>/<head> を持たない本文だけの形式）
#   index.js       Godot のエンジン起動スクリプト
#   pck.wasm       アプリ本体（index.pck。配信できる形式に合わせて名前だけ変えている）
#   engine.gz.wasm エンジン本体（index.wasm, 約 40 MB を gzip で約 10 MB に。ページ内で展開して読み込む）
#
# ブラウザ版では USB・Bluetooth は使えない（デモデバイスのみ）。
# 普通の Web サーバーに置く場合は、<html><head><meta charset="utf-8"></head><body> で包んでください。
#
# 必要なもの: Godot 4.4 以降と、同じバージョンの Web 用エクスポートテンプレート
# ============================================================
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
EXPORT="$ROOT/build/web"
OUT="$ROOT/build/web-page"

echo "== 1/3 書き出し（Godot: $("$GODOT" --version)）"
rm -rf "$EXPORT" "$OUT"
mkdir -p "$EXPORT" "$OUT"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" --export-release "Web" "$EXPORT/index.html" >/dev/null
[ -s "$EXPORT/index.wasm" ] || { echo "書き出しに失敗しました（Web 用テンプレートを確認）" >&2; exit 1; }

echo "== 2/3 圧縮"
cp "$EXPORT/index.js" "$OUT/"
cp "$EXPORT/index.pck" "$OUT/pck.wasm"
gzip -9 -c "$EXPORT/index.wasm" > "$OUT/engine.gz.wasm"

echo "== 3/3 起動ページ"
PCK_SIZE=$(wc -c < "$EXPORT/index.pck" | tr -d ' ')
WASM_SIZE=$(wc -c < "$EXPORT/index.wasm" | tr -d ' ')
sed -e "s/__PCK_SIZE__/$PCK_SIZE/" -e "s/__WASM_SIZE__/$WASM_SIZE/" \
	"$ROOT/tools/dist/web_page.html" > "$OUT/index.html"

ls -l "$OUT"
echo "完成: $OUT"
