// 生成した C++ 判定コード（SNIPPET で指定したヘッダ）に入力列を流し、1行ごとに 0/1 を出力する。
//   使い方: driver <input.txt>   入力 1行 = "ax ay az gx gy gz timestamp_ms"
// update()（M5.Imu から読む経路）も、スタブの IMU に値を入れて同じ判定になるかを確かめる。
// そのとき、サンプルの間（SAMPLE_INTERVAL_MS 未満）にも update() を 1ms ごとに呼び、
// 余分な呼び出しが判定にも平滑化にも影響しない（loop() の回る速さに依存しない）ことも確かめる。
// 入力のサンプル間隔は SAMPLE_INTERVAL_MS 以上であること（gen_cases.gd が sample_rate_hz を合わせる）。
#include <cstdio>
#include SNIPPET

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: driver <input.txt>\n");
    return 2;
  }
  std::FILE* f = std::fopen(argv[1], "r");
  if (f == nullptr) {
    std::fprintf(stderr, "cannot open %s\n", argv[1]);
    return 2;
  }
  motion_threshold::MotionDetector by_feed;    // feed(a, g, t) で値を直接渡す
  motion_threshold::MotionDetector by_update;  // update(t) で M5.Imu から読む
  float a[3], g[3];
  unsigned long t = 0;
  int mismatch = 0;
  while (std::fscanf(f, "%f %f %f %f %f %f %lu", &a[0], &a[1], &a[2], &g[0], &g[1], &g[2], &t) == 7) {
    bool fired = by_feed.feed(a, g, static_cast<uint32_t>(t));
    for (int i = 0; i < 3; ++i) {
      M5.Imu.accel[i] = a[i];
      M5.Imu.gyro[i] = g[i];
    }
    if (by_update.update(static_cast<uint32_t>(t)) != fired) ++mismatch;
    // loop() が速く回って、次のサンプル時刻までに同じ IMU 値で何度も update() が呼ばれる場合:
    // SAMPLE_INTERVAL_MS ごとにしか読まないので、判定（と平滑化）は 1 回分のまま変わらない
    for (uint32_t k = 1; k < motion_threshold::SAMPLE_INTERVAL_MS; ++k) {
      if (by_update.update(static_cast<uint32_t>(t + k))) ++mismatch;
    }
    std::printf("%d\n", fired ? 1 : 0);
  }
  std::fclose(f);
  if (mismatch > 0) {
    std::fprintf(stderr, "feed() と update() の結果が %d 回食い違いました\n", mismatch);
    return 3;
  }
  return 0;
}
