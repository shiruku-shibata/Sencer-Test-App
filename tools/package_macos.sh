#!/bin/sh
# ============================================================
# 共有用の macOS 配布物（zip）を作る
#
#   sh tools/package_macos.sh [バージョン]
#
# できるもの: build/SensorTestApp-macOS-<バージョン>.zip
#   SensorTestApp-macOS/
#   ├── Sensor Test App.app      アプリ本体（デモデバイス・有線はこれだけで使える）
#   ├── ble_bridge/              BLE 用ブリッジ（使う人だけ setup.sh を一度実行）
#   └── はじめにお読みください.txt
#
# 必要なもの:
#   - Godot 4.4 以降（環境変数 GODOT で場所を指定。既定は /Applications/Godot.app）
#   - 同じバージョンのエクスポートテンプレート（エディタの「エクスポートテンプレートの管理」で導入）
#
# 署名はアドホック署名（Apple の公証なし）。受け取った人は初回だけ右クリック →「開く」が必要。
# ============================================================
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
VERSION=${1:-$(sed -n 's/^application\/short_version="\(.*\)"/\1/p' "$ROOT/export_presets.cfg")}
VERSION=${VERSION:-dev}
APP_NAME="Sensor Test App"
DIST_NAME="SensorTestApp-macOS"
BUILD="$ROOT/build"
STAGE="$BUILD/$DIST_NAME"
ZIP="$BUILD/$DIST_NAME-$VERSION.zip"

if [ ! -x "$GODOT" ]; then
	echo "Godot が見つかりません: $GODOT（環境変数 GODOT で指定してください）" >&2
	exit 1
fi

echo "== 1/5 書き出し（Godot: $("$GODOT" --version)）"
rm -rf "$STAGE" "$BUILD/macos_export.zip"
mkdir -p "$STAGE"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT" --export-release "macOS" "$BUILD/macos_export.zip"
if [ ! -s "$BUILD/macos_export.zip" ]; then
	echo "書き出しに失敗しました。エクスポートテンプレートが入っているか確認してください。" >&2
	exit 1
fi
ditto -x -k "$BUILD/macos_export.zip" "$STAGE"
rm -f "$BUILD/macos_export.zip"
APP="$STAGE/$APP_NAME.app"
if [ ! -d "$APP" ]; then
	APP=$(find "$STAGE" -maxdepth 1 -name "*.app" | head -n 1)
	[ -n "$APP" ] || { echo ".app が見つかりません" >&2; exit 1; }
	mv "$APP" "$STAGE/$APP_NAME.app"
	APP="$STAGE/$APP_NAME.app"
fi

echo "== 2/5 BLE ブリッジを同梱（.app の隣の ble_bridge/。.venv は含めない）"
mkdir -p "$STAGE/ble_bridge"
for f in ble_bridge.py requirements.txt setup.sh setup.bat README.md; do
	cp "$ROOT/tools/ble_bridge/$f" "$STAGE/ble_bridge/"
done
chmod +x "$STAGE/ble_bridge/setup.sh"

echo "== 3/5 説明書・ライセンス"
cp "$ROOT/THIRD_PARTY_LICENSES.md" "$STAGE/"
cp "$ROOT/tools/dist/README_macOS.txt" "$STAGE/はじめにお読みください.txt"

echo "== 4/5 アドホック署名と検証"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
/usr/libexec/PlistBuddy -c "Print :NSBluetoothAlwaysUsageDescription" "$APP/Contents/Info.plist" >/dev/null

echo "== 5/5 zip 作成"
rm -f "$ZIP"
(cd "$BUILD" && ditto -c -k --keepParent --sequesterRsrc "$DIST_NAME" "$ZIP")
echo "完成: $ZIP ($(du -h "$ZIP" | cut -f1))"
