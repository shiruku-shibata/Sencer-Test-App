#include "sender_core.h"

#include <cmath>
#include <cstdio>
#include <cstring>

namespace sender {
namespace {

bool isSpace(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

char toUpperAscii(char c) { return (c >= 'a' && c <= 'z') ? static_cast<char>(c - 'a' + 'A') : c; }

/// [p, end) の単語が word（大文字）と大文字小文字を無視して一致するか。
bool tokenEquals(const char* p, const char* end, const char* word) {
  const size_t n = static_cast<size_t>(end - p);
  if (std::strlen(word) != n) return false;
  for (size_t i = 0; i < n; ++i) {
    if (toUpperAscii(p[i]) != word[i]) return false;
  }
  return true;
}

/// 文字列を空白区切りの単語に分ける（最大 max_tokens 個。それより多ければ count は max+1）。
struct Tokens {
  static constexpr size_t kMax = 3;
  const char* begin[kMax] = {};
  const char* end[kMax] = {};
  size_t count = 0;
};

Tokens tokenize(const char* line, size_t len) {
  Tokens t;
  size_t i = 0;
  while (i < len) {
    while (i < len && isSpace(line[i])) ++i;
    if (i >= len) break;
    const size_t start = i;
    while (i < len && !isSpace(line[i])) ++i;
    if (t.count < Tokens::kMax) {
      t.begin[t.count] = line + start;
      t.end[t.count] = line + i;
    }
    ++t.count;
  }
  return t;
}

Command makeError(CommandError e, int32_t rate = 0) {
  Command c;
  c.type = CommandType::kError;
  c.error = e;
  c.rate_hz = rate;
  return c;
}

Command parseRate(const Tokens& t) {
  if (t.count < 2) return makeError(CommandError::kRateMissing);
  if (t.count > 2) return makeError(CommandError::kUnexpectedArgument);

  const char* p = t.begin[1];
  const char* end = t.end[1];
  // 10進の正の整数のみ（符号・小数点・16進は受け付けない）。
  int32_t value = 0;
  bool overflow = false;
  for (const char* q = p; q < end; ++q) {
    if (*q < '0' || *q > '9') return makeError(CommandError::kRateNotNumber);
    if (!overflow) {
      value = value * 10 + (*q - '0');
      if (value > 999999) overflow = true;
    }
  }
  if (overflow) value = 999999;
  if (value < kRateMinHz || value > kRateMaxHz) {
    return makeError(CommandError::kRateOutOfRange, value);
  }
  Command c;
  c.type = CommandType::kRate;
  c.rate_hz = value;
  return c;
}

/// snprintf の結果を「書けた長さ／入らなければ 0」に直す。
size_t finish(int written, size_t cap) {
  if (written < 0 || static_cast<size_t>(written) >= cap) return 0;
  return static_cast<size_t>(written);
}

}  // namespace

// ------------------------------------------------------------
// コマンド解析
// ------------------------------------------------------------

Command parseCommand(const char* line, size_t len) {
  if (line == nullptr || len == 0) return Command{};

  // 先頭の空白を飛ばして、空行・コメント行（# 始まり）は無視する。
  size_t i = 0;
  while (i < len && isSpace(line[i])) ++i;
  if (i >= len || line[i] == '#') return Command{};

  const Tokens t = tokenize(line, len);
  if (t.count == 0) return Command{};

  const char* cmd = t.begin[0];
  const char* cmd_end = t.end[0];

  CommandType simple = CommandType::kNone;
  if (tokenEquals(cmd, cmd_end, "PAUSE")) {
    simple = CommandType::kPause;
  } else if (tokenEquals(cmd, cmd_end, "RESUME")) {
    simple = CommandType::kResume;
  } else if (tokenEquals(cmd, cmd_end, "INFO")) {
    simple = CommandType::kInfo;
  } else if (tokenEquals(cmd, cmd_end, "RATE")) {
    return parseRate(t);
  } else {
    return makeError(CommandError::kUnknownCommand);
  }

  if (t.count > 1) return makeError(CommandError::kUnexpectedArgument);
  Command c;
  c.type = simple;
  return c;
}

const char* commandErrorName(CommandError error) {
  switch (error) {
    case CommandError::kNone: return "none";
    case CommandError::kUnknownCommand: return "unknown_command";
    case CommandError::kUnexpectedArgument: return "unexpected_argument";
    case CommandError::kRateMissing: return "rate_missing";
    case CommandError::kRateNotNumber: return "rate_not_number";
    case CommandError::kRateOutOfRange: return "rate_out_of_range";
    case CommandError::kLineTooLong: return "line_too_long";
  }
  return "unknown";
}

// ------------------------------------------------------------
// LineAssembler
// ------------------------------------------------------------

LineAssembler::Result LineAssembler::push(char c) {
  if (line_ready_) {
    // 前回返した行は使い終わったものとして捨てる。
    line_ready_ = false;
    len_ = 0;
    buf_[0] = '\0';
  }

  if (c == '\n' || c == '\r') {
    if (discarding_) {
      discarding_ = false;
      len_ = 0;
      buf_[0] = '\0';
      return Result::kOverflow;
    }
    if (len_ == 0) return Result::kNone;  // 空行（CRLF の LF など）は無視
    buf_[len_] = '\0';
    line_ready_ = true;
    return Result::kLine;
  }

  if (c == '\0' || discarding_) return Result::kNone;

  if (len_ >= kMaxCommandLength) {
    // 長すぎる行。改行が来るまで読み捨てる。
    discarding_ = true;
    len_ = 0;
    buf_[0] = '\0';
    return Result::kNone;
  }
  buf_[len_++] = c;
  return Result::kNone;
}

void LineAssembler::reset() {
  len_ = 0;
  buf_[0] = '\0';
  line_ready_ = false;
  discarding_ = false;
}

// ------------------------------------------------------------
// 整形
// ------------------------------------------------------------

size_t formatSample(char* out, size_t cap, float ax, float ay, float az, float gx, float gy,
                    float gz) {
  if (out == nullptr || cap == 0) return 0;
  const float v[6] = {ax, ay, az, gx, gy, gz};
  for (float x : v) {
    if (!std::isfinite(x)) return 0;
  }
  const int n = std::snprintf(out, cap, "%.4f,%.4f,%.4f,%.3f,%.3f,%.3f\n",
                              static_cast<double>(ax), static_cast<double>(ay),
                              static_cast<double>(az), static_cast<double>(gx),
                              static_cast<double>(gy), static_cast<double>(gz));
  return finish(n, cap);
}

size_t formatDeviceName(char* out, size_t cap, const uint8_t mac[6]) {
  if (out == nullptr || cap == 0 || mac == nullptr) return 0;
  const int n = std::snprintf(out, cap, "M5-Sensor-%02X%02X", static_cast<unsigned>(mac[4]),
                              static_cast<unsigned>(mac[5]));
  return finish(n, cap);
}

size_t formatInfoLine(char* out, size_t cap, const DeviceInfo& info) {
  if (out == nullptr || cap == 0) return 0;
  const int n = std::snprintf(
      out, cap, "# model=%s name=%s rate=%d ble=%d fw=%s imu=%s sending=%d connected=%d "
      "drop_usb=%lu drop_ble=%lu\n",
      info.model ? info.model : "Unknown", info.name ? info.name : "", info.rate_hz,
      info.ble_available ? 1 : 0, kFirmwareVersion, info.imu ? info.imu : "none",
      info.sending ? 1 : 0, info.ble_connected ? 1 : 0,
      static_cast<unsigned long>(info.dropped_usb), static_cast<unsigned long>(info.dropped_ble));
  return finish(n, cap);
}

size_t formatCommandError(char* out, size_t cap, const Command& cmd) {
  if (out == nullptr || cap == 0) return 0;
  const char* name = commandErrorName(cmd.error);
  int n = 0;
  switch (cmd.error) {
    case CommandError::kRateOutOfRange:
      n = std::snprintf(out, cap, "# error=%s value=%ld min=%d max=%d\n", name,
                        static_cast<long>(cmd.rate_hz), kRateMinHz, kRateMaxHz);
      break;
    case CommandError::kRateMissing:
    case CommandError::kRateNotNumber:
      n = std::snprintf(out, cap, "# error=%s min=%d max=%d\n", name, kRateMinHz,
                        kRateMaxHz);
      break;
    case CommandError::kLineTooLong:
      n = std::snprintf(out, cap, "# error=%s max=%u\n", name,
                        static_cast<unsigned>(kMaxCommandLength));
      break;
    case CommandError::kUnknownCommand:
    case CommandError::kUnexpectedArgument:
      n = std::snprintf(out, cap, "# error=%s commands=PAUSE,RESUME,RATE,INFO\n", name);
      break;
    case CommandError::kNone:
    default:
      n = std::snprintf(out, cap, "# error=%s\n", name);
      break;
  }
  return finish(n, cap);
}

// ------------------------------------------------------------
// BLE 送信
// ------------------------------------------------------------

size_t blePayloadSize(uint16_t mtu) {
  // ATT ヘッダ（opcode 1 + handle 2）の 3 バイトを引く。
  // 最小 MTU は 23（= 20 バイト）。大きすぎる通知はコントローラ側で分割が必要になるので 244 で止める。
  size_t payload = (mtu > 3) ? static_cast<size_t>(mtu) - 3 : 0;
  if (payload < 20) payload = 20;
  if (payload > 244) payload = 244;
  return payload;
}

size_t nextChunkLength(const char* data, size_t len, size_t max_payload) {
  if (data == nullptr || len == 0 || max_payload == 0) return 0;
  if (len <= max_payload) return len;
  for (size_t i = max_payload; i > 0; --i) {
    if (data[i - 1] == '\n') return i;
  }
  return max_payload;
}

bool TxQueue::dropOneLine() {
  // 途中まで送った先頭行は残し、その次の行から捨てる。
  size_t start = 0;
  if (head_partial_) {
    const void* nl = std::memchr(buf_, '\n', size_);
    if (nl == nullptr) return false;
    start = static_cast<size_t>(static_cast<const char*>(nl) - buf_) + 1;
  }
  if (start >= size_) return false;
  const void* nl = std::memchr(buf_ + start, '\n', size_ - start);
  // キューには行単位でしか入れないので必ず見つかるが、念のため末尾まで捨てる。
  const size_t end = nl ? static_cast<size_t>(static_cast<const char*>(nl) - buf_) + 1 : size_;
  std::memmove(buf_ + start, buf_ + end, size_ - end);
  size_ -= (end - start);
  ++dropped_;
  return true;
}

bool TxQueue::pushLine(const char* line, size_t len) {
  if (line == nullptr || len == 0) return true;
  if (len > kCapacity || line[len - 1] != '\n') {
    ++dropped_;
    return false;
  }
  while (kCapacity - size_ < len) {
    if (!dropOneLine()) {
      ++dropped_;
      return false;
    }
  }
  std::memcpy(buf_ + size_, line, len);
  size_ += len;
  return true;
}

void TxQueue::consume(size_t n) {
  if (n == 0) return;
  if (n >= size_) {
    size_ = 0;
    head_partial_ = false;
    return;
  }
  head_partial_ = (buf_[n - 1] != '\n');
  std::memmove(buf_, buf_ + n, size_ - n);
  size_ -= n;
}

void TxQueue::clear() {
  size_ = 0;
  head_partial_ = false;
}

// ------------------------------------------------------------
// RateScheduler
// ------------------------------------------------------------

void RateScheduler::start(uint32_t now_ms, int rate_hz) {
  if (rate_hz < kRateMinHz) rate_hz = kRateMinHz;
  if (rate_hz > kRateMaxHz) rate_hz = kRateMaxHz;
  rate_hz_ = rate_hz;
  origin_ms_ = now_ms;
  index_ = 0;
}

uint32_t RateScheduler::dueTime() const {
  return origin_ms_ + (index_ * 1000u) / static_cast<uint32_t>(rate_hz_);
}

bool RateScheduler::poll(uint32_t now_ms) {
  const int32_t late = static_cast<int32_t>(now_ms - dueTime());
  if (late < 0) return false;
  if (static_cast<uint32_t>(late) > kMaxLagMs) {
    // 大きく遅れた：溜まった分は捨てて、今を起点に取り直す。
    origin_ms_ = now_ms;
    index_ = 0;
    ++resyncs_;
  }
  // 次の予定へ。1秒分進んだら起点を 1000ms 進めて index を小さく保つ（桁あふれ防止）。
  ++index_;
  if (index_ >= static_cast<uint32_t>(rate_hz_)) {
    index_ = 0;
    origin_ms_ += 1000u;
  }
  return true;
}

}  // namespace sender
