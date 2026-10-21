# 生成コードの等価性チェック

しきい値プロファイルから生成するゲーム用の判定コード（`ThresholdProfile.to_code_snippet()`）が、
アプリ内の判定器 `ThresholdDetector` と**同じ入力に対して同じタイミングで判定するか**を、実際にコンパイルして確かめます。

| 言語 | 確認方法 |
|---|---|
| GDScript | 通常の自動テスト（`tests/test_threshold_profile.gd`）の中でコンパイルして比較 |
| C++（M5Unified） | このフォルダの `run.sh`。スタブの `M5Unified.h` でコンパイルして比較 |
| C# | このフォルダの `run.sh`。`dotnet`（または `mcs` + `mono`）があれば比較、無ければ SKIP |

C++ / C# は外部のコンパイラが必要なため、`tests/run_tests.gd` には含めていません。

## 実行方法

```bash
tests/snippets/run.sh
```

出力の例:

```
== 生成コードの等価性チェック ==
-- 1. シナリオを生成（Godot: /Applications/Godot.app/Contents/MacOS/Godot）
  生成: pos_gz                 サンプル   996 / 判定  14 回
  ...
-- 2. C++
   OK   C++ pos_gz（14 回判定・全サンプル一致）
  ...
-- 3. C#
   SKIP: dotnet も mcs/mono も見つかりません

== 結果 ==
   C++: OK（14 シナリオすべて一致）
   C#: SKIP（コンパイラなし）
== 不一致なし ==
```

- 終了コード `0` は、不一致もコンパイルエラーも無いことを表します。コンパイラが無い言語は **SKIP** と表示し、失敗にはしません。
- 終了コード `1` は、どれかのシナリオで判定が食い違ったか、生成コードがコンパイルできなかったことを表します。
- 環境変数で動作を変えられます。
  - `GODOT=...`: Godot の実行ファイルを指定します（未指定なら `godot` → `godot4` → `/Applications/Godot.app` の順に探します）。
  - `CXX=g++`: C++ コンパイラを指定します。
  - `KEEP=1`: 作業フォルダ（生成コード・入力・期待値・実際の出力）を消さずに残します。不一致の調査に使います。
- macOS で既定の SDK ではリンクできない環境では、インストール済みの別の SDK を自動で探して使います。
- Linux / macOS 用のスクリプトです（bash）。

## 仕組み

1. `gen_cases.gd`（Godot）がシナリオごとに次のファイルを書き出します。
   - C++ / C# の生成コード
   - 入力列（1行 = `ax ay az gx gy gz timestamp_ms`）
   - その入力を `ThresholdDetector` に流した判定（1行 = `0` / `1`）

   入力値は、書き出した 10 進文字列を float32 に丸めてから判定器に渡します。C++ / C# が同じ文字列を `float` で読むので、両者は同じ値を見ています。
2. C++ は、`driver.cpp` に生成コードを `#include` して `-std=c++11 -Wall -Wextra -Werror` でコンパイルします。
   - `feed(a, g, t)`（値を直接渡す）の判定を期待値と 1 サンプルずつ比べます。
   - 同時に、`update(t)`（`M5.Imu.getAccelData / getGyroData` から読む）が `feed()` と同じ判定になることも確かめます。
     サンプルの間にも `update()` を 1ms ごとに余分に呼び、`SAMPLE_INTERVAL_MS`（測定時のサンプル間隔）ごとにしか読まない
     ＝ `loop()` の回る速さで判定や平滑化が変わらないことも確かめます。
3. C# は、各シナリオのクラス名を `MotionDetector_<シナリオ名>` に変えて、`Runner.cs.in` と一緒に 1 つのプログラムにして比べます。
   `Update()` についても C++ と同じ確認をします。
4. GDScript の `update()` は `tests/test_threshold_profile.gd` で、ループ 1 / 3 / 10ms ごとに呼んでも判定回数が変わらないことを確かめます。

## シナリオ

| 名前 | 内容 |
|---|---|
| `pos_gz` | ＋方向・ヒステリシスあり・揺り戻しあり |
| `neg_ax_smooth3` | −方向・平滑化 3 |
| `abs_gx` | 絶対値・左右交互 |
| `any_gz_amag` | 2 軸 ANY（ジャイロ＋方向・合成加速度の絶対値）・平滑化 3・不応期が違う 2 ルール（最大値を使う） |
| `all_ax_gz` | 2 軸 ALL（片方の軸だけの動作は判定しない）・平滑化 2 |
| `chatter_no_hys` | ヒステリシス 0・不応期 0（チャタリングする波形で回数まで一致するか） |
| `refractory_600` | 長い不応期（連打の一部だけ判定） |
| `neg_az_gravity_gmag` | 重力のかかる軸の −方向（正のしきい値）＋ 合成角速度・無効なルール入り・平滑化 5 |
| `same_axis_both_ways` | 同じ軸の ＋方向・−方向 を ANY・平滑化 10 |
| `hys_only_pos` / `hys_only_neg` / `hys_only_abs` | 不応期 0 で、ヒステリシスだけが効く波形（解除条件の違いを検出する） |
| `refractory_boundary` | ノイズ無し・不応期ちょうどの間隔（「経過 = 不応期」で判定できるかの境界） |
| `rate_50hz_smooth5` | 50Hz で測ったプロファイル（入力 20ms 間隔・平滑化 5）。`update()` は 20ms ごとにだけ読む |

シナリオを足すときは、`gen_cases.gd` の `_cases()` に追加します。

**シナリオの有効性の確認**: 生成コードの解除条件の符号や、不応期の比較（`<` → `<=`）をわざと変えると、このチェックが失敗することを確認済みです。
