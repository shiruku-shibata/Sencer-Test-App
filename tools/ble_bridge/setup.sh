#!/bin/sh
# BLE ブリッジ用の Python 仮想環境（tools/ble_bridge/.venv）を作り、bleak を入れる。
# macOS / Linux 用。Windows は setup.bat を使う。
#
#   sh tools/ble_bridge/setup.sh
#   PYTHON=/path/to/python3 sh tools/ble_bridge/setup.sh   # 使う Python を指定する場合
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PYTHON=${PYTHON:-python3}
VENV="$HERE/.venv"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
	echo "エラー: $PYTHON が見つかりません。Python 3.9 以上をインストールしてください。" >&2
	echo "  macOS: xcode-select --install（標準の python3）または https://www.python.org/" >&2
	echo "  Linux: sudo apt install python3 python3-venv など" >&2
	exit 1
fi

if ! "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
	echo "エラー: Python 3.9 以上が必要です（$("$PYTHON" --version 2>&1)）" >&2
	exit 1
fi

echo "仮想環境を作成します: $VENV"
"$PYTHON" -m venv "$VENV"
# Godot エディタが .venv の中（数千ファイル）を読み込まないようにする
: > "$VENV/.gdignore"

"$VENV/bin/python" -m pip install --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/python" -m pip install -r "$HERE/requirements.txt"

echo ""
echo "完了しました。アプリはこの仮想環境の python を自動で使います。"
echo "動作確認（M5 デバイスの電源を入れて近くに置く）:"
echo "  \"$VENV/bin/python\" \"$HERE/ble_bridge.py\" --scan-once"
