#!/usr/bin/env bash
# 生成コード（ThresholdProfile.to_code_snippet）の等価性チェック。
#
#   1. Godot でシナリオごとに「C++ / C# の生成コード・入力列・ThresholdDetector の判定結果」を書き出す
#   2. C++: スタブの M5Unified.h でコンパイル（-Wall -Wextra -Werror）して同じ入力を流し、判定を1サンプルずつ比較
#   3. C#: dotnet（または mcs + mono）があれば同様に比較
#
# 使い方（リポジトリのどこからでも）:
#   tests/snippets/run.sh
# 環境変数:
#   GODOT  Godot 実行ファイル（未指定なら godot / godot4 / macOS の /Applications/Godot.app を探す）
#   CXX    C++ コンパイラ（未指定なら clang++ → g++）
#   KEEP=1 作業フォルダを消さずに残す（失敗の調査用）
#
# 終了コード: 0 = 不一致なし（コンパイラが無い言語は SKIP と表示して 0）/ 1 = 不一致・コンパイルエラーあり

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

failures=0
summary=()

note() { printf '%s\n' "$*"; }
add_summary() { summary+=("$1"); }

# ------------------------------------------------------------ Godot
find_godot() {
  if [ -n "${GODOT:-}" ]; then echo "$GODOT"; return; fi
  for cmd in godot godot4; do
    if command -v "$cmd" >/dev/null 2>&1; then command -v "$cmd"; return; fi
  done
  if [ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]; then
    echo "/Applications/Godot.app/Contents/MacOS/Godot"; return
  fi
  echo ""
}

GODOT_BIN="$(find_godot)"
if [ -z "$GODOT_BIN" ]; then
  note "ERROR: Godot が見つかりません。環境変数 GODOT に実行ファイルのパスを指定してください。"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/snippet-check.XXXXXX")"
cleanup() {
  if [ "${KEEP:-0}" = "1" ]; then note "作業フォルダ: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT
CASES="$WORK/cases"

note "== 生成コードの等価性チェック =="
note "-- 1. シナリオを生成（Godot: ${GODOT_BIN}）"
if ! "$GODOT_BIN" --headless --path "$ROOT" -s res://tests/snippets/gen_cases.gd -- --out="$CASES" 2>&1 \
    | grep -v '^Godot Engine' | grep -v '^$'; then
  :
fi
if [ ! -s "$CASES/cases.txt" ]; then
  note "ERROR: シナリオを生成できませんでした（上の出力を確認してください）"
  exit 1
fi
CASE_NAMES=()
while IFS= read -r line; do
  [ -n "$line" ] && CASE_NAMES+=("$line")
done < "$CASES/cases.txt"

# 期待値と実際の判定を比べる。一致なら 0。
compare() {
  local name="$1" lang="$2" actual="$3"
  local expected="$CASES/$name.expected.txt"
  local fires
  fires="$(grep -c '^1$' "$expected")"
  if cmp -s "$expected" "$actual"; then
    note "   OK   ${lang} ${name}（${fires} 回判定・全サンプル一致）"
    return 0
  fi
  note "   FAIL $lang $name: ThresholdDetector と判定が食い違いました（行番号: 期待 / 実際）"
  diff "$expected" "$actual" | head -n 10 | sed 's/^/        /'
  return 1
}

# ------------------------------------------------------------ C++
note "-- 2. C++"
CXX_BIN="${CXX:-}"
if [ -z "$CXX_BIN" ]; then
  for cmd in clang++ g++; do
    if command -v "$cmd" >/dev/null 2>&1; then CXX_BIN="$(command -v "$cmd")"; break; fi
  done
fi

CXX_EXTRA=()
cxx_ready=0
if [ -z "$CXX_BIN" ]; then
  note "   SKIP: C++ コンパイラ（clang++ / g++）が見つかりません"
  add_summary "C++: SKIP（コンパイラなし）"
else
  # まず hello world がビルドできるか（macOS で既定の SDK が壊れている場合は別の SDK を試す）
  printf '#include <cstdio>\nint main(){std::printf("ok");return 0;}\n' > "$WORK/hello.cpp"
  if "$CXX_BIN" -std=c++11 -o "$WORK/hello" "$WORK/hello.cpp" >/dev/null 2>&1; then
    cxx_ready=1
  elif [ "$(uname)" = "Darwin" ]; then
    for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.sdk; do
      [ -d "$sdk" ] || continue
      if "$CXX_BIN" -std=c++11 -isysroot "$sdk" -o "$WORK/hello" "$WORK/hello.cpp" >/dev/null 2>&1; then
        CXX_EXTRA=(-isysroot "$sdk")
        cxx_ready=1
        note "   （既定の SDK でリンクできないため $sdk を使います）"
        break
      fi
    done
  fi
  if [ "$cxx_ready" = "0" ]; then
    note "   SKIP: $CXX_BIN で簡単なプログラムもビルドできません（コンパイラ環境の問題）"
    add_summary "C++: SKIP（コンパイラ環境の問題）"
  fi
fi

if [ "$cxx_ready" = "1" ]; then
  note "   コンパイラ: $CXX_BIN"
  cpp_fail=0
  for name in "${CASE_NAMES[@]}"; do
    bin="$WORK/cpp_$name"
    if ! "$CXX_BIN" -std=c++11 -Wall -Wextra -Werror "${CXX_EXTRA[@]}" \
        -I "$SCRIPT_DIR/stub" -I "$CASES" "-DSNIPPET=\"$name.h\"" \
        -o "$bin" "$SCRIPT_DIR/driver.cpp" > "$WORK/cpp_$name.log" 2>&1; then
      note "   FAIL C++ $name: コンパイルエラー"
      sed 's/^/        /' "$WORK/cpp_$name.log" | head -n 20
      cpp_fail=$((cpp_fail + 1))
      continue
    fi
    if ! "$bin" "$CASES/$name.input.txt" > "$WORK/cpp_$name.actual.txt"; then
      note "   FAIL C++ $name: 実行エラー（feed() と update() の食い違いなど）"
      cpp_fail=$((cpp_fail + 1))
      continue
    fi
    compare "$name" "C++" "$WORK/cpp_$name.actual.txt" || cpp_fail=$((cpp_fail + 1))
  done
  if [ "$cpp_fail" = "0" ]; then
    add_summary "C++: OK（${#CASE_NAMES[@]} シナリオすべて一致）"
  else
    add_summary "C++: FAIL（${cpp_fail} シナリオ）"
    failures=$((failures + cpp_fail))
  fi
fi

# ------------------------------------------------------------ C#
note "-- 3. C#"
CS_DIR="$WORK/cs"
mkdir -p "$CS_DIR"
: > "$WORK/cs_cases.txt"
for name in "${CASE_NAMES[@]}"; do
  # 各シナリオのクラス名をずらして 1 つのプログラムにまとめる
  sed "s/public class MotionDetector\$/public class MotionDetector_$name/" "$CASES/$name.cs" > "$CS_DIR/$name.cs"
  if ! grep -q "public class MotionDetector_$name\$" "$CS_DIR/$name.cs"; then
    note "   FAIL C# $name: 生成コードに 'public class MotionDetector' の行が見つかりません"
    failures=$((failures + 1))
  fi
  printf '            case "%s": { var d = new MotionDetector_%s(); feed = d.Feed; var u = new MotionDetector_%s(); update = u.Update; interval = MotionDetector_%s.SampleIntervalMs; break; }\n' \
    "$name" "$name" "$name" "$name" >> "$WORK/cs_cases.txt"
done
awk -v f="$WORK/cs_cases.txt" '$0 == "// @CASES@" { while ((getline l < f) > 0) print l; next } { print }' \
  "$SCRIPT_DIR/Runner.cs.in" > "$CS_DIR/Runner.cs"

cs_runner=()
if command -v dotnet >/dev/null 2>&1; then
  note "   コンパイラ: dotnet"
  cat > "$CS_DIR/SnippetCheck.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <Nullable>disable</Nullable>
    <ImplicitUsings>disable</ImplicitUsings>
    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
    <RollForward>Major</RollForward>
  </PropertyGroup>
</Project>
EOF
  if dotnet build "$CS_DIR/SnippetCheck.csproj" -c Release -o "$CS_DIR/out" > "$WORK/cs_build.log" 2>&1; then
    cs_runner=(dotnet "$CS_DIR/out/SnippetCheck.dll")
  else
    note "   FAIL C#: コンパイルエラー"
    grep -E 'error|エラー' "$WORK/cs_build.log" | head -n 20 | sed 's/^/        /'
    add_summary "C#: FAIL（コンパイルエラー）"
    failures=$((failures + 1))
  fi
elif command -v mcs >/dev/null 2>&1 && command -v mono >/dev/null 2>&1; then
  note "   コンパイラ: mcs + mono"
  if mcs -out:"$CS_DIR/SnippetCheck.exe" "$CS_DIR"/*.cs > "$WORK/cs_build.log" 2>&1; then
    cs_runner=(mono "$CS_DIR/SnippetCheck.exe")
  else
    note "   FAIL C#: コンパイルエラー"
    head -n 20 "$WORK/cs_build.log" | sed 's/^/        /'
    add_summary "C#: FAIL（コンパイルエラー）"
    failures=$((failures + 1))
  fi
else
  note "   SKIP: dotnet も mcs/mono も見つかりません"
  add_summary "C#: SKIP（コンパイラなし）"
fi

if [ "${#cs_runner[@]}" -gt 0 ]; then
  cs_fail=0
  for name in "${CASE_NAMES[@]}"; do
    if ! "${cs_runner[@]}" "$name" "$CASES/$name.input.txt" > "$WORK/cs_$name.actual.txt"; then
      note "   FAIL C# $name: 実行エラー"
      cs_fail=$((cs_fail + 1))
      continue
    fi
    compare "$name" "C#" "$WORK/cs_$name.actual.txt" || cs_fail=$((cs_fail + 1))
  done
  if [ "$cs_fail" = "0" ]; then
    add_summary "C#: OK（${#CASE_NAMES[@]} シナリオすべて一致）"
  else
    add_summary "C#: FAIL（${cs_fail} シナリオ）"
    failures=$((failures + cs_fail))
  fi
fi

# ------------------------------------------------------------ まとめ
note ""
note "== 結果 =="
for line in "${summary[@]}"; do note "   $line"; done
if [ "$failures" -gt 0 ]; then
  note "== 不一致・エラーがあります =="
  exit 1
fi
note "== 不一致なし =="
exit 0
