/*
 * m5stick_sender - センサーテストアプリ用 送信ファームウェア
 *
 * 対象デバイス: M5StickC Plus2
 * ビルド環境  : PlatformIO (framework = arduino)
 * 依存ライブラリ: M5Unified (MIT License)
 *
 * 動作:
 *   内蔵6軸IMU（加速度・ジャイロ）を一定間隔で読み取り、
 *   1行1サンプルのCSVとしてUSBシリアルに送信する。
 *
 *   形式: ax,ay,az,gx,gy,gz
 *   例  : 0.0210,0.9832,-0.0104,12.400,-3.100,0.800
 *   ボーレート: 115200 / 改行: LF
 *
 * 操作:
 *   Aボタン（本体前面の大きいボタン）で送信の一時停止／再開を切り替える。
 */

#include <Arduino.h>
#include <M5Unified.h>

/// 送信間隔[ms]。10ms = 100Hz。値を大きくすると送信レートが下がる。
static constexpr uint32_t SEND_INTERVAL_MS = 10;
static constexpr uint32_t SERIAL_BAUD = 115200;

static uint32_t g_last_sent_ms = 0;
static bool g_sending = true;

/// 画面に現在の状態を表示する。
static void drawStatus() {
  M5.Display.clear();
  M5.Display.setCursor(0, 0);
  M5.Display.println("Sensor Test");
  M5.Display.println(g_sending ? "SENDING" : "PAUSED");
}

void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);
  Serial.begin(SERIAL_BAUD);

  M5.Display.setRotation(1);
  M5.Display.setTextSize(2);
  drawStatus();
}

void loop() {
  M5.update();

  // Aボタンで送信のON/OFFを切り替え
  if (M5.BtnA.wasPressed()) {
    g_sending = !g_sending;
    drawStatus();
  }

  const uint32_t now = millis();
  if (!g_sending || (now - g_last_sent_ms) < SEND_INTERVAL_MS) {
    return;
  }
  g_last_sent_ms = now;

  float ax = 0.0f, ay = 0.0f, az = 0.0f;
  float gx = 0.0f, gy = 0.0f, gz = 0.0f;
  M5.Imu.getAccelData(&ax, &ay, &az);  // 単位: G
  M5.Imu.getGyroData(&gx, &gy, &gz);   // 単位: deg/s

  Serial.printf("%.4f,%.4f,%.4f,%.3f,%.3f,%.3f\n", ax, ay, az, gx, gy, gz);
}
