# サードパーティ ライセンス一覧

本アプリが利用する外部ソフトウェアとそのライセンスをまとめます。
Git公開の可能性があるため、依存を追加した際は必ずこのファイルを更新してください。

| 用途 | ソフトウェア | ライセンス | 状態 |
|---|---|---|---|
| ゲームエンジン | Godot Engine 4.4系 | MIT | 使用中 |
| フォント（ブラウザ版のみ） | Noto Sans JP（Regular を日本語で使う文字に絞ったサブセット。`assets/fonts/`） | SIL OFL 1.1 | ブラウザ版に同梱（ライセンス全文は `assets/fonts/OFL.txt`）。デスクトップ版には含めない |
| ファームウェア | M5Unified 0.2.26 | MIT | 使用中（firmware/、PlatformIOのlib_depsで取得） |
| ファームウェア | M5GFX 0.2.33 | MIT | 使用中（M5Unified の依存、lib_depsで固定） |
| ファームウェア（BLE） | NimBLE-Arduino 2.5.1 | Apache-2.0 | 使用中（lib_depsで取得） |
| ファームウェア（基盤） | Arduino-ESP32 2.0.17（framework-arduinoespressif32） | LGPL-2.1+ | 使用中（PlatformIO の espressif32 6.13.0 が取得） |
| ファームウェア（テスト） | Unity 2.6.x | MIT | 開発ツール（`pio test -e native` のみ。成果物には含まれない） |
| ビルド環境 | PlatformIO Core | Apache-2.0 | 開発ツール（成果物には含まれない） |
| シリアル通信 | GdSerial / GDBLE 等のアドオン | MIT | **未同梱**。導入した場合のみ使用 |
| BLE通信（ブリッジ） | [bleak](https://github.com/hbldh/bleak) 0.22.3〜1.x | MIT | **未同梱**。ユーザー環境に pip で導入（`tools/ble_bridge/requirements.txt`） |
| bleak の依存（macOS） | pyobjc-core / pyobjc-framework-CoreBluetooth / pyobjc-framework-libdispatch（＋pyobjc-framework-Cocoa） | MIT | **未同梱**。bleak と一緒に pip が導入 |
| bleak の依存（Linux） | dbus-fast | MIT | **未同梱**。bleak と一緒に pip が導入 |
| bleak の依存（Windows） | winrt-runtime / winrt-Windows.Devices.Bluetooth ほか winrt-Windows.* 一式（pywinrt） | MIT | **未同梱**。bleak と一緒に pip が導入 |
| bleak の依存（共通） | typing-extensions（Python 3.12 未満） / async-timeout（Python 3.11 未満） | PSF-2.0 / Apache-2.0 | **未同梱**。bleak と一緒に pip が導入 |
| 有線のブリッジ経由（任意） | [pyserial](https://github.com/pyserial/pyserial) 3.5〜3.x | BSD-3-Clause | **未同梱**。ユーザー環境に pip で導入（`tools/ble_bridge/requirements.txt`）。依存なし。主に Windows で有線を使うとき |
| BLEブリッジの実行環境 | Python 3.9 以上 | PSF-2.0 | **未同梱**。ユーザー環境のものを使う |

## 方針

- 有線接続は OS標準コマンド（`stty` / `cat`）で実装しており、**サードパーティのバイナリを同梱していない**。
- BLE 接続は別プロセスの BLEブリッジ（`tools/ble_bridge/ble_bridge.py`、本リポジトリのコード）が担当する。
  ブリッジが使う bleak・pyserial とその依存は**アプリに同梱せず**、利用者が `setup.sh` / `setup.bat`（中身は `pip install`）で
  自分の環境に導入する。配布物にブリッジのフォルダを添える場合も、`.venv` は含めないこと。
- 波形描画も Godot標準機能（`_draw()`）で実装し、依存を増やさない。
- アドオンを同梱する場合は、各アドオンの LICENSE ファイルもあわせて含める。
- ファームウェアをビルド済みバイナリ（.bin）で配布する場合は、上記ファームウェア行のライセンス表記（Apache-2.0 の NOTICE、LGPL の再リンク可能性への配慮を含む）を添えること。ソースから各自ビルドする運用なら追加対応は不要。
- ライセンスが不明・確認中のものは導入しない。
