# センサーテストアプリ（Sensor Test App）

ゲーム制作で使用するセンサー（M5StickC Plus2）の加速度・ジャイロデータを、PC上でリアルタイムに
可視化・記録・検証するためのローカルテストツールです。

現在は **開発ステップ3（実装・試作品作成）の第1弾**。P1機能（有線シリアル接続 → モニタリング →
CSV記録 ＋ アプリ内マニュアル）を実装しています。

## 使い方（アプリ）

1. Godot 4.4 系でこのフォルダをプロジェクトとして開き、実行（F5）します。
2. 「デバイス管理」画面で **スキャン** を押します。
3. 一覧からポート（macOSでは `/dev/cu.*`）を選び **接続** します。
   - 実機が無い場合は、**デモ**と表示される `demo-01` / `demo-02` に接続すればダミーデータで一通り試せます。
4. 「モニタリング」画面で波形を確認し、**● 記録開始** でCSV記録を開始します。
5. 記録したCSVは「ログ管理」画面から確認・削除できます（保存先は `user://logs`）。

## 実機を使う場合

1. `firmware/m5stick_sender/` を PlatformIO で開き、M5StickC Plus2 に書き込みます（`pio run -t upload`）。
2. USBケーブル（データ通信対応）でMacに接続します。
3. アプリで **スキャン → 接続** します。

## 有線接続の仕組み

Godotには標準のシリアル通信機能がありません。本アプリでは2通りの経路を用意しています。

| 経路 | 実装 | 対応OS | 備考 |
|---|---|---|---|
| OS標準コマンド経由（既定） | `src/core/pipe_serial_sensor_provider.gd` | macOS / Linux | `stty` + `cat` を使用。外部アドオン不要 |
| シリアル通信アドオン経由 | `src/core/serial_port_adapter.gd` | 全OS | GdSerial等を導入した場合に自動で切り替わる |

アドオンが導入されていればそちらを優先し、無ければOS標準コマンド経由で動作します（`SensorManager._ready()`）。
Windowsで有線を使う場合はアドオンの導入が必要です。

## ビルド（配布用）

```bash
# エクスポートテンプレート（エンジンと同じバージョン）を入れたうえで
godot --headless --export-release "macOS" build/SensorTestApp.zip
```

macOSでは未署名配布になるため、受け取った側で初回に右クリック →「開く」が必要です。
開けない場合は `xattr -dr com.apple.quarantine "Sensor Test App.app"` を実行してください。

## フォルダ構成

```
src/
├── core/                            ロジック層（UIに依存しない）
│   ├── sensor_reading.gd            1サンプル分のデータ
│   ├── sensor_device.gd             デバイス情報
│   ├── sensor_provider.gd           通信方式ごとの基底クラス
│   ├── pipe_serial_sensor_provider.gd  有線（OS標準コマンド経由）
│   ├── serial_sensor_provider.gd    有線（アドオン経由）
│   ├── serial_port_adapter.gd       アドオンへの薄いラッパー
│   ├── mock_sensor_provider.gd      ダミーデータ（実機なしの確認用）
│   ├── sensor_data_parser.gd        受信文字列 → SensorReading
│   ├── device_registry.gd           デバイス一覧とニックネーム管理
│   ├── sensor_manager.gd            Providerの集約・配信
│   └── logging_service.gd           CSV記録
└── ui/
    ├── main.gd / main.tscn          サイドバー・画面切り替え・ステータスバー
    ├── ui_strings.gd                UI文言の一元管理
    ├── screens/                     各画面（S1/S2/S3/S5）
    └── widgets/waveform_view.gd     波形描画（Godot標準の _draw のみ）

firmware/m5stick_sender/             M5StickC Plus2 用送信ファームウェア（PlatformIO）
```

## 未実装（次段階 P2 以降）

- BLE接続
- キャリブレーション画面（波形上のドラッグによるしきい値設定・判定シミュレーション）
- 複数デバイスの同時波形表示（現在は対象デバイスを1台選択して表示）
- 設定画面

## ライセンス

本リポジトリのライセンスは未定です（公開前に決定します）。
サードパーティのライセンスは [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) を参照してください。
