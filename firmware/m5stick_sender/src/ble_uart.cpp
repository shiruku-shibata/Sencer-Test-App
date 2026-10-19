#include "ble_uart.h"

#include <Arduino.h>
#include <NimBLEDevice.h>

#include <atomic>

#include "sender_core.h"

namespace ble_uart {
namespace {

// docs/DESIGN_P2.md 5.6 の UUID（Nordic UART Service）。変更禁止。
constexpr const char* kServiceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
constexpr const char* kRxUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";  // PC → デバイス (Write)
constexpr const char* kTxUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";  // デバイス → PC (Notify)

constexpr uint16_t kDefaultMtu = 23;

/// 1回の poll() で送る通知の上限。NimBLE の送信バッファを使い切らないように抑える。
constexpr int kMaxNotifiesPerPoll = 4;

/// 広告が止まっていたときに再開を試みる間隔 [ms]。
constexpr uint32_t kAdvertiseRetryMs = 1000;

// 接続パラメータ要望（1.25ms 単位）。15〜30ms は macOS / Windows が受け入れやすい範囲。
constexpr uint16_t kConnIntervalMin = 12;  // 15ms
constexpr uint16_t kConnIntervalMax = 24;  // 30ms
constexpr uint16_t kConnLatency = 0;
constexpr uint16_t kSupervisionTimeout = 400;  // 4s（10ms 単位）

// ---- NimBLE タスクと loop() で共有する状態 ----
std::atomic<bool> g_available{false};
std::atomic<bool> g_connected{false};
std::atomic<bool> g_subscribed{false};
std::atomic<uint16_t> g_mtu{kDefaultMtu};
std::atomic<uint16_t> g_conn_handle{BLE_HS_CONN_HANDLE_NONE};
std::atomic<bool> g_subscribed_event{false};
std::atomic<bool> g_reset_queue{false};

// RX のリングバッファ（NimBLE タスクが書き、loop() が読む）。
constexpr size_t kRxCapacity = 256;
char g_rx_buf[kRxCapacity];
size_t g_rx_head = 0;  // 次に読む位置
size_t g_rx_size = 0;
bool g_rx_reset = false;  // 新しい接続が始まった（受信途中の行を捨てる合図）
portMUX_TYPE g_rx_mux = portMUX_INITIALIZER_UNLOCKED;

// ---- loop() だけが触る状態 ----
NimBLEServer* g_server = nullptr;
NimBLECharacteristic* g_tx = nullptr;
sender::TxQueue g_queue;
uint32_t g_last_adv_try_ms = 0;

void pushRx(const uint8_t* data, size_t len) {
  portENTER_CRITICAL(&g_rx_mux);
  for (size_t i = 0; i < len && g_rx_size < kRxCapacity; ++i) {
    g_rx_buf[(g_rx_head + g_rx_size) % kRxCapacity] = static_cast<char>(data[i]);
    ++g_rx_size;
  }
  // 入りきらない分は捨てる（コマンドは短いので通常起きない）。
  portEXIT_CRITICAL(&g_rx_mux);
}

/// 新しい接続の開始時に、前の接続の受信データを捨てる。
void resetRx() {
  portENTER_CRITICAL(&g_rx_mux);
  g_rx_head = 0;
  g_rx_size = 0;
  g_rx_reset = true;
  portEXIT_CRITICAL(&g_rx_mux);
}

/// 切断・再購読のあとに、古い送信待ちデータを捨てる。
void applyPendingReset() {
  if (g_reset_queue.exchange(false)) g_queue.clear();
}

class ServerCallbacks : public NimBLEServerCallbacks {
 public:
  void onConnect(NimBLEServer* server, NimBLEConnInfo& info) override {
    g_conn_handle = info.getConnHandle();
    g_mtu = info.getMTU();
    g_connected = true;
    g_subscribed = false;
    g_reset_queue = true;
    resetRx();
    // 低遅延のための要望。相手（OS）が拒否しても接続は続く。
    server->updateConnParams(info.getConnHandle(), kConnIntervalMin, kConnIntervalMax,
                             kConnLatency, kSupervisionTimeout);
  }

  void onDisconnect(NimBLEServer* /*server*/, NimBLEConnInfo& /*info*/, int /*reason*/) override {
    g_connected = false;
    g_subscribed = false;
    g_conn_handle = BLE_HS_CONN_HANDLE_NONE;
    g_mtu = kDefaultMtu;
    g_reset_queue = true;
    // 再広告は advertiseOnDisconnect(true) と poll() の両方で行う。
  }

  void onMTUChange(uint16_t mtu, NimBLEConnInfo& /*info*/) override { g_mtu = mtu; }
};

class TxCallbacks : public NimBLECharacteristicCallbacks {
 public:
  void onSubscribe(NimBLECharacteristic* /*chr*/, NimBLEConnInfo& info,
                   uint16_t sub_value) override {
    const bool notify_on = (sub_value & 0x0001) != 0;
    const bool was = g_subscribed.exchange(notify_on);
    if (notify_on) {
      g_conn_handle = info.getConnHandle();
      if (!was) {
        g_reset_queue = true;
        g_subscribed_event = true;
      }
    }
  }
};

class RxCallbacks : public NimBLECharacteristicCallbacks {
 public:
  void onWrite(NimBLECharacteristic* chr, NimBLEConnInfo& /*info*/) override {
    const NimBLEAttValue value = chr->getValue();
    pushRx(value.data(), value.length());
  }
};

ServerCallbacks g_server_callbacks;
TxCallbacks g_tx_callbacks;
RxCallbacks g_rx_callbacks;

bool startAdvertising() {
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  if (adv == nullptr) return false;
  if (adv->isAdvertising()) return true;
  return adv->start();
}

}  // namespace

bool begin(const char* device_name) {
  if (!NimBLEDevice::init(device_name)) return false;

  g_server = NimBLEDevice::createServer();
  if (g_server == nullptr) return false;
  g_server->setCallbacks(&g_server_callbacks, false);
  g_server->advertiseOnDisconnect(true);

  NimBLEService* service = g_server->createService(kServiceUuid);
  g_tx = service->createCharacteristic(kTxUuid, NIMBLE_PROPERTY::NOTIFY);
  NimBLECharacteristic* rx =
      service->createCharacteristic(kRxUuid, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  if (g_tx == nullptr || rx == nullptr) return false;
  g_tx->setCallbacks(&g_tx_callbacks);
  rx->setCallbacks(&g_rx_callbacks);
  // NimBLE-Arduino 2.x ではサービスはサーバ開始（広告開始）時に自動で開始される。

  // 広告パケット（31バイト以内）: Flags(3) + 128bit サービスUUID(18) = 21 バイト。
  NimBLEAdvertisementData adv_data;
  adv_data.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
  adv_data.addServiceUUID(NimBLEUUID(kServiceUuid));

  // スキャン応答（31バイト以内）: Complete Local Name "M5-Sensor-XXXX" = 2 + 14 = 16 バイト。
  NimBLEAdvertisementData scan_data;
  scan_data.setName(device_name);

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->enableScanResponse(true);
  if (!adv->setAdvertisementData(adv_data) || !adv->setScanResponseData(scan_data)) return false;

  g_available = true;
  g_last_adv_try_ms = millis();
  // 広告の開始に失敗しても、poll() が定期的にやり直すので BLE は有効のままにする。
  startAdvertising();
  return true;
}

bool available() { return g_available; }

bool poll() {
  if (!g_available) return false;
  applyPendingReset();

  if (!g_connected) {
    // 念のため：切断後に広告が止まったままなら定期的に再開する。
    const uint32_t now = millis();
    if (now - g_last_adv_try_ms >= kAdvertiseRetryMs) {
      g_last_adv_try_ms = now;
      startAdvertising();
    }
    return false;
  }

  if (!g_subscribed || g_queue.empty() || g_tx == nullptr) return false;

  const size_t payload = sender::blePayloadSize(g_mtu);
  const uint16_t handle = g_conn_handle;
  if (handle == BLE_HS_CONN_HANDLE_NONE) return false;

  bool sent = false;
  for (int i = 0; i < kMaxNotifiesPerPoll && !g_queue.empty(); ++i) {
    const size_t n = sender::nextChunkLength(g_queue.data(), g_queue.size(), payload);
    if (n == 0) break;
    if (!g_tx->notify(reinterpret_cast<const uint8_t*>(g_queue.data()), n, handle)) {
      // 送信バッファ不足など。消さずに残して次回再送する。
      break;
    }
    g_queue.consume(n);
    sent = true;
  }
  return sent;
}

bool isConnected() { return g_connected; }

bool isSubscribed() { return g_subscribed; }

uint16_t mtu() { return g_mtu; }

void sendLine(const char* line, size_t len) {
  if (!g_available) return;
  applyPendingReset();
  if (!g_connected || !g_subscribed) return;
  g_queue.pushLine(line, len);
}

size_t readCommandBytes(char* out, size_t cap, bool* reset_before) {
  if (reset_before) *reset_before = false;
  if (out == nullptr || cap == 0) return 0;
  portENTER_CRITICAL(&g_rx_mux);
  if (g_rx_reset) {
    g_rx_reset = false;
    if (reset_before) *reset_before = true;
  }
  size_t n = 0;
  while (n < cap && g_rx_size > 0) {
    out[n++] = g_rx_buf[g_rx_head];
    g_rx_head = (g_rx_head + 1) % kRxCapacity;
    --g_rx_size;
  }
  portEXIT_CRITICAL(&g_rx_mux);
  return n;
}

bool takeSubscribedEvent() {
  applyPendingReset();
  return g_subscribed_event.exchange(false);
}

uint32_t droppedLines() { return g_queue.droppedLines(); }

}  // namespace ble_uart
