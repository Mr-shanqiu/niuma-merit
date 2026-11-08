#import <AppKit/AppKit.h>
#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>
#include "../merit_curve.h"

// F4 牛马曲线视图实现。日视图读取 96 个 15 分钟桶（区分未采集/真零）；周/月视图
// 读取旧存储的每日总（dailyTotals，权威来源）。纯展示，不做持久化。

static void NMCurveDrawText(NSString *text, NSRect rect, CGFloat size, NSColor *color,
                            NSFontWeight weight) {
  NSFont *font = [NSFont systemFontOfSize:size weight:weight];
  CGFloat width = [text sizeWithAttributes:@{NSFontAttributeName : font}].width;
  if (width > NSWidth(rect) && width > 0)
    font = [NSFont systemFontOfSize:MAX(9, size * NSWidth(rect) / width) weight:weight];
  [text drawInRect:rect withAttributes:@{NSFontAttributeName : font,
                                         NSForegroundColorAttributeName : color}];
}

@implementation NMCurveView

- (BOOL)isFlipped { return YES; }
- (void)refreshToToday { [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [NSColor.whiteColor setFill];
  NSRectFill(self.bounds);
  NSColor *ink = NMUiInk(), *muted = NMUiMuted(), *accent = NMUiMeritGold(), *blue = NMUiBlue();

  NSDateComponents *nowComp = [RecordCalendar() components:
      NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:NSDate.date];
  const int year = (int)nowComp.year, month = (int)nowComp.month, day = (int)nowComp.day;
  NSString *todayKey = DateKeyForDate(NSDate.date);

  NSNumberFormatter *numbers = [NSNumberFormatter new];
  numbers.numberStyle = NSNumberFormatterDecimalStyle;

  NSString *title = nil;
  if (self.mode == 0)
    title = [NSString stringWithFormat:UiText(@"牛马曲线 · 今日（%@）", @"Merit Curve · Today (%@)"), todayKey];
  else if (self.mode == 1)
    title = UiText(@"牛马曲线 · 本周（周一–周日）", @"Merit Curve · This Week (Mon–Sun)");
  else
    title = [NSString stringWithFormat:UiText(@"牛马曲线 · %ld 年 %ld 月", @"Merit Curve · %ld / %ld"),
        (long)year, (long)month];
  NMCurveDrawText(title, NSMakeRect(28, 20, NSWidth(self.bounds) - 56, 32), 22, ink, NSFontWeightBold);

  const CGFloat left = 64, right = 28, top = 78, bottom = 60;
  NSRect plot = NSMakeRect(left, top, NSWidth(self.bounds) - left - right,
                           NSHeight(self.bounds) - top - bottom);
  [[NSColor colorWithCalibratedWhite:.92 alpha:1] setStroke];
  NSBezierPath *axis = [NSBezierPath bezierPath];
  [axis moveToPoint:NSMakePoint(NSMinX(plot), NSMaxY(plot))];
  [axis lineToPoint:NSMakePoint(NSMaxX(plot), NSMaxY(plot))];
  axis.lineWidth = 1; [axis stroke];

  if (self.mode == 0) {
    NSDictionary *snapshot = [self.controller curveDayForDisplay:todayKey];
    unsigned long long total = [self.controller.dailyTotals[todayKey] unsignedLongLongValue];
    NMCurveDrawText(UiText(@"今日总计", @"Today's total"),
                    NSMakeRect(28, 48, 120, 18), 11, muted, NSFontWeightRegular);
    NMCurveDrawText([numbers stringFromNumber:@(total)],
                    NSMakeRect(NSWidth(self.bounds) - 260, 44, 232, 28), 22, ink,
                    NSFontWeightBold);
    if (!snapshot) {
      NMCurveDrawText(UiText(@"今日暂无 0.9.6 采集数据（历史旧日按「未采集」处理）",
                             @"No 0.9.6 samples yet today (older days show as not collected)."),
                      NSMakeRect(NSMinX(plot), NSMidY(plot) - 10, NSWidth(plot), 22), 13, muted,
                      NSFontWeightRegular);
      return;
    }
    NSArray *buckets = snapshot[@"buckets"];
    niuma::curve::Coverage coverage;
    const bool haveCoverage = niuma::curve::Coverage::FromHex(
        std::string([snapshot[@"coverage"] UTF8String] ?: ""), &coverage);
    std::uint64_t maxValue = 0;
    for (NSUInteger i = 0; i < buckets.count && i < 96; ++i) {
      if (haveCoverage && !coverage.Get((int)i)) continue;
      maxValue = std::max(maxValue, [buckets[i] unsignedLongLongValue]);
    }
    if (maxValue == 0) maxValue = 1;
    const CGFloat step = NSWidth(plot) / 96.0;
    for (int i = 0; i < 96; ++i) {
      const bool collected = haveCoverage && coverage.Get(i);
      NSRect cell = NSMakeRect(NSMinX(plot) + i * step, NSMinY(plot), std::max<CGFloat>(1, step - 1),
                               NSHeight(plot));
      if (!collected) {
        [[NSColor colorWithCalibratedWhite:.90 alpha:1] setFill];
        NSRectFill(NSMakeRect(cell.origin.x, NSMaxY(plot) - 3, cell.size.width, 3));
        continue;
      }
      std::uint64_t value = i < (int)buckets.count ? [buckets[(NSUInteger)i] unsignedLongLongValue] : 0;
      CGFloat h = NSHeight(plot) * (CGFloat)value / (CGFloat)maxValue;
      if (h < (value > 0 ? 2 : 0)) h = value > 0 ? 2 : 0;
      [(i >= 36 && i < 54 ? blue : accent) setFill];
      NSRectFill(NSMakeRect(cell.origin.x, NSMaxY(plot) - h, cell.size.width, h));
    }
    for (int hour = 0; hour <= 24; hour += 6) {
      CGFloat x = NSMinX(plot) + NSWidth(plot) * hour / 24.0;
      NMCurveDrawText([NSString stringWithFormat:@"%02d:00", hour],
                      NSMakeRect(x - 26, NSMaxY(plot) + 8, 52, 16), 10, muted, NSFontWeightRegular);
    }
    NMCurveDrawText([NSString stringWithFormat:UiText(@"峰值/桶 %@", @"Peak/bucket %@"),
                     [numbers stringFromNumber:@(maxValue)]],
                    NSMakeRect(NSMinX(plot), NSMaxY(plot) + 30, 240, 16), 11, muted,
                    NSFontWeightRegular);
    // 图例：未采集
    [[NSColor colorWithCalibratedWhite:.90 alpha:1] setFill];
    NSRectFill(NSMakeRect(NSMaxX(plot) - 150, NSMaxY(plot) + 32, 14, 6));
    NMCurveDrawText(UiText(@"未采集", @"Not collected"),
                    NSMakeRect(NSMaxX(plot) - 130, NSMaxY(plot) + 27, 120, 16), 11, muted,
                    NSFontWeightRegular);
    return;
  }

  // 周 / 月：读取每日总。
  std::vector<std::string> keys;
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  if (self.mode == 1) {
    keys = niuma::curve::WeekDayKeys(year, month, day);
    NSArray *zh = @[ @"一", @"二", @"三", @"四", @"五", @"六", @"日" ];
    NSArray *en = @[ @"MON", @"TUE", @"WED", @"THU", @"FRI", @"SAT", @"SUN" ];
    for (int i = 0; i < 7; ++i) [labels addObject:(IsChineseUI() ? zh : en)[i]];
  } else {
    keys = niuma::curve::MonthDayKeys(year, month);
    for (std::size_t i = 0; i < keys.size(); ++i)
      [labels addObject:[NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)]];
  }
  std::uint64_t maxValue = 0;
  std::vector<std::uint64_t> values;
  values.reserve(keys.size());
  for (const std::string &key : keys) {
    NSString *k = [NSString stringWithUTF8String:key.c_str()];
    std::uint64_t v = [self.controller.dailyTotals[k] unsignedLongLongValue];
    values.push_back(v);
    maxValue = std::max(maxValue, v);
  }
  if (maxValue == 0) maxValue = 1;
  const CGFloat count = (CGFloat)keys.size();
  const CGFloat slot = NSWidth(plot) / count;
  const CGFloat barWidth = std::max<CGFloat>(4, slot * 0.62);
  const CGFloat labelSize = count > 12 ? 8 : 11;
  for (std::size_t i = 0; i < keys.size(); ++i) {
    CGFloat cx = NSMinX(plot) + slot * (i + 0.5);
    CGFloat h = NSHeight(plot) * (CGFloat)values[i] / (CGFloat)maxValue;
    if (values[i] > 0 && h < 2) h = 2;
    [(i == 0 ? blue : accent) setFill];
    NSRectFill(NSMakeRect(cx - barWidth / 2, NSMaxY(plot) - h, barWidth, h));
    NSString *label = labels[i];
    CGFloat lw = count > 20 ? 20 : 40;
    NMCurveDrawText(label, NSMakeRect(cx - lw / 2, NSMaxY(plot) + 6, lw, 16), labelSize, muted,
                    NSFontWeightRegular);
    if (count <= 12) {
      NMCurveDrawText([numbers stringFromNumber:@(values[i])],
                      NSMakeRect(cx - 40, NSMaxY(plot) - h - 18, 80, 14), 10, ink,
                      NSFontWeightRegular);
    }
  }
  NMCurveDrawText([NSString stringWithFormat:UiText(@"峰值 %@", @"Peak %@"),
                   [numbers stringFromNumber:@(maxValue)]],
                  NSMakeRect(NSMinX(plot), NSMaxY(plot) + 30, 240, 16), 11, muted,
                  NSFontWeightRegular);
}

@end
