/*
 * ble_uart - Nordic UART Service (NUS) による BLE シリアル
 *
 * docs/DESIGN_P2.md 5.6「BLE プロトコル」の実装。
 *   サービス  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
 *   TX(Notify) 6E400003-...  デバイス → PC。有線と同じ CSV 行／# 情報行
 *   RX(Write)  6E400002-...  PC → デバイス。コマンド（改行終端）
 *
 * 使い方（すべて loop() と同じタスクから呼ぶ）:
 *   ble_uart::begin("M5-Sensor-1A2B");
 *   loop() で ble_uart::poll() を毎回呼ぶ（送信キューの吐き出し・切断後の再広告）。
 *   ble_uart::sendLine() で1行送る（購読されていなければ何もしない）。
 *   ble_uart::readCommandBytes() で RX に届いたバイト列を取り出す。
 *
 * NimBLE のコールバックは別タスクで動くので、ここでフラグ／リングバッファに移し替えて
 * loop() 側からだけ通知を送るようにしている（スレッド安全のため）。
 */
#pragma once

#include <cstddef>
#include <cstdint>

namespace ble_uart {

/// BLE を初期化して広告を開始する。失敗したら false（BLE なしで動作を続ける）。
bool begin(const char* device_name);

/// 初期化に成功して BLE が使える状態か。
bool available();

/// 送信キューを吐き出し、切断後なら再広告する。loop() から毎回呼ぶ。
/// 何か通知を送ったら true（ループの休止判断に使う）。
bool poll();

/// 接続中か（購読していなくても true）。
bool isConnected();

/// TX の通知が購読されているか（データを送るのはこのときだけ）。
bool isSubscribed();

/// 現在の ATT MTU（未接続時は 23）。
uint16_t mtu();

/// 1行（末尾 '\n' 込み）を送信キューに入れる。購読されていなければ捨てる。
void sendLine(const char* line, size_t len);

/// RX に届いたバイト列を最大 cap バイト取り出す。戻り値は取り出した長さ。
/// reset_before が true になったら新しい接続が始まっているので、取り出したバイトを
/// 処理する前に行の組み立て途中のデータ（前の接続の残り）を捨てること。
size_t readCommandBytes(char* out, size_t cap, bool* reset_before);

/// 購読が新しく始まったら1回だけ true（接続直後に情報行を送るため）。
bool takeSubscribedEvent();

/// 送信キューがあふれて捨てた行数の累計。
uint32_t droppedLines();

}  // namespace ble_uart
