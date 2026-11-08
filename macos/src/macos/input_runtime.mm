#include <mutex>
#include <ctime>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <algorithm>
#include <map>
#include <string>
#include "../merit_curve.h"

// F0: scroll counting is by distance, not by a per-gesture debounce. These
// helpers are shared by the live input mailbox below and the CGEventTap
// fallback in app.mm so both use identical thresholds and gesture rules.
namespace niuma { namespace macos {

struct ScrollTickCounter {
  // One tick adds one merit. Continuous (trackpad / precision) deltas are in
  // pixels; this is the calibrated pixels-per-notch. Line-based wheels report
  // lines, where one line already equals one tick.
  static constexpr double kPixelsPerTick = 10.0;
  // Guard abnormal single events and a runaway single gesture. Both values
  // are calibration constants for real hardware; momentum counts but stays
  // inside the same gesture and is bounded by kMaxTicksPerGesture.
  static constexpr double kMaxTicksPerEvent = 4.0;
  static constexpr double kMaxTicksPerGesture = 30.0;
  // Wheels that expose no scroll phase use an idle gap to start a new gesture.
  static constexpr double kIdleGestureGap = 0.35;

  double residue = 0.0;        // sub-tick carry across contiguous events
  double gestureTicks = 0.0;   // whole ticks already counted this gesture
  bool gestureActive = false;
  double lastEventTime = 0.0;

  void BeginGesture(double now) {
    residue = 0.0;
    gestureTicks = 0.0;
    gestureActive = true;
    lastEventTime = now;
  }

  // distanceTicks: absolute magnitude for this event in tick units. phase /
  // momentum: raw kCGScrollPhase* / kCGMomentumScrollPhase* values. Returns
  // the number of whole ticks to add now (0..kMaxTicksPerEvent).
  int Consume(double distanceTicks, std::uint32_t phase, std::uint32_t momentum, double now) {
    const bool began = (phase & 1u) != 0;                 // kCGScrollPhaseBegan
    const bool hasPhase = phase != 0 || momentum != 0;
    const double idle = now - lastEventTime;
    if (began || !gestureActive) {
      BeginGesture(now);                                  // finger re-landed / first event
    } else if (!hasPhase && idle > kIdleGestureGap) {
      BeginGesture(now);                                  // classic wheel: pause == new gesture
    }
    lastEventTime = now;
    if (!std::isfinite(distanceTicks) || distanceTicks < 0.0) distanceTicks = 0.0;
    if (distanceTicks > kMaxTicksPerEvent) residue = 0.0; // abnormal jump: do not bank residue
    residue += std::min(distanceTicks, kMaxTicksPerEvent);
    int ticks = 0;
    while (residue >= 1.0) {
      if (gestureTicks >= kMaxTicksPerGesture) { residue = 0.0; break; }
      residue -= 1.0;
      gestureTicks += 1.0;
      ++ticks;
      if (ticks >= static_cast<int>(kMaxTicksPerEvent)) { residue = std::fmod(residue, 1.0); break; }
    }
    return ticks;
  }
};

// Absolute tick-equivalent magnitude of a raw scroll event.
inline double ScrollTickDistance(CGEventRef event) {
  if (!event) return 0.0;
  const std::int64_t continuous =
      CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
  if (continuous) {
    const double dx = static_cast<double>(
        CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1));
    const double dy = static_cast<double>(
        CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2));
    return std::hypot(dx, dy) / ScrollTickCounter::kPixelsPerTick;
  }
  // Line-based wheel: fixed-point line delta keeps fractional lines.
  double dx = static_cast<double>(
      CGEventGetIntegerValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1)) / 65536.0;
  double dy = static_cast<double>(
      CGEventGetIntegerValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2)) / 65536.0;
  double lines = std::hypot(dx, dy);
  if (lines <= 0.0) {
    dx = static_cast<double>(CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1));
    dy = static_cast<double>(CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2));
    lines = std::hypot(dx, dy) / ScrollTickCounter::kPixelsPerTick;
  }
  return lines;
}

}}  // namespace niuma::macos

// The activity algorithm is unchanged. Each operation is a short in-memory
// critical section; persistence and presentation never hold this mutex.
class NMSynchronizedActivity {
  mutable std::mutex mutex_;
  niuma::reminder::ActivitySampler value_;
 public:
  using Sampler=niuma::reminder::ActivitySampler;
  void Observe(Sampler::Event e,std::uint64_t t) { std::lock_guard<std::mutex> l(mutex_);value_.Observe(e,t); }
  void BeginSuspend(std::uint64_t t) { std::lock_guard<std::mutex> l(mutex_);value_.BeginSuspend(t); }
  void ResetForListenerRestart() { std::lock_guard<std::mutex> l(mutex_);value_.ResetForListenerRestart(); }
  void RestoreSegmentConsumed(bool c) { std::lock_guard<std::mutex> l(mutex_);value_.RestoreSegmentConsumed(c); }
  bool ResumeFromSuspend(std::uint64_t t,bool p,bool trusted,std::uint64_t d) { std::lock_guard<std::mutex> l(mutex_);return value_.ResumeFromSuspend(t,p,trusted,d); }
  bool suspended() const { std::lock_guard<std::mutex> l(mutex_);return value_.suspended(); }
  bool segment_consumed() const { std::lock_guard<std::mutex> l(mutex_);return value_.segment_consumed(); }
  std::uint64_t suspend_started_ms() const { std::lock_guard<std::mutex> l(mutex_);return value_.suspend_started_ms(); }
  Sampler::Trigger Evaluate(std::uint64_t t,bool healthy=true) { std::lock_guard<std::mutex> l(mutex_);return value_.Evaluate(t,healthy); }
};

// This is a pending ledger, not an event queue: repeated inputs update a few
// integers. Only distinct calendar dates add entries, exactly as in saved data.
// Payload, key identity, coordinates and window information never enter it.
@interface NMInputMailbox : NSObject {
  NSLock *_lock;
  NSMutableDictionary<NSString *,NSNumber *> *_days;
  unsigned long long _events,_keys,_clicks,_scrolls,_checkKeys,_checkClicks,_checkScrolls,_checkCounted,_checkExpected;
  long long _remaining;
  double _lastCount,_interval,_checkStart,_checkEnd,_checkLast;
  niuma::macos::ScrollTickCounter _scrollCounter;
  std::map<std::string, niuma::curve::CurveDay> _curve;
  BOOL _checking;
  time_t _lastWallSecond;
  NSString *_dateKey;
  CGEventType _disabled;
}
- (instancetype)initWithTotal:(long long)total;
- (void)configureCheckFrom:(double)start until:(double)end enabled:(BOOL)enabled;
- (void)record:(CGEventType)type wall:(time_t)wall uptime:(double)uptime
        scrollTicks:(double)scrollTicks phase:(std::uint32_t)phase momentum:(std::uint32_t)momentum;
- (void)invalidateDate;
- (void)disabled:(CGEventType)type;
- (NSDictionary *)take;
@end
@implementation NMInputMailbox
- (instancetype)initWithTotal:(long long)total {
  if ((self=[super init])) { _lock=[NSLock new]; _days=[NSMutableDictionary dictionary];
    _remaining=LLONG_MAX-MAX(0,total); _interval=.22; _lastWallSecond=-1; }
  return self;
}
- (void)configureCheckFrom:(double)start until:(double)end enabled:(BOOL)enabled {
  [_lock lock];_checkStart=start;_checkEnd=end;_checking=enabled;[_lock unlock];
}
- (void)invalidateDate { [_lock lock];_lastWallSecond=-1;[_lock unlock]; }
- (void)disabled:(CGEventType)type { [_lock lock]; _disabled=type; [_lock unlock]; }
- (void)record:(CGEventType)type wall:(time_t)wall uptime:(double)uptime
    scrollTicks:(double)scrollTicks phase:(std::uint32_t)phase momentum:(std::uint32_t)momentum {
  [_lock lock];
  ++_events;
  BOOL checking=_checking && uptime>=_checkStart && uptime<_checkEnd;
  if(type==kCGEventKeyDown) { ++_keys; if(checking) ++_checkKeys; }
  else if(type==kCGEventScrollWheel) { ++_scrolls; if(checking) ++_checkScrolls; }
  else { ++_clicks; if(checking) ++_checkClicks; }
  if(checking) _checkLast=uptime-_checkStart;
  // Keys and clicks add exactly one merit. A scroll wheel adds one merit per
  // accumulated distance tick (F0), so fast/continuous scrolling is no longer
  // folded into a single count; momentum stays inside the same gesture.
  NSUInteger increments=1;
  if(type==kCGEventScrollWheel)
    increments=(NSUInteger)_scrollCounter.Consume(scrollTicks,phase,momentum,uptime);
  if(checking) _checkExpected+=increments;
  // F4: 按事件发生的本地时间归桶。每个实际计数增量都记入对应 15 分钟桶。
  std::string curveKey; int curveBucket=-1;
  if(increments>0) {
    struct tm local{}; localtime_r(&wall,&local);
    char ck[32]{}; strftime(ck,sizeof(ck),"%Y-%m-%d",&local);
    curveKey.assign(ck);
    curveBucket=niuma::curve::BucketForMinute(local.tm_hour*60+local.tm_min);
  }
  for(NSUInteger i=0;i<increments;i++) {
    if(_remaining<=0) break;
    --_remaining;
    if(_lastWallSecond!=wall) {
      struct tm local{};localtime_r(&wall,&local);char key[32]{};strftime(key,sizeof(key),"%Y-%m-%d",&local);
      _dateKey=[NSString stringWithUTF8String:key];_lastWallSecond=wall;
    }
    _days[_dateKey]=@([_days[_dateKey] longLongValue]+1);
    if(curveBucket>=0) _curve[curveKey].AddCount(curveBucket,1);
    if(checking) ++_checkCounted;
  }
  if(increments>0) {
    double gap=uptime-_lastCount;
    _interval=_lastCount<=0 || gap>.6 || gap<0 ? .22 : _interval*.65+gap*.35;
    _lastCount=uptime;
  }
  [_lock unlock];
}
- (NSDictionary *)take {
  [_lock lock];
  NSMutableDictionary *snapshot=[@{@"days":_days,@"events":@(_events),@"keys":@(_keys),@"clicks":@(_clicks),@"scrolls":@(_scrolls),
    @"checkKeys":@(_checkKeys),@"checkClicks":@(_checkClicks),@"checkScrolls":@(_checkScrolls),@"checkCounted":@(_checkCounted),@"checkExpected":@(_checkExpected),
    @"checkLast":@(_checkLast),@"interval":@(_interval),@"lastCount":@(_lastCount),@"disabled":@(_disabled)} mutableCopy];
  NSMutableDictionary *curveOut=[NSMutableDictionary dictionaryWithCapacity:_curve.size()];
  for(const auto &entry:_curve) {
    NSData *buckets=[NSData dataWithBytes:entry.second.buckets.data() length:96*sizeof(std::uint64_t)];
    NSData *coverage=[NSData dataWithBytes:entry.second.coverage.bytes.data() length:12];
    curveOut[[NSString stringWithUTF8String:entry.first.c_str()]]=@{@"buckets":buckets,@"coverage":coverage};
  }
  _curve.clear();
  snapshot[@"curve"]=curveOut;
  _days=[NSMutableDictionary dictionary]; _events=_keys=_clicks=_scrolls=_checkKeys=_checkClicks=_checkScrolls=_checkCounted=_checkExpected=0; _disabled=(CGEventType)0;
  [_lock unlock];return snapshot;
}
@end

@interface NMEventTapThread : NSObject {
  NSCondition *_condition;
  NSThread *_thread;
  CFRunLoopRef _runLoop;
  CFRunLoopSourceRef _source;
  BOOL _ready,_finished;
}
- (instancetype)initWithSource:(CFRunLoopSourceRef)source;
- (void)stop;
@end
@implementation NMEventTapThread
- (instancetype)initWithSource:(CFRunLoopSourceRef)source {
  if((self=[super init])) {
    _condition=[NSCondition new];_source=(CFRunLoopSourceRef)CFRetain(source);
    _thread=[[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
    _thread.name=@"Niuma input events";[_condition lock];[_thread start];
    while(!_ready) [_condition wait];[_condition unlock];
  }return self;
}
- (void)run { @autoreleasepool {
  [_condition lock];_runLoop=CFRunLoopGetCurrent();CFRetain(_runLoop);
  CFRunLoopAddSource(_runLoop,_source,kCFRunLoopDefaultMode);
  CFRunLoopPerformBlock(_runLoop,kCFRunLoopDefaultMode,^{
    [self->_condition lock];self->_ready=YES;[self->_condition broadcast];[self->_condition unlock];
  });
  [_condition unlock];
  CFRunLoopRun();
  CFRunLoopRemoveSource(_runLoop,_source,kCFRunLoopDefaultMode);CFRelease(_source);_source=NULL;
  [_condition lock];CFRelease(_runLoop);_runLoop=NULL;_finished=YES;[_condition broadcast];[_condition unlock];
}}
- (void)stop {
  [_condition lock];if(_runLoop) { CFRunLoopStop(_runLoop);CFRunLoopWakeUp(_runLoop); }
  while(!_finished) [_condition wait];[_condition unlock];_thread=nil;
}
@end
