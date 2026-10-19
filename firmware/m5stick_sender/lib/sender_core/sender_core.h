/*
 * sender_core - 送信ファームウェアの「ハードウェアに依存しない」部品
 *
 * ここには Arduino / M5Unified / NimBLE のヘッダを一切 include しない。
 * そのため PC 上でもコンパイルでき、`pio test -e native` で単体テストできる。
 *
 *   - コマンド解析      : parseCommand()          （PAUSE / RESUME / RATE <Hz> / INFO）
 *   - 受信行の組み立て  : LineAssembler           （1文字ずつ入れて改行で1行にする）
 *   - 出力行の整形      : formatSample() など      （CSV 行・情報行）
 *   - BLE 送信キュー    : TxQueue / nextChunkLength（行単位で溜めて MTU に合わせて切り出す）
 *   - 送信タイミング    : RateScheduler           （millis ベースでドリフトしない一定間隔）
 *
 * 通信仕様（アプリとの契約）は docs/DESIGN_P2.md の 5.6 を参照。
 */
#pragma once

#include <cstddef>
#include <cstdint>

namespace sender {

/// ファームウェアのバージョン（INFO 行の fw= に出る）。
constexpr const char* kFirmwareVersion = "2.0.0";

/// 送信レートの範囲 [Hz]。
constexpr int kRateMinHz = 10;
constexpr int kRateMaxHz = 200;
constexpr int kRateDefaultHz = 100;

/// 受け付けるコマンド1行の最大長（改行を除く）。これを超えた行は破棄してエラーを返す。
constexpr size_t kMaxCommandLength = 64;

/// 送信する1行（CSV/情報行）の最大長の目安。バッファサイズに使う。
constexpr size_t kMaxLineLength = 192;

// ------------------------------------------------------------
// コマンド解析
// ------------------------------------------------------------

enum class CommandType : uint8_t {
  kNone,    ///< 空行・コメント行（# 始まり）。何もしない（応答も返さない）
  kPause,   ///< 送信を一時停止
  kResume,  ///< 送信を再開
  kRate,    ///< 送信レート変更（rate_hz に値）
  kInfo,    ///< 情報行を返す
  kError,   ///< 解析エラー（error に理由）
};

enum class CommandError : uint8_t {
  kNone,
  kUnknownCommand,      ///< 知らないコマンド
  kUnexpectedArgument,  ///< 引数を取らないコマンドに引数が付いている／引数が多すぎる
  kRateMissing,         ///< RATE の後に数値が無い
  kRateNotNumber,       ///< RATE の引数が整数でない
  kRateOutOfRange,      ///< RATE の値が範囲外（rate_hz に値。大きすぎる値は 999999 に丸める）
  kLineTooLong,         ///< 1行が kMaxCommandLength を超えた（LineAssembler が検出）
};

struct Command {
  CommandType type = CommandType::kNone;
  CommandError error = CommandError::kNone;
  int32_t rate_hz = 0;
};

/// 1行（改行を含まない）をコマンドとして解析する。大文字小文字は区別しない。
/// 前後の空白・タブ・CR は無視する。単語の区切りは空白またはタブ（連続可）。
Command parseCommand(const char* line, size_t len);

/// エラー種別をエラー行に使う名前（例 "rate_out_of_range"）にする。
const char* commandErrorName(CommandError error);

// ------------------------------------------------------------
// 受信した文字列を改行ごとの1行に組み立てる
// ------------------------------------------------------------

class LineAssembler {
 public:
  enum class Result : uint8_t {
    kNone,      ///< まだ行が完成していない
    kLine,      ///< 1行完成。line() / length() で取得（次の push() までは有効）
    kOverflow,  ///< 長すぎる行を破棄した（改行を受けた時点で1回だけ通知）
  };

  /// 1文字入れる。'\n' と '\r' はどちらも行の終わりとして扱う（CRLF でも空行は出ない）。
  Result push(char c);
  const char* line() const { return buf_; }
  size_t length() const { return len_; }
  void reset();

 private:
  char buf_[kMaxCommandLength + 1] = {};
  size_t len_ = 0;
  bool line_ready_ = false;
  bool discarding_ = false;
};

// ------------------------------------------------------------
// 出力行の整形（すべて末尾に '\n' を付け、書いた長さを返す。入らなければ 0）
// ------------------------------------------------------------

/// CSV のサンプル行 "ax,ay,az,gx,gy,gz\n"（加速度 G は小数4桁、ジャイロ deg/s は小数3桁）。
/// 非有限値（NaN/Inf）が含まれる場合は 0 を返す（壊れた行を送らない）。
size_t formatSample(char* out, size_t cap, float ax, float ay, float az, float gx, float gy,
                    float gz);

/// MAC アドレスからデバイス名 "M5-Sensor-XXXX"（下位2バイトの16進大文字）を作る。
size_t formatDeviceName(char* out, size_t cap, const uint8_t mac[6]);

struct DeviceInfo {
  const char* model = "Unknown";  ///< 機種名（空白を含まないこと）
  const char* name = "";          ///< BLE デバイス名
  const char* imu = "none";       ///< IMU の種類
  int rate_hz = kRateDefaultHz;
  bool ble_available = true;
  bool sending = true;
  bool ble_connected = false;
  uint32_t dropped_usb = 0;  ///< USB シリアルの送信バッファが足りずに捨てた行数
  uint32_t dropped_ble = 0;  ///< BLE の送信キューがあふれて捨てた行数
};

/// 情報行
/// "# model=... name=... rate=100 ble=1 fw=2.0.0 imu=... sending=1 connected=0 drop_usb=0 drop_ble=0\n"
size_t formatInfoLine(char* out, size_t cap, const DeviceInfo& info);

/// コマンドのエラー行 "# error=<name> ...\n"。
size_t formatCommandError(char* out, size_t cap, const Command& cmd);

// ------------------------------------------------------------
// BLE 送信
// ------------------------------------------------------------

/// ATT MTU から1通知に載せられるデータ長を求める（MTU - 3。範囲は 20〜244 に収める）。
size_t blePayloadSize(uint16_t mtu);

/// 送信待ちデータ data[0..len) の先頭から、1通知で送る長さを決める。
///   - 全部が max_payload 以内ならそのまま全部。
///   - 収まらなければ、max_payload 以内の最後の改行までを送る（行をなるべく分割しない）。
///   - 1行が max_payload より長い場合だけ、行の途中で切る（受信側が改行で組み立てる契約）。
size_t nextChunkLength(const char* data, size_t len, size_t max_payload);

/// BLE に送る行を溜めておくキュー。必ず「行単位」で入れる。
/// いっぱいのときは古い行から捨てて新しい行を入れる（表示の遅れより鮮度を優先）。
/// ただし、途中まで送ってしまった先頭行は捨てない（受信側で行が壊れないように）。
class TxQueue {
 public:
  static constexpr size_t kCapacity = 2048;

  /// 1行（末尾 '\n' 込み）を追加する。入らなかった場合は false。
  bool pushLine(const char* line, size_t len);
  const char* data() const { return buf_; }
  size_t size() const { return size_; }
  bool empty() const { return size_ == 0; }
  /// 先頭から n バイトを送信済みとして取り除く。
  void consume(size_t n);
  void clear();
  /// 容量不足で捨てた行の累計。
  uint32_t droppedLines() const { return dropped_; }
  /// 先頭の行が途中まで送信済みか。
  bool headIsPartial() const { return head_partial_; }

 private:
  bool dropOneLine();

  char buf_[kCapacity] = {};
  size_t size_ = 0;
  bool head_partial_ = false;
  uint32_t dropped_ = 0;
};

// ------------------------------------------------------------
// 送信タイミング
// ------------------------------------------------------------

/// millis() の値を使って、指定レートで「いつ送るか」を決める。
///   n 回目の送信予定時刻 = 起点 + n * 1000 / rate  （整数演算、誤差が溜まらない）
/// 処理が遅れたときは少しなら追いつき（連続で送る）、大きく遅れたら起点を取り直す
/// （古いサンプルをまとめて吐き出さない）。millis() の桁あふれ（約49日）にも対応。
class RateScheduler {
 public:
  /// これより遅れたら追いつくのをやめて起点を取り直す [ms]。
  static constexpr uint32_t kMaxLagMs = 100;

  void start(uint32_t now_ms, int rate_hz);
  /// 今送るべきなら true を返し、次の予定に進める。
  bool poll(uint32_t now_ms);
  int rateHz() const { return rate_hz_; }
  /// 大きく遅れて起点を取り直した回数（デバッグ用）。
  uint32_t resyncCount() const { return resyncs_; }

 private:
  uint32_t dueTime() const;

  uint32_t origin_ms_ = 0;
  uint32_t index_ = 0;
  int rate_hz_ = kRateDefaultHz;
  uint32_t resyncs_ = 0;
};

}  // namespace sender
