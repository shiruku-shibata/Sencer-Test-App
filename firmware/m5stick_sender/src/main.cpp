/*
 * m5stick_sender - センサーテストアプリ用 送信ファームウェア v2
 *
 * 対象デバイス: M5Unified が対応する IMU 付き M5 製品（機種は起動時に自動判別）
 *               M5StickC Plus2 / Plus / StickC / Core2 / CoreS3 / AtomS3 / ATOM Matrix など
 * ビルド環境  : PlatformIO (framework = arduino)。機種ごとの env は platformio.ini を参照。
 * 依存ライブラリ: M5Unified / M5GFX (MIT), NimBLE-Arduino (Apache-2.0)
 *
 * 動作:
 *   内蔵 6 軸 IMU（加速度・ジャイロ）を一定間隔で読み取り、1 行 1 サンプルの CSV として
 *   USB シリアルと BLE（Nordic UART Service）の両方に送る。
 *
 *   形式: ax,ay,az,gx,gy,gz          （加速度 G・ジャイロ deg/s）
 *   例  : 0.0210,0.9832,-0.0104,12.400,-3.100,0.800
 *   シリアル: 115200bps / 改行 LF
 *   '#' で始まる行は情報行（アプリは無視する）。
 *
 * コマンド（USB シリアル・BLE RX 共通。改行終端・大文字小文字は区別しない）:
 *   PAUSE / RESUME / RATE <Hz>（10〜200）/ INFO
 *
 * 操作:
 *   A ボタン（前面の大きいボタン。CoreS3 は画面タップ）で送信の一時停止／再開。
 *
 * 通信仕様は docs/DESIGN_P2.md 5.6、使い方は README.md を参照。
 */

#include <Arduino.h>
#include <M5Unified.h>

#if __has_include(<esp_mac.h>)
#include <esp_mac.h>
#else
#include <esp_system.h>
#endif

#include "ble_uart.h"
#include "sender_core.h"
#include "status_display.h"

namespace {

constexpr uint32_t kSerialBaud = 115200;
constexpr size_t kSerialTxBufferSize = 1024;

/// IMU が無いときにエラー行を繰り返す間隔 [ms]（後からモニタを開いても気づけるように）。
constexpr uint32_t kImuErrorRepeatMs = 5000;

/// どこから来たコマンドか（応答を返す先）。
enum class Channel : uint8_t { kSerial, kBle };

// ---- 状態 ----
char g_name[24] = "M5-Sensor-0000";
const char* g_model = "Unknown";
const char* g_imu_name = "none";
bool g_imu_ok = false;
bool g_sending = true;
bool g_ble_ok = false;
uint32_t g_last_imu_error_ms = 0;
uint32_t g_serial_dropped = 0;

sender::RateScheduler g_scheduler;
sender::LineAssembler g_serial_lines;
sender::LineAssembler g_ble_lines;

// ------------------------------------------------------------
// 機種名・IMU 名
// ------------------------------------------------------------

const char* boardName(m5::board_t board) {
  switch (board) {
    case m5::board_t::board_M5Stack: return "M5Stack";
    case m5::board_t::board_M5StackCore2: return "M5StackCore2";
    case m5::board_t::board_M5StickC: return "M5StickC";
    case m5::board_t::board_M5StickCPlus: return "M5StickCPlus";
    case m5::board_t::board_M5StickCPlus2: return "M5StickCPlus2";
    case m5::board_t::board_M5StackCoreInk: return "M5StackCoreInk";
    case m5::board_t::board_M5Paper: return "M5Paper";
    case m5::board_t::board_M5Tough: return "M5Tough";
    case m5::board_t::board_M5Station: return "M5Station";
    case m5::board_t::board_M5StackCoreS3: return "M5StackCoreS3";
    case m5::board_t::board_M5StackCoreS3SE: return "M5StackCoreS3SE";
    case m5::board_t::board_M5AtomS3: return "M5AtomS3";
    case m5::board_t::board_M5AtomS3Lite: return "M5AtomS3Lite";
    case m5::board_t::board_M5AtomS3R: return "M5AtomS3R";
    case m5::board_t::board_M5Dial: return "M5Dial";
    case m5::board_t::board_M5Cardputer: return "M5Cardputer";
    case m5::board_t::board_M5AtomLite: return "M5AtomLite";
    case m5::board_t::board_M5AtomMatrix: return "M5AtomMatrix";
    case m5::board_t::board_M5AtomPsram: return "M5AtomPsram";
    case m5::board_t::board_M5AtomU: return "M5AtomU";
    case m5::board_t::board_M5StampPico: return "M5StampPico";
    case m5::board_t::board_M5StampS3: return "M5StampS3";
    case m5::board_t::board_unknown: return "Unknown";
    default: return "M5Other";
  }
}

const char* imuName(m5::imu_t imu) {
  switch (imu) {
    case m5::imu_t::imu_none: return "none";
    case m5::imu_t::imu_sh200q: return "SH200Q";
    case m5::imu_t::imu_mpu6050: return "MPU6050";
    case m5::imu_t::imu_mpu6886: return "MPU6886";
    case m5::imu_t::imu_mpu9250: return "MPU9250";
    case m5::imu_t::imu_bmi270: return "BMI270";
    case m5::imu_t::imu_unknown:
    default: return "unknown";
  }
}

// ------------------------------------------------------------
// 出力
// ------------------------------------------------------------

/// シリアルへ 1 行書く。送信バッファに入りきらないときは待たずに捨てる
/// （PC が読んでいない USB-CDC で loop() が止まらないように）。
void serialWriteLine(const char* line, size_t len) {
  if (len == 0) return;
  if (Serial.availableForWrite() < static_cast<int>(len)) {
    ++g_serial_dropped;
    return;
  }
  Serial.write(reinterpret_cast<const uint8_t*>(line), len);
}

void emit(Channel channel, const char* line, size_t len) {
  if (channel == Channel::kSerial) {
    serialWriteLine(line, len);
  } else {
    ble_uart::sendLine(line, len);
  }
}

void emitAll(const char* line, size_t len) {
  serialWriteLine(line, len);
  ble_uart::sendLine(line, len);
}

size_t buildInfoLine(char* out, size_t cap) {
  sender::DeviceInfo info;
  info.model = g_model;
  info.name = g_name;
  info.imu = g_imu_name;
  info.rate_hz = g_scheduler.rateHz();
  info.ble_available = g_ble_ok;
  info.sending = g_sending;
  info.ble_connected = ble_uart::isConnected();
  info.dropped_usb = g_serial_dropped;
  info.dropped_ble = ble_uart::droppedLines();
  return sender::formatInfoLine(out, cap, info);
}

void emitInfo(Channel channel) {
  char line[sender::kMaxLineLength];
  emit(channel, line, buildInfoLine(line, sizeof(line)));
}

void emitImuError(bool to_ble) {
  static const char kLine[] = "# error=imu_not_found\n";
  serialWriteLine(kLine, sizeof(kLine) - 1);
  if (to_ble) ble_uart::sendLine(kLine, sizeof(kLine) - 1);
}

// ------------------------------------------------------------
// 状態変更
// ------------------------------------------------------------

void setSending(bool sending, uint32_t now_ms) {
  if (sending && !g_sending) {
    // 再開時は今を起点にする（止めていた間の分をまとめて送らない）。
    g_scheduler.start(now_ms, g_scheduler.rateHz());
  }
  g_sending = sending;
}

void handleLine(Channel channel, const char* text, size_t len) {
  const sender::Command cmd = sender::parseCommand(text, len);
  char line[sender::kMaxLineLength];
  size_t n = 0;
  const uint32_t now = millis();

  switch (cmd.type) {
    case sender::CommandType::kNone:
      return;
    case sender::CommandType::kPause:
      setSending(false, now);
      n = static_cast<size_t>(snprintf(line, sizeof(line), "# ok=PAUSE sending=0\n"));
      break;
    case sender::CommandType::kResume:
      setSending(true, now);
      n = static_cast<size_t>(snprintf(line, sizeof(line), "# ok=RESUME sending=1\n"));
      break;
    case sender::CommandType::kRate:
      g_scheduler.start(now, cmd.rate_hz);
      n = static_cast<size_t>(snprintf(line, sizeof(line), "# ok=RATE rate=%d\n",
                                       g_scheduler.rateHz()));
      break;
    case sender::CommandType::kInfo:
      n = buildInfoLine(line, sizeof(line));
      break;
    case sender::CommandType::kError:
      n = sender::formatCommandError(line, sizeof(line), cmd);
      break;
  }
  if (n >= sizeof(line)) n = 0;
  emit(channel, line, n);
}

void feedAssembler(Channel channel, sender::LineAssembler& assembler, char c) {
  switch (assembler.push(c)) {
    case sender::LineAssembler::Result::kLine:
      handleLine(channel, assembler.line(), assembler.length());
      break;
    case sender::LineAssembler::Result::kOverflow: {
      sender::Command err;
      err.type = sender::CommandType::kError;
      err.error = sender::CommandError::kLineTooLong;
      char line[sender::kMaxLineLength];
      emit(channel, line, sender::formatCommandError(line, sizeof(line), err));
      break;
    }
    case sender::LineAssembler::Result::kNone:
      break;
  }
}

void pollCommands() {
  // 1 回の loop() で読みすぎないよう上限を設ける（サンプル送信を遅らせないため）。
  for (int i = 0; i < 64 && Serial.available() > 0; ++i) {
    const int c = Serial.read();
    if (c < 0) break;
    feedAssembler(Channel::kSerial, g_serial_lines, static_cast<char>(c));
  }
  if (g_ble_ok) {
    char buf[64];
    bool reset = false;
    const size_t n = ble_uart::readCommandBytes(buf, sizeof(buf), &reset);
    if (reset) g_ble_lines.reset();
    for (size_t i = 0; i < n; ++i) feedAssembler(Channel::kBle, g_ble_lines, buf[i]);
  }
}

bool toggleRequested() {
  if (M5.BtnA.wasPressed()) return true;
  // CoreS3 には物理ボタンが無いので、画面タップで代用する。
  const auto board = M5.getBoard();
  if ((board == m5::board_t::board_M5StackCoreS3 ||
       board == m5::board_t::board_M5StackCoreS3SE) &&
      M5.Touch.getCount() > 0 && M5.Touch.getDetail(0).wasPressed()) {
    return true;
  }
  return false;
}

/// IMU を読み取って 1 サンプル送る。
void sendSample() {
  M5.Imu.update();
  const auto& data = M5.Imu.getImuData();
  char line[sender::kMaxLineLength];
  const size_t n = sender::formatSample(line, sizeof(line), data.accel.x, data.accel.y,
                                        data.accel.z, data.gyro.x, data.gyro.y, data.gyro.z);
  if (n == 0) return;
  serialWriteLine(line, n);
  ble_uart::sendLine(line, n);
}

void refreshDisplay() {
  status_display::Status s;
  s.name = g_name;
  s.model = g_model;
  s.imu = g_imu_name;
  s.imu_ok = g_imu_ok;
  s.sending = g_sending;
  s.rate_hz = g_scheduler.rateHz();
  s.ble_available = g_ble_ok;
  s.ble_connected = ble_uart::isConnected();
  s.ble_subscribed = ble_uart::isSubscribed();
  status_display::update(s);
}

void makeDeviceName() {
  uint8_t mac[6] = {};
  // BLE のアドレス（= bleak が Windows/Linux で表示する MAC）の下位 2 バイトを使う。
  if (esp_read_mac(mac, ESP_MAC_BT) != ESP_OK) {
    esp_efuse_mac_get_default(mac);
  }
  sender::formatDeviceName(g_name, sizeof(g_name), mac);
}

}  // namespace

void setup() {
  // M5.begin() より先にシリアルを開く（送信バッファは begin() 前にしか変えられない）。
  Serial.setTxBufferSize(kSerialTxBufferSize);
  Serial.begin(kSerialBaud);

  auto cfg = M5.config();
  cfg.serial_baudrate = 0;  // シリアルは上で開いた
  cfg.internal_imu = true;
  M5.begin(cfg);

  g_model = boardName(M5.getBoard());
  g_imu_ok = M5.Imu.isEnabled();
  g_imu_name = imuName(M5.Imu.getType());

  makeDeviceName();
  g_ble_ok = ble_uart::begin(g_name);

  const uint32_t now = millis();
  g_scheduler.start(now, sender::kRateDefaultHz);

  status_display::begin();
  refreshDisplay();

  emitInfo(Channel::kSerial);
  if (!g_ble_ok) {
    static const char kLine[] = "# error=ble_init_failed\n";
    serialWriteLine(kLine, sizeof(kLine) - 1);
  }
  if (!g_imu_ok) {
    emitImuError(false);
    g_last_imu_error_ms = now;
  }
}

void loop() {
  M5.update();
  const uint32_t now = millis();
  bool busy = false;

  // A ボタンで送信の ON/OFF（応答は両方の経路に情報行で知らせる）。
  if (toggleRequested()) {
    setSending(!g_sending, now);
    char line[48];
    const int n = snprintf(line, sizeof(line), "# event=button sending=%d\n", g_sending ? 1 : 0);
    if (n > 0 && static_cast<size_t>(n) < sizeof(line)) emitAll(line, static_cast<size_t>(n));
  }

  pollCommands();

  if (g_ble_ok) {
    if (ble_uart::takeSubscribedEvent()) {
      // BLE で購読が始まったら、まず情報行を送る（ブリッジが機種やレートを知るため）。
      emitInfo(Channel::kBle);
      if (!g_imu_ok) emitImuError(true);
    }
  }

  if (g_imu_ok) {
    if (g_sending && g_scheduler.poll(now)) {
      sendSample();
      busy = true;
    }
  } else if (now - g_last_imu_error_ms >= kImuErrorRepeatMs) {
    g_last_imu_error_ms = now;
    emitImuError(true);
  }

  if (g_ble_ok && ble_uart::poll()) busy = true;

  refreshDisplay();

  // 次のサンプルまで余裕があるときは 1ms 休んで電力と発熱を抑える。
  if (!busy) delay(1);
}
