#include "status_display.h"

#include <M5Unified.h>

#include <cstring>

namespace status_display {
namespace {

bool g_has_display = false;
bool g_has_led = false;
bool g_drawn_once = false;
Status g_last;

// 色（RGB565）。
constexpr uint16_t kColorBg = TFT_BLACK;
constexpr uint16_t kColorText = TFT_WHITE;
constexpr uint16_t kColorDim = TFT_DARKGREY;
constexpr uint16_t kColorSending = TFT_GREEN;
constexpr uint16_t kColorPaused = TFT_ORANGE;
constexpr uint16_t kColorError = TFT_RED;
constexpr uint16_t kColorBle = TFT_CYAN;

bool sameStatus(const Status& a, const Status& b) {
  return a.imu_ok == b.imu_ok && a.sending == b.sending && a.rate_hz == b.rate_hz &&
         a.ble_available == b.ble_available && a.ble_connected == b.ble_connected &&
         a.ble_subscribed == b.ble_subscribed && std::strcmp(a.name, b.name) == 0 &&
         std::strcmp(a.model, b.model) == 0 && std::strcmp(a.imu, b.imu) == 0;
}

void drawScreen(const Status& s) {
  auto& d = M5.Display;
  const int w = d.width();
  const int h = d.height();

  // 小さい画面（StickC 160x80）でも 6 行入るように文字の大きさを決める。
  // Font2 は高さ 16px・平均幅 約 8px。名前（14文字）が横に収まる範囲で最大 2 倍。
  float scale = static_cast<float>(h) / 96.0f;
  const float by_width = static_cast<float>(w) / 128.0f;
  if (scale > by_width) scale = by_width;
  if (scale > 2.0f) scale = 2.0f;
  if (scale < 1.0f) scale = 1.0f;

  d.startWrite();
  d.fillScreen(kColorBg);
  d.setFont(&fonts::Font2);
  d.setTextSize(scale);
  d.setTextWrap(false);
  d.setCursor(0, 0);

  d.setTextColor(kColorText, kColorBg);
  d.println(s.name);

  if (!s.imu_ok) {
    d.setTextColor(kColorError, kColorBg);
    d.println("IMU ERROR");
    d.setTextColor(kColorDim, kColorBg);
    d.println("no data");
  } else if (s.sending) {
    d.setTextColor(kColorSending, kColorBg);
    d.println("SENDING");
    d.setTextColor(kColorText, kColorBg);
    d.printf("%d Hz\n", s.rate_hz);
  } else {
    d.setTextColor(kColorPaused, kColorBg);
    d.println("PAUSED");
    d.setTextColor(kColorDim, kColorBg);
    d.printf("%d Hz\n", s.rate_hz);
  }

  if (!s.ble_available) {
    d.setTextColor(kColorError, kColorBg);
    d.println("BLE: off");
  } else if (s.ble_subscribed) {
    d.setTextColor(kColorBle, kColorBg);
    d.println("BLE: streaming");
  } else if (s.ble_connected) {
    d.setTextColor(kColorBle, kColorBg);
    d.println("BLE: connected");
  } else {
    d.setTextColor(kColorDim, kColorBg);
    d.println("BLE: advertising");
  }

  d.setTextColor(kColorDim, kColorBg);
  d.printf("%s/%s\n", s.model, s.imu);
  d.endWrite();
}

void drawLed(const Status& s) {
  // LED は眩しく発熱もするので暗めにする。
  uint8_t r = 0, g = 0, b = 0;
  if (!s.imu_ok) {
    r = 255;
  } else if (!s.sending) {
    r = 255;
    g = 96;
  } else if (s.ble_subscribed) {
    b = 255;
  } else {
    g = 255;
  }
  M5.Led.setAllColor(r, g, b);
  M5.Led.display();
}

}  // namespace

void begin() {
  g_has_display = M5.getDisplayCount() > 0 && M5.Display.width() > 0 && M5.Display.height() > 0;
  if (g_has_display) {
    // 縦長パネル（StickC 系など）は横向きにする。
    if (M5.Display.height() > M5.Display.width()) {
      M5.Display.setRotation((M5.Display.getRotation() + 1) & 3);
    }
    M5.Display.fillScreen(kColorBg);
  }
  g_has_led = M5.Led.isEnabled();
  if (g_has_led) {
    M5.Led.setBrightness(16);
  }
  g_drawn_once = false;
}

void update(const Status& status) {
  if (g_drawn_once && sameStatus(status, g_last)) return;
  g_last = status;
  g_drawn_once = true;
  if (g_has_display) drawScreen(status);
  if (g_has_led) drawLed(status);
}

}  // namespace status_display
