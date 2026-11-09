#import <AppKit/AppKit.h>
#include <cmath>

// FB10 · 修行等级视图（D22）。
//
// 单一等级徽标（六边形 + 单一金属色，简洁克制、不做拟物浮雕）+ 进度环 +
// 当前称号 + 「距下一级还差 X 功德」。满级显示「宗师 · 功德圆满」。
// 全部程序化绘制，不引入图片资源、不使用佛/菩萨/罗汉等神祇字眼。

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

@interface NMCultivationLevelView : NSView
@property(nonatomic) int level;             // 0-based，0=香客
@property(nonatomic, copy) NSString *title;      // 当前称号
@property(nonatomic, copy) NSString *meritText;  // 累计功德文案
@property(nonatomic, copy) NSString *subtitle;   // 距下一级/满级文案
@property(nonatomic) double progress;       // 0..1
@property(nonatomic) BOOL maxLevel;
@end

@implementation NMCultivationLevelView
- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [NSColor.whiteColor setFill];
  NSRectFill(self.bounds);
  NSColor *ink = NMUiInk(), *muted = NMUiMuted();
  NSColor *metal = NMCultivationMetal(), *metalDark = NMCultivationMetalDark();

  const CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
  const CGFloat cx = w / 2.0;
  const CGFloat R = MIN(w * 0.24, 92.0);   // 进度环半径
  const CGFloat cy = 20.0 + R;             // 环心（顶部留白）

  // 1) 进度环轨道。
  NSBezierPath *track = [NSBezierPath bezierPathWithOvalInRect:
      NSMakeRect(cx - R, cy - R, R * 2, R * 2)];
  track.lineWidth = 10.0;
  [[NSColor colorWithCalibratedWhite:0.90 alpha:1] setStroke];
  [track stroke];

  // 2) 进度弧（自顶部顺时针）。
  double progress = self.maxLevel ? 1.0 : MAX(0.0, MIN(1.0, self.progress));
  if (progress > 0.0001) {
    NSBezierPath *arc = [NSBezierPath bezierPath];
    const CGFloat start = 90.0;
    const CGFloat end = 90.0 - 360.0 * (CGFloat)progress;
    [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:R
                                    startAngle:start endAngle:end clockwise:YES];
    arc.lineWidth = 10.0;
    arc.lineCapStyle = NSLineCapStyleRound;
    [metal setStroke];
    [arc stroke];
  }

  // 3) 六边形徽标（单一金属色，扁平不拟物）。
  const CGFloat hr = R - 24.0;  // 六边形外接半径
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

  // 4) 中央等级序号。
  NSString *num = [NSString stringWithFormat:@"%d", self.level + 1];
  NMDrawCentered(num, NSMakeRect(cx - hr, cy - 22, hr * 2, 44), hr * 0.95,
                 NSFontWeightBold, [NSColor colorWithCalibratedWhite:1.0 alpha:0.95]);

  // 5) 当前称号。
  CGFloat textTop = cy + R + 16.0;
  NMDrawCentered(self.title ?: @"", NSMakeRect(24, textTop, w - 48, 40), 28,
                 NSFontWeightBold, ink);

  // 6) 累计功德。
  NMDrawCentered(self.meritText ?: @"", NSMakeRect(24, textTop + 44.0, w - 48, 22), 13,
                 NSFontWeightRegular, muted);

  // 7) 距下一级 / 满级文案。
  NMDrawCentered(self.subtitle ?: @"", NSMakeRect(24, textTop + 72.0, w - 48, 24), 14,
                 NSFontWeightMedium, self.maxLevel ? metalDark : muted);
}

@end
