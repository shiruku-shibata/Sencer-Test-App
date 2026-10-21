/*
 * status_display - 本体の画面（または LED）に状態を表示する
 *
 * 画面がある機種: 名前・送信中/停止・BLE 接続状態・レート・機種/IMU を表示。
 * 画面が無い機種: 内蔵 RGB LED があれば色で状態を表示（ATOM Matrix / ATOM Lite など）。
 *                 どちらも無ければ何もしない（動作には影響しない）。
 *
 * 描画は状態が変わったときだけ行う（毎フレーム描くと送信タイミングが乱れるため）。
 */
#pragma once

#include <cstdint>

namespace status_display {

struct Status {
  const char* name = "";
  const char* model = "";
  const char* imu = "";
  bool imu_ok = true;
  bool sending = true;
  int rate_hz = 100;
  bool ble_available = true;
  bool ble_connected = false;
  bool ble_subscribed = false;
};

/// M5.begin() の後に1回呼ぶ。
void begin();

/// 表示内容が前回と違えば描き直す。
void update(const Status& status);

}  // namespace status_display
