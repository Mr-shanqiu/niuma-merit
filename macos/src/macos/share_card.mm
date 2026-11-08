#import <AppKit/AppKit.h>
#include <cmath>
#include <cstring>

// F3/F4 共用分享卡 PNG 渲染底层（CONTRACT_096 §8）。
//
// 只接收白名单展示模型（NMShareCardModel）；模型之外的任何数据不得进入渲染。
// 输出为单张 PNG 像素，不写任何文本块/EXIF/伴随文件——因此不含本机路径、账号
// 或逐桶原始时段数组。曲线图的数据仅用于本次像素渲染，不落盘。

typedef NS_ENUM(NSInteger, NMShareCardKind) {
  NMShareCardKindMedal = 0,
  NMShareCardKindCurve = 1,
};

@interface NMShareCardModel : NSObject
@property(nonatomic) NMShareCardKind kind;
@property(nonatomic, copy) NSString *locale;
@property(nonatomic, copy) NSString *appVersion;
@property(nonatomic, copy) NSString *generatedOn;  // 仅 YYYY-MM-DD
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, copy) NSString *meritPeriod;
@property(nonatomic) unsigned long long meritValue;
@property(nonatomic, copy) NSString *medalPeriod;
@property(nonatomic, copy) NSString *medalTier;
@property(nonatomic, copy) NSString *medalEarnedDay;
@property(nonatomic) NSInteger medalCount;
@property(nonatomic, copy) NSString *moneyCurrency;
@property(nonatomic, copy) NSString *moneyDisplay;
@property(nonatomic) NSInteger moneyExponent;
@property(nonatomic) unsigned long long moneyAmountMinor;
@property(nonatomic, copy) NSString *footerProduct;
@property(nonatomic, copy) NSString *footerWatermark;
// 曲线卡：仅渲染用，不持久化。
@property(nonatomic, copy) NSString *curveView;
@property(nonatomic, copy) NSString *curveRangeLabel;
@property(nonatomic, copy) NSString *curveYUnit;
@property(nonatomic, copy) NSArray<NSNumber *> *curvePoints;
@property(nonatomic, copy) NSArray<NSString *> *curveLabels;
@end

@implementation NMShareCardModel
@end

static NSColor *NMShareInk(void) { return [NSColor colorWithCalibratedRed:.13 green:.13 blue:.16 alpha:1]; }
static NSColor *NMShareMuted(void) { return [NSColor colorWithCalibratedRed:.42 green:.42 blue:.47 alpha:1]; }
static NSColor *NMShareGold(void) { return [NSColor colorWithCalibratedRed:.80 green:.52 blue:.16 alpha:1]; }
static NSColor *NMShareTierColor(NSString *tier) {
  if ([tier isEqualToString:@"gold"]) return [NSColor colorWithCalibratedRed:.86 green:.68 blue:.18 alpha:1];
  if ([tier isEqualToString:@"silver"]) return [NSColor colorWithCalibratedRed:.66 green:.68 blue:.72 alpha:1];
  return [NSColor colorWithCalibratedRed:.78 green:.47 blue:.24 alpha:1];  // bronze
}
static void NMShareText(NSString *text, NSRect rect, CGFloat size, NSColor *color,
                        NSFontWeight weight, NSTextAlignment align) {
  if (text.length == 0) return;
  NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
  p.alignment = align;
  p.lineBreakMode = NSLineBreakByTruncatingTail;
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:size weight:weight],
    NSForegroundColorAttributeName : color,
    NSParagraphStyleAttributeName : p,
  };
  [text drawInRect:rect withAttributes:attrs];
}

// 仅保留像素所需的块，剔除 eXIf / tEXt / zTXt / iTXt 等元数据块（契约 §8.2）。
static NSData *NMPNGStripMetadata(NSData *png) {
  if (png.length < 8) return png;
  const unsigned char *bytes = static_cast<const unsigned char *>(png.bytes);
  static const unsigned char signature[8] = {0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a};
  if (std::memcmp(bytes, signature, 8) != 0) return png;
  NSMutableData *out = [NSMutableData dataWithBytes:signature length:8];
  NSUInteger index = 8;
  while (index + 12 <= png.length) {
    const std::uint32_t length = (static_cast<std::uint32_t>(bytes[index]) << 24) |
        (static_cast<std::uint32_t>(bytes[index + 1]) << 16) |
        (static_cast<std::uint32_t>(bytes[index + 2]) << 8) |
        static_cast<std::uint32_t>(bytes[index + 3]);
    if (index + 12 + length > png.length) break;
    const char *type = reinterpret_cast<const char *>(bytes + index + 4);
    const bool keep = std::memcmp(type, "IHDR", 4) == 0 ||
        std::memcmp(type, "PLTE", 4) == 0 || std::memcmp(type, "IDAT", 4) == 0 ||
        std::memcmp(type, "IEND", 4) == 0 || std::memcmp(type, "sRGB", 4) == 0;
    if (keep) [out appendBytes:bytes + index length:12 + length];
    index += 12 + length;
  }
  return out;
}

// 渲染为 PNG 数据（不含元数据）。宽高为像素，1x。
static NSData *NMRenderShareCardPNG(NMShareCardModel *model, CGFloat width, CGFloat height) {
  if (!model || width < 64 || height < 64) return nil;
  NSInteger W = (NSInteger)llround(width), H = (NSInteger)llround(height);
  NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H
                   bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSDeviceRGBColorSpace
                       bitmapFormat:0 bytesPerRow:W * 4 bitsPerPixel:32];
  if (!rep) return nil;
  rep.size = NSMakeSize(width, height);
  NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = ctx;
  NSRect canvas = NSMakeRect(0, 0, width, height);
  [NSGraphicsContext currentContext].imageInterpolation = NSImageInterpolationHigh;

  // 背景：柔和米色渐变（不透明，便于分享）。
  NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:
      [NSColor colorWithCalibratedRed:.99 green:.97 blue:.92 alpha:1]
      endingColor:[NSColor colorWithCalibratedRed:.95 green:.91 blue:.82 alpha:1]];
  [gradient drawInRect:canvas angle:-90];
  [[NSColor colorWithCalibratedWhite:1 alpha:.65] setFill];
  NSRectFill(NSMakeRect(28, 28, width - 56, height - 56));

  const CGFloat margin = 56;
  // 顶部标题
  NMShareText(model.title.length ? model.title : @"牛马电子功德",
              NSMakeRect(margin, height - 110, width - margin * 2, 56), 40, NMShareInk(),
              NSFontWeightBold, NSTextAlignmentLeft);
  if (model.subtitle.length)
    NMShareText(model.subtitle, NSMakeRect(margin, height - 158, width - margin * 2, 34), 22,
                NMShareMuted(), NSFontWeightMedium, NSTextAlignmentLeft);
  [NMShareGold() setFill];
  NSRectFill(NSMakeRect(margin, height - 178, 64, 4));

  if (model.kind == NMShareCardKindMedal) {
    // 勋章圆盘
    CGFloat diameter = 220;
    NSRect disc = NSMakeRect((width - diameter) / 2, height - 470, diameter, diameter);
    NSColor *tier = NMShareTierColor(model.medalTier);
    [tier setFill];
    [[NSBezierPath bezierPathWithOvalInRect:disc] fill];
    [[NSColor colorWithCalibratedWhite:1 alpha:.85] setStroke];
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(disc, 14, 14)];
    ring.lineWidth = 6; [ring stroke];
    NSString *tierLabel = [model.medalTier isEqualToString:@"gold"] ? @"GOLD" :
        ([model.medalTier isEqualToString:@"silver"] ? @"SILVER" : @"BRONZE");
    NMShareText(tierLabel, NSMakeRect(NSMinX(disc), NSMidY(disc) - 20, diameter, 40), 30,
                [NSColor whiteColor], NSFontWeightHeavy, NSTextAlignmentCenter);
    // 主数值
    NSNumberFormatter *fmt = [NSNumberFormatter new];
    fmt.numberStyle = NSNumberFormatterDecimalStyle;
    NMShareText([fmt stringFromNumber:@(model.meritValue)],
                NSMakeRect(margin, height - 560, width - margin * 2, 60), 52, NMShareInk(),
                NSFontWeightBold, NSTextAlignmentCenter);
    if (model.medalEarnedDay.length) {
      NSString *line = [NSString stringWithFormat:@"%@ · #%ld",
                        model.medalEarnedDay, (long)model.medalCount];
      NMShareText(line, NSMakeRect(margin, height - 600, width - margin * 2, 30), 20,
                  NMShareMuted(), NSFontWeightRegular, NSTextAlignmentCenter);
    }
  } else {
    // 曲线柱状图
    NSArray<NSNumber *> *points = model.curvePoints ?: @[];
    NSRect plot = NSMakeRect(margin + 20, 220, width - margin * 2 - 40, height - 500);
    [[NSColor colorWithCalibratedWhite:.88 alpha:1] setStroke];
    NSBezierPath *axis = [NSBezierPath bezierPath];
    [axis moveToPoint:NSMakePoint(NSMinX(plot), NSMinY(plot))];
    [axis lineToPoint:NSMakePoint(NSMaxX(plot), NSMinY(plot))];
    axis.lineWidth = 1.5; [axis stroke];
    unsigned long long maxValue = 1;
    for (NSNumber *n in points) maxValue = MAX(maxValue, n.unsignedLongLongValue);
    if (points.count) {
      CGFloat slot = NSWidth(plot) / (CGFloat)points.count;
      CGFloat barWidth = MAX(2, slot * 0.64);
      NSArray *labels = model.curveLabels;
      for (NSUInteger i = 0; i < points.count; ++i) {
        unsigned long long v = points[i].unsignedLongLongValue;
        CGFloat h = NSHeight(plot) * (CGFloat)v / (CGFloat)maxValue;
        if (v > 0 && h < 2) h = 2;
        CGFloat cx = NSMinX(plot) + slot * (i + 0.5);
        [NMShareGold() setFill];
        NSRectFill(NSMakeRect(cx - barWidth / 2, NSMinY(plot), barWidth, h));
        if (labels.count == points.count && (points.count <= 12 || i % 4 == 0)) {
          NMShareText(labels[i], NSMakeRect(cx - 24, NSMinY(plot) - 24, 48, 18), 11,
                      NMShareMuted(), NSFontWeightRegular, NSTextAlignmentCenter);
        }
      }
    }
    NSNumberFormatter *fmt = [NSNumberFormatter new];
    fmt.numberStyle = NSNumberFormatterDecimalStyle;
    NMShareText([fmt stringFromNumber:@(model.meritValue)],
                NSMakeRect(margin, height - 300, width - margin * 2, 54), 46, NMShareInk(),
                NSFontWeightBold, NSTextAlignmentCenter);
  }

  // 金额（鼓励器）
  if (model.moneyDisplay.length) {
    NMShareText(model.moneyDisplay, NSMakeRect(margin, 150, width - margin * 2, 44), 30,
                NMShareGold(), NSFontWeightSemibold, NSTextAlignmentCenter);
  }
  // 页脚
  NSString *footer = model.footerWatermark.length ? model.footerWatermark : @"niuma-merit 0.9.6";
  NMShareText(footer, NSMakeRect(margin, 84, width - margin * 2, 24), 16, NMShareMuted(),
              NSFontWeightRegular, NSTextAlignmentCenter);
  if (model.footerProduct.length)
    NMShareText(model.footerProduct, NSMakeRect(margin, 108, width - margin * 2, 24), 16,
                NMShareMuted(), NSFontWeightMedium, NSTextAlignmentCenter);
  (void)NMShareTierColor;
  [NSGraphicsContext restoreGraphicsState];
  // properties:@{} => PNG 无文本块/元数据；再剔除 eXIf 等辅助块，仅保留像素。
  NSData *raw = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return NMPNGStripMetadata(raw);
}

// 统一“用户主动导出”保存流程；由系统保存面板选择路径，文件名不含本机路径。
static BOOL NMSaveShareCardPNG(NSData *png, NSWindow *parentWindow, NSString *defaultName) {
  (void)parentWindow;
  if (!png.length) return NO;
  NSSavePanel *panel = [NSSavePanel savePanel];
  panel.allowedFileTypes = @[ @"png" ];
  panel.nameFieldStringValue = defaultName.length ? defaultName : @"niuma-merit-share.png";
  panel.canCreateDirectories = YES;
  if ([panel runModal] != NSModalResponseOK) return NO;
  NSURL *url = panel.URL;
  if (!url) return NO;
  return [png writeToURL:url options:NSDataWritingAtomic error:nil];
}
