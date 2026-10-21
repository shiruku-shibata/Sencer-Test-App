// テスト用スタブ: 生成コードが使う M5Unified の API（M5.Imu.getAccelData / getGyroData / M5.update）の形だけ。
// 実機のライブラリではない。tests/snippets/run.sh が PC 上でのコンパイルに使う。
#pragma once

struct M5ImuStub {
  float accel[3] = {0.0f, 0.0f, 1.0f};
  float gyro[3] = {0.0f, 0.0f, 0.0f};
  bool getAccelData(float* x, float* y, float* z) {
    *x = accel[0];
    *y = accel[1];
    *z = accel[2];
    return true;
  }
  bool getGyroData(float* x, float* y, float* z) {
    *x = gyro[0];
    *y = gyro[1];
    *z = gyro[2];
    return true;
  }
};

struct M5Stub {
  M5ImuStub Imu;
  void update() {}
};

static M5Stub M5;
