#pragma once

// F0 · 滚动计数 —— 按距离折算（Windows 纯逻辑层，无 Win32 依赖）。
//
// 与 macOS 的 ScrollTickCounter（macos/src/macos/input_runtime.mm）同一模型，
// 只把「像素距离」换成 Windows 的整数滚动增量：
//   - 每累计 1 个滚动刻度（WHEEL_DELTA = 120）计 1 功德；
//   - 单条事件最多 kMaxTicksPerEvent 个刻度（异常跳变不保留余量）；
//   - 单次手势最多 kMaxTicksPerGesture 个刻度，超出部分丢弃；
//   - 方向不敏感：向上/向下、水平/垂直都按 |delta| 累计；
//   - 手势边界由调用方判定（Windows 无 scrollPhase）。手指重新落下、空闲
//     超过 kIdleGestureGapMs、监听器重启时传 new_gesture=true。
//
// Windows 的 WHEEL_DELTA 本身是整数，因此本层全程整数运算，不引入浮点
// 余量误差。本层不做 I/O、不读时钟、不调用平台 API。
//
// 契约：CONTRACT_096 §2（计数为 uint64）与 FEATURE_FREEZE §三（F0）。

#include <cstdint>

namespace niuma {
namespace client {
namespace core {

class ScrollTickCounter {
 public:
  // WHEEL_DELTA：一个传统滚轮刻度。
  static constexpr int kWheelDelta = 120;
  // 与 macOS 版常量对齐（kMaxTicksPerEvent / kMaxTicksPerGesture）；实机
  // 校准后两端应同步调整。
  static constexpr int kMaxTicksPerEvent = 4;
  static constexpr int kMaxTicksPerGesture = 30;
  // 与 macOS kIdleGestureGap(0.35s) 对齐：调用方用它判定「空闲即新手势」。
  static constexpr std::uint64_t kIdleGestureGapMs = 350;

  // 调用方判定新手势时使用；now < last 视为时钟回退，不开启新手势。
  static bool IdleGapExceeded(std::uint64_t last_ms, std::uint64_t now_ms) noexcept {
    return now_ms >= last_ms && now_ms - last_ms > kIdleGestureGapMs;
  }

  // 显式开始一次新手势：清空亚刻度余量与本次手势预算。
  void BeginGesture() noexcept {
    residue_delta_ = 0;
    gesture_ticks_ = 0;
    active_ = true;
  }

  // wheel_delta：WM_MOUSEWHEEL / WM_MOUSEHWHEEL 或 RAWMOUSE 的带符号增量；
  // 调用方已按「手指重新落下 / 空闲超时」算好 new_gesture。
  // 返回本次事件应增加的功德数（0..kMaxTicksPerEvent）。
  int Consume(int wheel_delta, bool new_gesture) noexcept {
    if (new_gesture || !active_) BeginGesture();
    const std::uint64_t magnitude = Magnitude(wheel_delta);
    if (magnitude == 0) return 0;
    if (gesture_ticks_ >= kMaxTicksPerGesture) {
      residue_delta_ = 0;  // 本次手势已封顶，余量不再保留
      return 0;
    }
    std::uint64_t incoming = magnitude;
    const std::uint64_t max_delta_per_event =
        static_cast<std::uint64_t>(kWheelDelta) * kMaxTicksPerEvent;
    if (incoming > max_delta_per_event) {
      residue_delta_ = 0;  // 异常跳变：不把余量带入下一次事件
      incoming = max_delta_per_event;
    }
    residue_delta_ += incoming;
    int ticks = 0;
    while (residue_delta_ >= static_cast<std::uint64_t>(kWheelDelta) &&
           ticks < kMaxTicksPerEvent) {
      if (gesture_ticks_ >= kMaxTicksPerGesture) {
        residue_delta_ = 0;
        break;
      }
      residue_delta_ -= static_cast<std::uint64_t>(kWheelDelta);
      ++gesture_ticks_;
      ++ticks;
    }
    return ticks;
  }

  bool active() const noexcept { return active_; }
  int gesture_ticks() const noexcept { return gesture_ticks_; }  // 本次手势已计刻度
  std::uint64_t residue() const noexcept { return residue_delta_; }  // delta 余量，0..119

 private:
  // 无符号绝对值，避免 INT_MIN 取负溢出。
  static std::uint64_t Magnitude(int value) noexcept {
    if (value >= 0) return static_cast<std::uint64_t>(value);
    return static_cast<std::uint64_t>(-(value + 1)) + 1;
  }

  std::uint64_t residue_delta_ = 0;  // 0..kWheelDelta-1 的亚刻度余量
  int gesture_ticks_ = 0;            // 本次手势已计刻度
  bool active_ = false;              // 首条事件自动开启手势
};

}  // namespace core
}  // namespace client
}  // namespace niuma
