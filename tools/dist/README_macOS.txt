センサーテストアプリ（Sensor Test App）macOS 版
==================================================

M5 製品（M5StickC Plus2 など）の IMU（加速度・ジャイロ）を受信して、
ゲーム用の「しきい値」を測定・調整・保存するツールです。

■ 動作環境
  macOS 11 以降（Apple シリコン / Intel 両対応）

■ 起動のしかた（初回だけ）
  このアプリは Apple の公証を受けていないため、ダブルクリックでは
  「開発元を検証できません」と出て開けません。次のどちらかで開いてください。

  1. 「Sensor Test App」を右クリック（control + クリック）→「開く」→ ダイアログで「開く」
  2. それでも開けないときは、ターミナルでこのフォルダに移動して次を実行:
       xattr -dr com.apple.quarantine "Sensor Test App.app"

  2回目からはダブルクリックで開けます。

■ まず試す（実機なしで5分）
  1. 「デバイス管理」で「スキャン」→ demo-01 の「接続」
  2. 「しきい値測定」で軸「gZ（ジャイロ Z）」を選ぶ
  3. ①静止測定 → ②試行開始/終了（Space キー）を5回（デモは試行を始めるたびに1回振ります）
     → ③推奨値を適用 → ④判定テスト
  4. ⑤で名前を付けて保存。「JSONをコピー」「コードをコピー」で共有できます
  詳しい使い方はアプリ内の「マニュアル」（右上の ?）にあります。

■ 実機（M5）を使う
  ・M5 側に専用ファームウェアの書き込みが必要です（PlatformIO）。
    ソースと手順: https://github.com/shiruku-shibata/Sencer-Test-App の firmware/m5stick_sender
  ・有線: USB ケーブル（データ通信対応）で接続 → スキャン → 接続（/dev/cu.* を選ぶ）
  ・BLE: 下の「BLE を使う場合」を一度だけ行ってください。

■ BLE を使う場合（最初に一度だけ）
  Python 3.9 以上が必要です（macOS 標準の python3 で可）。
  ターミナルでこのフォルダに移動して:
       sh ble_bridge/setup.sh
  これで ble_bridge/.venv に必要なもの（bleak）が入り、アプリが自動で BLE を使えるようになります。
  初回に Bluetooth の使用許可を求められたら「許可」してください。
  うまくいかない場合は、デバイス管理画面の「手動起動で接続」に表示されるコマンドを
  ターミナルで実行してください（詳しくは ble_bridge/README.md）。

  ※ ble_bridge フォルダは「Sensor Test App.app」と同じ場所に置いたままにしてください。

■ データの保存場所
  記録した CSV やしきい値プロファイルは次の場所に保存されます（アプリ内のボタンでも開けます）。
    ~/Library/Application Support/Godot/app_userdata/Sensor Test App/

■ ライセンス
  THIRD_PARTY_LICENSES.md を参照してください。
