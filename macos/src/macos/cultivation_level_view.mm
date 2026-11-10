#import <AppKit/AppKit.h>
#include <cmath>
#include "cultivation_level.h"

// FB10 · 修行等级视图（D22）+ FB15 · 完整等级阶梯。
//
// 顶部：当前等级徽标（六边形 + 单一金属色）+ 进度环 + 称号 + 累计功德 + 距下一级/圆满。
// 下方：完整 6 级阶梯（香客→宗师），区分 已达成 / 当前高亮 / 未达成，并显示每级门槛功德。
// 全部程序化绘制，不引入图片、不使用佛/菩萨/罗汉等神祇字眼。

static NSColor *NMCultivationMetal() {
  return [NSColor colorWithCalibratedRed:0.80 green:0.63 blue:0.26 alpha:1.0];
}
static NSColor *NMCultivationMetalDark() {
  return [NSColor colorWithCalibratedRed:0.62 green:0.47 blue:0.17 alpha:1.0];
}

static void NMDrawCentered(NSString *text, NSRect rect, CGFloat size, NSFontWeight weight,
                           NSColor *color) {
  if (!text.length) return;
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentCenter;
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  NSFont *font = [NSFont systemFontOfSize:size weight:weight];
  CGFloat width = [text sizeWithAttributes:@{NSFontAttributeName : font}].width;
  if (width > NSWidth(rect) && width > 0)
    font = [NSFont systemFontOfSize:MAX(9, size * NSWidth(rect) / width) weight:weight];
  [text drawInRect:rect withAttributes:@{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : color,
    NSParagraphStyleAttributeName : ps,
  }];
}

static void NMDrawLeft(NSString *text, NSRect rect, CGFloat size, NSFontWeight weight,
                       NSColor *color) {
  if (!text.length) return;
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentLeft;
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  NSFont *font = [NSFont systemFontOfSize:size weight:weight];
  [text drawInRect:rect withAttributes:@{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : color,
    NSParagraphStyleAttributeName : ps,
  }];
}

static void NMDrawRight(NSString *text, NSRect rect, CGFloat size, NSFontWeight weight,
                        NSColor *color) {
  if (!text.length) return;
  NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
  ps.alignment = NSTextAlignmentRight;
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  NSFont *font = [NSFont systemFontOfSize:size weight:weight];
  [text drawInRect:rect withAttributes:@{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : color,
    NSParagraphStyleAttributeName : ps,
  }];
}

@interface NMCultivationLevelView : NSView
@property(nonatomic) int level;                  // 0-based 当前等级
@property(nonatomic, copy) NSString *title;      // 当前称号
@property(nonatomic, copy) NSString *meritText;  // 累计功德文案
@property(nonatomic, copy) NSString *subtitle;   // 距下一级/满级文案
@property(nonatomic) double progress;            // 0..1
@property(nonatomic) BOOL maxLevel;
// FB15：完整阶梯数据（由 app.mm 注入）。
@property(nonatomic, copy) NSArray<NSString *> *levelTitles;
@property(nonatomic, copy) NSArray<NSNumber *> *levelThresholds;
@end

@implementation NMCultivationLevelView
- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [NSColor.whiteColor setFill];
  NSRectFill(self.bounds);
  NSColor *ink = NMUiInk(), *muted = NMUiMuted();
  NSColor *metal = NMCultivationMetal(), *metalDark = NMCultivationMetalDark();

  const CGFloat w = NSWidth(self.bounds);
  const CGFloat cx = w / 2.0;

  // ---- 1) 顶部当前徽标 + 进度环（较小，给阶梯让出空间）----
  const CGFloat R = 50.0;             // 环半径
  const CGFloat cy = 60.0;            // 环心（flipped 顶向下）
  NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:
      NSMakeRect(cx - R, cy - R, R * 2, R * 2)];
  track.lineWidth = 8.0;
  [[NSColor colorWithCalibratedWhite:0.90 alpha:1] setStroke];
  [track stroke];

  double progress = self.maxLevel ? 1.0 : MAX(0.0, MIN(1.0, self.progress));
  if (progress > 0.0001) {
    NSBezierPath *arc = [NSBezierPath bezierPath];
    const CGFloat start = 90.0;
    const CGFloat end = 90.0 - 360.0 * (CGFloat)progress;
    [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:R
                                    startAngle:start endAngle:end clockwise:YES];
    arc.lineWidth = 8.0;
    arc.lineCapStyle = NSLineCapStyleRound;
    [metal setStroke];
    [arc stroke];
  }

  const CGFloat hr = R - 16.0;
  NSBezierPath *hex = [NSBezierPath bezierPath];
  for (int i = 0; i < 6; ++i) {
    const CGFloat deg = -90.0 + i * 60.0;
    const CGFloat rad = deg * (CGFloat)M_PI / 180.0;
    const CGFloat px = cx + hr * cos(rad);
    const CGFloat py = cy + hr * sin(rad);
    if (i == 0) [hex moveToPoint:NSMakePoint(px, py)];
    else [hex lineToPoint:NSMakePoint(px, py)];
  }
  [hex closePath];
  [metal setFill];
  [hex fill];
  hex.lineWidth = 1.5;
  [metalDark setStroke];
  [hex stroke];

  NSString *num = [NSString stringWithFormat:@"%d", self.level + 1];
  NMDrawCentered(num, NSMakeRect(cx - hr, cy - 20, hr * 2, 40), hr * 0.92,
                 NSFontWeightBold, [NSColor colorWithCalibratedWhite:1.0 alpha:0.95]);

  // 称号 / 累计功德 / 副文案
  CGFloat y = cy + R + 8.0;
  NMDrawCentered(self.title ?: @"", NSMakeRect(24, y, w - 48, 32), 24, NSFontWeightBold, ink);
  y += 34.0;
  NMDrawCentered(self.meritText ?: @"", NSMakeRect(24, y, w - 48, 20), 13,
                 NSFontWeightRegular, muted);
  y += 22.0;
  NMDrawCentered(self.subtitle ?: @"", NSMakeRect(24, y, w - 48, 22), 13,
                 NSFontWeightMedium, self.maxLevel ? metalDark : muted);
  y += 30.0;

  // ---- 2) 完整 6 级阶梯 ----
  NSArray<NSString *> *titles = self.levelTitles;
  NSArray<NSNumber *> *ths = self.levelThresholds;
  const NSInteger n = MIN(titles.count, ths.count);
  if (n <= 0) return;

  NSNumberFormatter *fmt = [NSNumberFormatter new];
  fmt.numberStyle = NSNumberFormatterDecimalStyle;

  const CGFloat rowH = MIN(30.0, (NSHeight(self.bounds) - y - 12.0) / (CGFloat)n);
  const CGFloat leftX = 32.0;
  const CGFloat dotR = 7.0;
  const CGFloat dotCx = leftX + dotR;
  for (NSInteger i = 0; i < n; ++i) {
    const CGFloat rowTop = y + rowH * (CGFloat)i;
    const BOOL achieved = (i < self.level);
    const BOOL current = (i == self.level);

    if (current) {
      [[metal colorWithAlphaComponent:0.14] setFill];
      NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:
          NSMakeRect(leftX - 12, rowTop + 2, w - (leftX - 12) * 2, rowH - 4)
          xRadius:7 yRadius:7];
      [bg fill];
    }

    // 状态圆点
    const CGFloat dotCy = rowTop + rowH / 2.0;
    NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:
        NSMakeRect(dotCx - dotR, dotCy - dotR, dotR * 2, dotR * 2)];
    if (achieved || current) {
      [metal setFill];
      [dot fill];
    } else {
      [[NSColor colorWithCalibratedWhite:0.78 alpha:1] setStroke];
      dot.lineWidth = 1.5;
      [dot stroke];
    }
    if (achieved) {  // 已达成画个白色对勾
      NSBezierPath *ck = [NSBezierPath bezierPath];
      [ck moveToPoint:NSMakePoint(dotCx - 3.2, dotCy + 0.2)];
      [ck lineToPoint:NSMakePoint(dotCx - 0.8, dotCy + 2.8)];
      [ck lineToPoint:NSMakePoint(dotCx + 3.6, dotCy - 2.6)];
      ck.lineWidth = 1.8;
      ck.lineCapStyle = NSLineCapStyleRound;
      [[NSColor whiteColor] setStroke];
      [ck stroke];
    }

    // 称号
    NSColor *titleColor = current ? ink : (achieved ? ink : muted);
    NSFontWeight tw = current ? NSFontWeightBold : NSFontWeightRegular;
    NMDrawLeft(titles[i], NSMakeRect(leftX + dotR * 2 + 12, rowTop + (rowH - 20) / 2.0,
                                     w * 0.5, 20), current ? 15 : 14, tw, titleColor);

    // 门槛功德（右对齐）
    NSString *thText = [fmt stringFromNumber:ths[i]];
    NSColor *thColor = current ? metalDark : (achieved ? ink : muted);
    NMDrawRight(thText, NSMakeRect(w - leftX - 120, rowTop + (rowH - 18) / 2.0, 120, 18),
                13, current ? NSFontWeightSemibold : NSFontWeightRegular, thColor);
  }
}

@end
