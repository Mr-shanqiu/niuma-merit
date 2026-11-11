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
  NMCurveDrawText(title, NSMakeRect(28, 20, NSWidth(self.bounds) - 56 - 360, 32), 22, ink, NSFontWeightBold);

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
    // FB9：统计数值移到标题行右侧，与「日/周/月」分段控件分离，不再压住 tab。
    NMCurveDrawText(UiText(@"今日总计", @"Today's total"),
                    NSMakeRect(NSWidth(self.bounds) - 352, 22, 84, 18), 11, muted, NSFontWeightRegular);
    NMCurveDrawText([numbers stringFromNumber:@(total)],
                    NSMakeRect(NSWidth(self.bounds) - 260, 14, 232, 28), 22, ink,
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
    // FB17：真折线——每 30 分钟一个点（48 点），Catmull-Rom 平滑 + 淡面积填充。
    const int kPoints = 48;
    std::uint64_t maxValue = 0;
    std::uint64_t vals[kPoints];
    BOOL has[kPoints];
    for (int p = 0; p < kPoints; ++p) {
      const int b0 = p * 2, b1 = p * 2 + 1;
      const bool c0 = haveCoverage && (b0 < 96) && coverage.Get(b0);
      const bool c1 = haveCoverage && (b1 < 96) && coverage.Get(b1);
      std::uint64_t v = 0;
      if (c0 && b0 < (int)buckets.count) v += [buckets[(NSUInteger)b0] unsignedLongLongValue];
      if (c1 && b1 < (int)buckets.count) v += [buckets[(NSUInteger)b1] unsignedLongLongValue];
      vals[p] = v;
      has[p] = (c0 || c1);
      if (has[p] && v > maxValue) maxValue = v;
    }
    if (maxValue == 0) maxValue = 1;
    NSPoint pts[kPoints];
    const CGFloat stepX = NSWidth(plot) / (CGFloat)kPoints;
    const CGFloat baseY = NSMaxY(plot);
    for (int p = 0; p < kPoints; ++p) {
      CGFloat h = NSHeight(plot) * (CGFloat)vals[p] / (CGFloat)maxValue;
      CGFloat x = NSMinX(plot) + stepX * (p + 0.5);
      pts[p] = NSMakePoint(x, NSMaxY(plot) - h);
    }
    // 未采集区段：底部灰色短标
    [[NSColor colorWithCalibratedWhite:.90 alpha:1] setFill];
    for (int p = 0; p < kPoints; ++p)
      if (!has[p])
        NSRectFill(NSMakeRect(NSMinX(plot) + stepX * p, NSMaxY(plot) - 3,
                              std::max<CGFloat>(1, stepX - 1), 3));

    NSBezierPath *linePath = [NSBezierPath bezierPath];
    NSBezierPath *areaPath = [NSBezierPath bezierPath];
    int q = 0;
    while (q < kPoints) {
      if (!has[q]) { ++q; continue; }
      int s = q;
      while (q + 1 < kPoints && has[q + 1]) ++q;
      int e = q;
      [linePath moveToPoint:pts[s]];
      [areaPath moveToPoint:NSMakePoint(pts[s].x, baseY)];
      [areaPath lineToPoint:pts[s]];
      for (int i = s; i < e; ++i) {
        NSPoint p0 = (i > s) ? pts[i - 1] : pts[i];
        NSPoint p1 = pts[i], p2 = pts[i + 1];
        NSPoint p3 = (i + 1 < e) ? pts[i + 2] : p2;
        NSPoint c1 = NSMakePoint(p1.x + (p2.x - p0.x) / 6.0, p1.y + (p2.y - p0.y) / 6.0);
        NSPoint c2 = NSMakePoint(p2.x - (p3.x - p1.x) / 6.0, p2.y - (p3.y - p1.y) / 6.0);
        // FB17b：钳制控制点到绘图区（防止 Catmull-Rom 在尖峰处过冲到基线以下 / 顶部以上）。
        const CGFloat yLo = NSMinY(plot), yHi = baseY;
        c1.y = MIN(MAX(c1.y, yLo), yHi);
        c2.y = MIN(MAX(c2.y, yLo), yHi);
        [linePath curveToPoint:p2 controlPoint1:c1 controlPoint2:c2];
        [areaPath curveToPoint:p2 controlPoint1:c1 controlPoint2:c2];
      }
      [areaPath lineToPoint:NSMakePoint(pts[e].x, baseY)];
      [areaPath closePath];
      ++q;
    }
    // FB17b：整体裁剪到绘图区，双保险——曲线绝不出基线/顶边。
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRect:plot] addClip];
    [[accent colorWithAlphaComponent:0.12] setFill];
    [areaPath fill];
    [accent setStroke];
    linePath.lineWidth = 2.0;
    linePath.lineJoinStyle = NSLineJoinStyleRound;
    linePath.lineCapStyle = NSLineCapStyleRound;
    [linePath stroke];
    [NSGraphicsContext restoreGraphicsState];

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
    NSArray *weekdays = NMWeekdayLabels();
    for (int i = 0; i < 7; ++i) [labels addObject:weekdays[i]];
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
