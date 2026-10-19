/*
 * sender_core の単体テスト（PC 上で実行）
 *
 *   cd firmware/m5stick_sender
 *   pio test -e native
 *
 * 実機を使わずに、コマンド解析・行の組み立て・BLE 分割送信・送信タイミングを確認する。
 */
#include <unity.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>

#include "sender_core.h"

using namespace sender;

namespace {

Command parse(const char* s) { return parseCommand(s, std::strlen(s)); }

/// LineAssembler に文字列を流し込み、完成した行を '|' 区切りで返す（あふれは "<OVF>"）。
std::string feed(LineAssembler& a, const std::string& input) {
  std::string out;
  for (char c : input) {
    switch (a.push(c)) {
      case LineAssembler::Result::kLine:
        out += std::string(a.line(), a.length()) + "|";
        break;
      case LineAssembler::Result::kOverflow:
        out += "<OVF>|";
        break;
      case LineAssembler::Result::kNone:
        break;
    }
  }
  return out;
}

/// TxQueue を MTU に合わせて全部吐き出し、各通知を返す。受信側の組み立ても確認できる。
std::string drain(TxQueue& q, size_t payload, int* notify_count = nullptr) {
  std::string all;
  int count = 0;
  while (!q.empty()) {
    const size_t n = nextChunkLength(q.data(), q.size(), payload);
    TEST_ASSERT_TRUE(n > 0);
    TEST_ASSERT_TRUE(n <= payload);
    all.append(q.data(), n);
    q.consume(n);
    ++count;
  }
  if (notify_count) *notify_count = count;
  return all;
}

}  // namespace

void setUp() {}
void tearDown() {}

// ------------------------------------------------------------
// コマンド解析
// ------------------------------------------------------------

void test_parse_simple_commands() {
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kPause), static_cast<int>(parse("PAUSE").type));
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kResume), static_cast<int>(parse("resume").type));
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kInfo), static_cast<int>(parse("Info").type));
  // 前後の空白・CR は無視
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kPause),
                    static_cast<int>(parse("  pause \r").type));
}

void test_parse_empty_and_comment_are_ignored() {
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kNone), static_cast<int>(parse("").type));
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kNone), static_cast<int>(parse("   \t").type));
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kNone),
                    static_cast<int>(parse("# model=M5StickCPlus2").type));
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kNone),
                    static_cast<int>(parseCommand(nullptr, 3).type));
}

void test_parse_rate_valid() {
  Command c = parse("RATE 50");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kRate), static_cast<int>(c.type));
  TEST_ASSERT_EQUAL(50, c.rate_hz);

  c = parse("rate\t\t200");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kRate), static_cast<int>(c.type));
  TEST_ASSERT_EQUAL(200, c.rate_hz);

  c = parse("Rate 10");
  TEST_ASSERT_EQUAL(10, c.rate_hz);

  c = parse("RATE 0100");  // 先頭ゼロは許可
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kRate), static_cast<int>(c.type));
  TEST_ASSERT_EQUAL(100, c.rate_hz);
}

void test_parse_rate_errors() {
  Command c = parse("RATE");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandType::kError), static_cast<int>(c.type));
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kRateMissing), static_cast<int>(c.error));

  c = parse("RATE 9");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kRateOutOfRange), static_cast<int>(c.error));
  TEST_ASSERT_EQUAL(9, c.rate_hz);

  c = parse("RATE 201");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kRateOutOfRange), static_cast<int>(c.error));
  TEST_ASSERT_EQUAL(201, c.rate_hz);

  c = parse("RATE 0");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kRateOutOfRange), static_cast<int>(c.error));

  // 桁あふれしない（大きすぎる値は 999999 に丸めて範囲外扱い）
  c = parse("RATE 99999999999999999999");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kRateOutOfRange), static_cast<int>(c.error));
  TEST_ASSERT_EQUAL(999999, c.rate_hz);

  const char* not_numbers[] = {"RATE -50", "RATE +50", "RATE 50.5", "RATE abc", "RATE 0x20",
                               "RATE 5O"};
  for (const char* s : not_numbers) {
    c = parse(s);
    TEST_ASSERT_EQUAL_MESSAGE(static_cast<int>(CommandError::kRateNotNumber),
                              static_cast<int>(c.error), s);
  }

  c = parse("RATE 50 60");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kUnexpectedArgument), static_cast<int>(c.error));
}

void test_parse_unknown_and_extra_args() {
  Command c = parse("HELLO");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kUnknownCommand), static_cast<int>(c.error));
  c = parse("PAUSED");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kUnknownCommand), static_cast<int>(c.error));
  c = parse("RATE=50");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kUnknownCommand), static_cast<int>(c.error));
  c = parse("PAUSE now");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kUnexpectedArgument), static_cast<int>(c.error));
  c = parse("INFO 1 2 3 4");
  TEST_ASSERT_EQUAL(static_cast<int>(CommandError::kUnexpectedArgument), static_cast<int>(c.error));
}

void test_format_command_error_lines() {
  char buf[160];
  Command c = parse("RATE 5");
  size_t n = formatCommandError(buf, sizeof(buf), c);
  TEST_ASSERT_EQUAL_STRING("# error=rate_out_of_range value=5 min=10 max=200\n", buf);
  TEST_ASSERT_EQUAL(std::strlen(buf), n);

  c = parse("FOO");
  formatCommandError(buf, sizeof(buf), c);
  TEST_ASSERT_EQUAL_STRING("# error=unknown_command commands=PAUSE,RESUME,RATE,INFO\n", buf);

  c = parse("RATE x");
  formatCommandError(buf, sizeof(buf), c);
  TEST_ASSERT_EQUAL_STRING("# error=rate_not_number min=10 max=200\n", buf);

  Command too_long;
  too_long.type = CommandType::kError;
  too_long.error = CommandError::kLineTooLong;
  formatCommandError(buf, sizeof(buf), too_long);
  TEST_ASSERT_EQUAL_STRING("# error=line_too_long max=64\n", buf);
}

// ------------------------------------------------------------
// LineAssembler
// ------------------------------------------------------------

void test_line_assembler_basic() {
  LineAssembler a;
  TEST_ASSERT_EQUAL_STRING("PAUSE|RATE 50|", feed(a, "PAUSE\nRATE 50\n").c_str());
  // CRLF・CR のみ・空行
  TEST_ASSERT_EQUAL_STRING("INFO|RESUME|", feed(a, "INFO\r\n\r\n\nRESUME\r").c_str());
  // 分割して届いても組み立てられる
  TEST_ASSERT_EQUAL_STRING("", feed(a, "RA").c_str());
  TEST_ASSERT_EQUAL_STRING("", feed(a, "TE 1").c_str());
  TEST_ASSERT_EQUAL_STRING("RATE 100|", feed(a, "00\n").c_str());
}

void test_line_assembler_overflow() {
  LineAssembler a;
  const std::string exact(kMaxCommandLength, 'A');
  TEST_ASSERT_EQUAL_STRING((exact + "|").c_str(), feed(a, exact + "\n").c_str());

  const std::string too_long(kMaxCommandLength + 1, 'B');
  TEST_ASSERT_EQUAL_STRING("<OVF>|", feed(a, too_long + "\n").c_str());
  // あふれの後も次の行は正常に読める
  TEST_ASSERT_EQUAL_STRING("INFO|", feed(a, "INFO\n").c_str());
  // とても長い行でもあふれ通知は 1 回だけ
  TEST_ASSERT_EQUAL_STRING("<OVF>|PAUSE|",
                           feed(a, std::string(500, 'C') + "\nPAUSE\n").c_str());
}

// ------------------------------------------------------------
// 整形
// ------------------------------------------------------------

void test_format_sample() {
  char buf[160];
  size_t n = formatSample(buf, sizeof(buf), 0.021f, 0.9832f, -0.0104f, 12.4f, -3.1f, 0.8f);
  TEST_ASSERT_EQUAL_STRING("0.0210,0.9832,-0.0104,12.400,-3.100,0.800\n", buf);
  TEST_ASSERT_EQUAL(std::strlen(buf), n);

  // 最大級の値でも 1 行に収まり、末尾は改行
  n = formatSample(buf, sizeof(buf), -16.0f, -16.0f, -16.0f, -2000.0f, -2000.0f, -2000.0f);
  TEST_ASSERT_EQUAL_STRING("-16.0000,-16.0000,-16.0000,-2000.000,-2000.000,-2000.000\n", buf);
  TEST_ASSERT_TRUE(n < 64);

  // 非有限値は送らない
  TEST_ASSERT_EQUAL(0, formatSample(buf, sizeof(buf), 0, 0, 0, 0, 0, NAN));
  // バッファ不足は 0
  TEST_ASSERT_EQUAL(0, formatSample(buf, 10, 0, 0, 0, 0, 0, 0));
}

void test_format_device_name() {
  char buf[24];
  const uint8_t mac[6] = {0x24, 0x0a, 0xc4, 0x12, 0x1a, 0x2b};
  formatDeviceName(buf, sizeof(buf), mac);
  TEST_ASSERT_EQUAL_STRING("M5-Sensor-1A2B", buf);
  // スキャン応答（31 バイト）に入る長さ: 2 + 14 = 16
  TEST_ASSERT_EQUAL(14, std::strlen(buf));
}

void test_format_info_line() {
  char buf[160];
  DeviceInfo info;
  info.model = "M5StickCPlus2";
  info.name = "M5-Sensor-1A2B";
  info.imu = "MPU6886";
  info.rate_hz = 100;
  info.ble_available = true;
  info.sending = true;
  info.ble_connected = false;
  formatInfoLine(buf, sizeof(buf), info);
  TEST_ASSERT_EQUAL_STRING(
      "# model=M5StickCPlus2 name=M5-Sensor-1A2B rate=100 ble=1 fw=2.0.0 imu=MPU6886 "
      "sending=1 connected=0 drop_usb=0 drop_ble=0\n",
      buf);
}

// ------------------------------------------------------------
// BLE 分割送信
// ------------------------------------------------------------

void test_ble_payload_size() {
  TEST_ASSERT_EQUAL(20, blePayloadSize(23));
  TEST_ASSERT_EQUAL(20, blePayloadSize(0));
  TEST_ASSERT_EQUAL(182, blePayloadSize(185));
  TEST_ASSERT_EQUAL(244, blePayloadSize(247));
  TEST_ASSERT_EQUAL(244, blePayloadSize(512));
}

void test_next_chunk_length() {
  const char* two = "abc\ndefg\n";
  TEST_ASSERT_EQUAL(9, nextChunkLength(two, 9, 20));  // 全部入る
  TEST_ASSERT_EQUAL(4, nextChunkLength(two, 9, 8));   // 改行で切る
  TEST_ASSERT_EQUAL(4, nextChunkLength(two, 9, 4));   // ちょうど改行まで
  TEST_ASSERT_EQUAL(3, nextChunkLength(two, 9, 3));   // 行の途中で切るしかない
  TEST_ASSERT_EQUAL(0, nextChunkLength(two, 0, 20));
  TEST_ASSERT_EQUAL(0, nextChunkLength(two, 9, 0));
}

void test_tx_queue_split_and_reassemble_mtu23() {
  // MTU 23（20 バイト）では 1 行が複数通知に分かれるが、つなげると元に戻る。
  TxQueue q;
  const std::string l1 = "0.0210,0.9832,-0.0104,12.400,-3.100,0.800\n";
  const std::string l2 = "-16.0000,-16.0000,-16.0000,-2000.000,-2000.000,-2000.000\n";
  TEST_ASSERT_TRUE(q.pushLine(l1.c_str(), l1.size()));
  TEST_ASSERT_TRUE(q.pushLine(l2.c_str(), l2.size()));
  int notifies = 0;
  const std::string out = drain(q, blePayloadSize(23), &notifies);
  TEST_ASSERT_EQUAL_STRING((l1 + l2).c_str(), out.c_str());
  TEST_ASSERT_TRUE(notifies >= 6);
}

void test_tx_queue_batches_whole_lines_large_mtu() {
  // MTU 185（182 バイト）なら、行を分割せずに複数行をまとめて送る。
  TxQueue q;
  const std::string line = "0.0210,0.9832,-0.0104,12.400,-3.100,0.800\n";  // 42 バイト
  for (int i = 0; i < 10; ++i) TEST_ASSERT_TRUE(q.pushLine(line.c_str(), line.size()));
  std::string all;
  while (!q.empty()) {
    const size_t n = nextChunkLength(q.data(), q.size(), blePayloadSize(185));
    TEST_ASSERT_EQUAL('\n', q.data()[n - 1]);  // どの通知も行の終わりで切れている
    all.append(q.data(), n);
    q.consume(n);
  }
  std::string expected;
  for (int i = 0; i < 10; ++i) expected += line;
  TEST_ASSERT_EQUAL_STRING(expected.c_str(), all.c_str());
}

void test_tx_queue_rejects_bad_lines() {
  TxQueue q;
  TEST_ASSERT_FALSE(q.pushLine("no newline", 10));
  const std::string huge(TxQueue::kCapacity + 1, 'x');
  TEST_ASSERT_FALSE(q.pushLine(huge.c_str(), huge.size()));
  TEST_ASSERT_TRUE(q.empty());
}

void test_tx_queue_drops_oldest_when_full() {
  TxQueue q;
  // 10 バイトの行で満杯にする
  char line[11];
  const int total = static_cast<int>(TxQueue::kCapacity / 10);
  for (int i = 0; i < total; ++i) {
    std::snprintf(line, sizeof(line), "%08d,\n", i);
    TEST_ASSERT_TRUE(q.pushLine(line, 10));
  }
  TEST_ASSERT_EQUAL(0u, q.droppedLines());
  // さらに 1 行入れると、最も古い行が捨てられる
  std::snprintf(line, sizeof(line), "%08d,\n", 99999);
  TEST_ASSERT_TRUE(q.pushLine(line, 10));
  TEST_ASSERT_TRUE(q.droppedLines() >= 1u);
  TEST_ASSERT_EQUAL(0, std::strncmp(q.data(), "00000001,\n", 10));
  // 末尾は新しい行
  TEST_ASSERT_EQUAL(0, std::strncmp(q.data() + q.size() - 10, "00099999,\n", 10));
}

void test_tx_queue_keeps_partially_sent_head_line() {
  // 先頭行を途中まで送った状態で満杯になっても、先頭行の残りは捨てない（受信側で行が壊れない）。
  TxQueue q;
  const std::string a = "AAAAAAAAA\n";  // 10 バイト
  char line[11];
  TEST_ASSERT_TRUE(q.pushLine(a.c_str(), a.size()));
  q.consume(4);  // "AAAA" を送信済み
  TEST_ASSERT_TRUE(q.headIsPartial());
  const int fill = static_cast<int>((TxQueue::kCapacity - q.size()) / 10);
  for (int i = 0; i < fill; ++i) {
    std::snprintf(line, sizeof(line), "%08d,\n", i);
    TEST_ASSERT_TRUE(q.pushLine(line, 10));
  }
  std::snprintf(line, sizeof(line), "%08d,\n", 77777);
  TEST_ASSERT_TRUE(q.pushLine(line, 10));
  // 先頭は送りかけの行の残り、その次に捨てられずに残った行が続く
  TEST_ASSERT_EQUAL(0, std::strncmp(q.data(), "AAAAA\n", 6));
  TEST_ASSERT_EQUAL(0, std::strncmp(q.data() + 6, "00000001,\n", 10));

  // 受信側の組み立て: 送信済み "AAAA" + 残り → すべて正しい行になる
  std::string received = "AAAA" + drain(q, 20);
  size_t start = 0;
  int lines = 0;
  while (start < received.size()) {
    const size_t nl = received.find('\n', start);
    TEST_ASSERT_TRUE(nl != std::string::npos);
    const std::string l = received.substr(start, nl - start);
    TEST_ASSERT_TRUE(l == "AAAAAAAAA" || (l.size() == 9 && l[8] == ','));
    start = nl + 1;
    ++lines;
  }
  TEST_ASSERT_TRUE(lines > 100);
}

void test_tx_queue_clear() {
  TxQueue q;
  q.pushLine("abc\n", 4);
  q.consume(2);
  q.clear();
  TEST_ASSERT_TRUE(q.empty());
  TEST_ASSERT_FALSE(q.headIsPartial());
}

// ------------------------------------------------------------
// RateScheduler
// ------------------------------------------------------------

/// [from, to) の各ミリ秒で poll() を呼び、送信回数を数える。
int countSends(RateScheduler& s, uint32_t from, uint32_t to) {
  int n = 0;
  for (uint32_t t = from; t != to; ++t) {
    while (s.poll(t)) ++n;  // 同じ時刻に複数回送ることもある（追いつき）
  }
  return n;
}

void test_scheduler_exact_rate_no_drift() {
  const int rates[] = {10, 30, 60, 100, 120, 200};
  for (int r : rates) {
    RateScheduler s;
    s.start(0, r);
    // 10 秒間で送る回数はぴったり r*10（1000/r が割り切れないレートでもずれない）
    const int sends = countSends(s, 0, 10000);
    TEST_ASSERT_EQUAL_MESSAGE(r * 10, sends, "rate");
    TEST_ASSERT_EQUAL(0u, s.resyncCount());
  }
}

void test_scheduler_millis_wraparound() {
  RateScheduler s;
  const uint32_t start = 0xFFFFFFFFu - 500u;  // 0.5 秒後に millis() が 0 に戻る
  s.start(start, 100);
  const int sends = countSends(s, start, start + 2000u);
  TEST_ASSERT_EQUAL(200, sends);
}

void test_scheduler_small_lag_catches_up() {
  RateScheduler s;
  s.start(0, 100);
  TEST_ASSERT_TRUE(s.poll(0));
  // 50ms 止まった（< kMaxLagMs）→ 溜まった 5 回分を続けて送って追いつく
  int burst = 0;
  while (s.poll(50)) ++burst;
  TEST_ASSERT_EQUAL(5, burst);
  TEST_ASSERT_FALSE(s.poll(55));
  TEST_ASSERT_TRUE(s.poll(60));
  TEST_ASSERT_EQUAL(0u, s.resyncCount());
}

void test_scheduler_large_lag_resyncs() {
  RateScheduler s;
  s.start(0, 100);
  TEST_ASSERT_TRUE(s.poll(0));
  // 500ms 止まった（> kMaxLagMs）→ まとめ送りせず 1 回だけ送って起点を取り直す
  int burst = 0;
  while (s.poll(500)) ++burst;
  TEST_ASSERT_EQUAL(1, burst);
  TEST_ASSERT_EQUAL(1u, s.resyncCount());
  TEST_ASSERT_FALSE(s.poll(509));
  TEST_ASSERT_TRUE(s.poll(510));
}

void test_scheduler_clamps_rate() {
  RateScheduler s;
  s.start(0, 5);
  TEST_ASSERT_EQUAL(kRateMinHz, s.rateHz());
  s.start(0, 1000);
  TEST_ASSERT_EQUAL(kRateMaxHz, s.rateHz());
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_parse_simple_commands);
  RUN_TEST(test_parse_empty_and_comment_are_ignored);
  RUN_TEST(test_parse_rate_valid);
  RUN_TEST(test_parse_rate_errors);
  RUN_TEST(test_parse_unknown_and_extra_args);
  RUN_TEST(test_format_command_error_lines);
  RUN_TEST(test_line_assembler_basic);
  RUN_TEST(test_line_assembler_overflow);
  RUN_TEST(test_format_sample);
  RUN_TEST(test_format_device_name);
  RUN_TEST(test_format_info_line);
  RUN_TEST(test_ble_payload_size);
  RUN_TEST(test_next_chunk_length);
  RUN_TEST(test_tx_queue_split_and_reassemble_mtu23);
  RUN_TEST(test_tx_queue_batches_whole_lines_large_mtu);
  RUN_TEST(test_tx_queue_rejects_bad_lines);
  RUN_TEST(test_tx_queue_drops_oldest_when_full);
  RUN_TEST(test_tx_queue_keeps_partially_sent_head_line);
  RUN_TEST(test_tx_queue_clear);
  RUN_TEST(test_scheduler_exact_rate_no_drift);
  RUN_TEST(test_scheduler_millis_wraparound);
  RUN_TEST(test_scheduler_small_lag_catches_up);
  RUN_TEST(test_scheduler_large_lag_resyncs);
  RUN_TEST(test_scheduler_clamps_rate);
  return UNITY_END();
}
