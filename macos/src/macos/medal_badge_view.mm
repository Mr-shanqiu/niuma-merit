#import <AppKit/AppKit.h>
#include <cmath>

// FB4 · 勋章墙徽章化。
//
// 每枚勋章绘制为有质感的圆形徽章：金属径向渐变 + 浮雕外环 + 高光 + 内圈刻字。
// 未点亮为灰色剪影（同形状、去色），并显示名称与达成条件。
// 全部用 Core Graphics 程序化绘制，不引入图片资源；保留原有阈值/点亮/计次/分享图逻辑，
// 只改视觉呈现。

// 徽章档位金属配色：0=铜 1=银 2=金；-1 = 集齐成就（紫金）。
typedef struct {
  CGFloat r, g, b;  // 主色
} NMMetalColor;

static NMMetalColor NMMetalBase(int tier) {
  switch (tier) {
    case 0: return (NMMetalColor){0.80, 0.52, 0.28};  // 铜
    case 1: return (NMMetalColor){0.78, 0.80, 0.84};  // 银
    case 2: return (NMMetalColor){0.95, 0.78, 0.30};  // 金
    default: return (NMMetalColor){0.62, 0.45, 0.86}; // 集齐：紫
  }
}

static NSColor *NMColorShift(NMMetalColor c, CGFloat dr, CGFloat dg, CGFloat db, CGFloat a) {
  return [NSColor colorWithCalibratedRed:MAX(0, MIN(1, c.r + dr))
                                   green:MAX(0, MIN(1, c.g + dg))
                                    blue:MAX(0, MIN(1, c.b + db))
                                   alpha:a];
}

@interface NMMedalBadgeView : NSView
@property(nonatomic) int tier;            // 0/1/2，-1 集齐
@property(nonatomic) BOOL lit;            // 是否点亮
@property(nonatomic, copy) NSString *glyph;      // 徽章中心字符（日/周/月/集）
@property(nonatomic, copy) NSString *title;      // 名称（如「日 · 铜」）
@property(nonatomic, copy) NSString *detail;     // 达成条件 / 首次日期
@end

@implementation NMMedalBadgeView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [NSColor.clearColor setFill];
  NSRectFill(self.bounds);

  const CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
  // 徽章圆盘区域：上方留出圆盘，下方留出两行文字。
  const CGFloat textH = 40.0;
  const CGFloat discSize = MIN(w - 12.0, h - textH - 8.0);
  const CGFloat cx = w / 2.0;
  const CGFloat cy = 6.0 + discSize / 2.0;
  const CGFloat r = discSize / 2.0;

  NMMetalColor base = NMMetalBase(self.tier);
  const BOOL lit = self.lit;

  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  CGContextSaveGState(ctx);

  // 外投影，增加浮雕悬浮感。
  CGContextSetShadowWithColor(ctx, CGSizeMake(0, 2), lit ? 4.0 : 1.5,
      [NSColor colorWithWhite:0 alpha:lit ? 0.28 : 0.12].CGColor);

  // 1) 外环（金属圈）：径向渐变，边缘更暗形成浮雕。
  NSRect outer = NSMakeRect(cx - r, cy - r, discSize, discSize);
  NSBezierPath *outerPath = [NSBezierPath bezierPathWithOvalInRect:outer];
  NSGradient *rimGrad;
  if (lit) {
    rimGrad = [[NSGradient alloc] initWithColors:@[
      NMColorShift(base, 0.18, 0.16, 0.12, 1.0),   // 高光
      NMColorShift(base, 0.0, 0.0, 0.0, 1.0),      // 主色
      NMColorShift(base, -0.28, -0.28, -0.24, 1.0),// 暗边
    ] atLocations:(CGFloat[]){0.0, 0.55, 1.0} colorSpace:NSColorSpace.deviceRGBColorSpace];
  } else {
    rimGrad = [[NSGradient alloc] initWithColors:@[
      [NSColor colorWithCalibratedWhite:0.80 alpha:1.0],
      [NSColor colorWithCalibratedWhite:0.66 alpha:1.0],
      [NSColor colorWithCalibratedWhite:0.52 alpha:1.0],
    ] atLocations:(CGFloat[]){0.0, 0.55, 1.0} colorSpace:NSColorSpace.deviceRGBColorSpace];
  }
  [rimGrad drawInBezierPath:outerPath relativeCenterPosition:NSMakePoint(-0.25, -0.35)];

  // 2) 内盘：略微内缩，径向渐变高光在左上，暗在右下，形成球面浮雕。
  const CGFloat innerR = r - MAX(3.0, discSize * 0.06);
  NSRect inner = NSMakeRect(cx - innerR, cy - innerR, innerR * 2, innerR * 2);
  NSBezierPath *innerPath = [NSBezierPath bezierPathWithOvalInRect:inner];
  NSGradient *faceGrad;
  if (lit) {
    faceGrad = [[NSGradient alloc] initWithColors:@[
      NMColorShift(base, 0.30, 0.28, 0.22, 1.0),   // 左上高光
      NMColorShift(base, 0.06, 0.05, 0.03, 1.0),   // 中部主色
      NMColorShift(base, -0.22, -0.22, -0.20, 1.0),// 右下暗
    ] atLocations:(CGFloat[]){0.0, 0.5, 1.0} colorSpace:NSColorSpace.deviceRGBColorSpace];
  } else {
    faceGrad = [[NSGradient alloc] initWithColors:@[
      [NSColor colorWithCalibratedWhite:0.86 alpha:1.0],
      [NSColor colorWithCalibratedWhite:0.72 alpha:1.0],
      [NSColor colorWithCalibratedWhite:0.58 alpha:1.0],
    ] atLocations:(CGFloat[]){0.0, 0.5, 1.0} colorSpace:NSColorSpace.deviceRGBColorSpace];
  }
  [faceGrad drawInBezierPath:innerPath relativeCenterPosition:NSMakePoint(-0.3, -0.4)];

  CGContextRestoreGState(ctx);

  // 3) 内圈细刻线（双环），增强"徽章"层次。
  CGContextSaveGState(ctx);
  CGFloat ringR = innerR - MAX(2.0, discSize * 0.035);
  NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:
      NSMakeRect(cx - ringR, cy - ringR, ringR * 2, ringR * 2)];
  ring.lineWidth = 1.0;
  [[NSColor colorWithWhite:lit ? 0.0 : 0.35 alpha:lit ? 0.22 : 0.30] setStroke];
  [ring stroke];
  CGContextRestoreGState(ctx);

  // 4) 顶部弧形高光（微光）：一条从左上到右上的白色渐隐弧。
  CGContextSaveGState(ctx);
  NSBezierPath *gloss = [NSBezierPath bezierPath];
  const CGFloat glossR = innerR * 0.86;
  [gloss appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:glossR
                                    startAngle:110 endAngle:70 clockwise:YES];
  gloss.lineWidth = MAX(2.0, innerR * 0.16);
  gloss.lineCapStyle = NSLineCapStyleRound;
  [[NSColor colorWithWhite:1.0 alpha:lit ? 0.45 : 0.22] setStroke];
  [gloss stroke];
  CGContextRestoreGState(ctx);

  // 5) 中心字形（日/周/月/集），浮雕描边。
  NSString *glyph = self.glyph ?: @"";
  if (glyph.length) {
    CGFloat gs = innerR * 1.05;
    NSFont *gf = [NSFont systemFontOfSize:gs weight:NSFontWeightHeavy];
    NSShadow *gsh = [NSShadow new];
    gsh.shadowColor = [NSColor colorWithWhite:0 alpha:lit ? 0.35 : 0.20];
    gsh.shadowOffset = NSMakeSize(0, 1.5);
    gsh.shadowBlurRadius = 2.0;
    NSDictionary *ga = @{
      NSFontAttributeName : gf,
      NSForegroundColorAttributeName : lit
          ? [NSColor colorWithCalibratedWhite:0.99 alpha:0.96]
          : [NSColor colorWithCalibratedWhite:0.46 alpha:1.0],
      NSStrokeColorAttributeName : lit
          ? NMColorShift(base, -0.35, -0.34, -0.30, 0.85)
          : [NSColor colorWithCalibratedWhite:0.40 alpha:0.8],
      NSStrokeWidthAttributeName : @(-3.0),
      NSShadowAttributeName : gsh,
    };
    NSSize gsz = [glyph sizeWithAttributes:ga];
    [glyph drawAtPoint:NSMakePoint(cx - gsz.width / 2.0, cy - gsz.height / 2.0)
        withAttributes:ga];
  }

  // 6) 名称（徽章下方一行）。
  NSColor *titleColor = lit ? NMUiInk() : NMUiMuted();
  NSFont *tf = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
  NSString *title = self.title ?: @"";
  NSSize tsz = [title sizeWithAttributes:@{NSFontAttributeName : tf}];
  CGFloat titleY = cy + r + 4.0;
  [title drawAtPoint:NSMakePoint(cx - MIN(tsz.width, w - 6) / 2.0, titleY)
      withAttributes:@{NSFontAttributeName : tf, NSForegroundColorAttributeName : titleColor}];

  // 7) 达成条件 / 首次日期（更小一行，灰色）。
  NSString *detail = self.detail ?: @"";
  if (detail.length) {
    NSFont *df = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSRect dr = NSMakeRect(2, titleY + tsz.height + 1.0, w - 4, 14);
    [detail drawInRect:dr withAttributes:@{
      NSFontAttributeName : df,
      NSForegroundColorAttributeName : lit ? NMUiMuted() : [NSColor colorWithCalibratedWhite:0.62 alpha:1.0],
      NSParagraphStyleAttributeName : ps,
    }];
  }
}

@end
