@echo off
rem BLE ブリッジ用の Python 仮想環境（tools\ble_bridge\.venv）を作り、bleak と pyserial を入れる。Windows 用。
rem   tools\ble_bridge\setup.bat
rem   使う Python を指定する場合: set PYTHON=C:\Path\To\python.exe を実行してから setup.bat
chcp 65001 >nul
setlocal
set "HERE=%~dp0"
set "VENV=%HERE%.venv"

if not defined PYTHON (
  where py >nul 2>nul
  if not errorlevel 1 (
    set "PYTHON=py -3"
  ) else (
    set "PYTHON=python"
  )
)

%PYTHON% -c "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)"
if errorlevel 1 (
  echo ERROR: Python 3.9+ was not found. Install it from https://www.python.org/
  echo        and check "Add python.exe to PATH" in the installer.
  exit /b 1
)

echo 仮想環境を作成します: %VENV%
%PYTHON% -m venv "%VENV%"
if errorlevel 1 exit /b 1
rem Godot エディタが .venv の中を読み込まないようにする
type nul > "%VENV%\.gdignore"

"%VENV%\Scripts\python.exe" -m pip install --upgrade pip >nul 2>nul
"%VENV%\Scripts\python.exe" -m pip install -r "%HERE%requirements.txt"
if errorlevel 1 exit /b 1

echo.
echo 完了しました。アプリはこの仮想環境の python を自動で使います。
echo 動作確認（M5 デバイスの電源を入れて近くに置く）:
echo   "%VENV%\Scripts\python.exe" "%HERE%ble_bridge.py" --scan-once
endlocal
