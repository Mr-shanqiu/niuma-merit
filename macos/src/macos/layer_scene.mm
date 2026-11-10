#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cmath>

// Reuse a small glyph atlas like a clock: changing a number replaces only
// affected digit contents. No typesetting or bitmap drawing on each keypress.
@interface NMNumberLayer : CALayer
@property(nonatomic, copy) NSString *text;
@property(nonatomic, strong) NSMutableDictionary<NSString *,id> *glyphs;
@property(nonatomic, strong) NSMutableDictionary<NSString *,NSNumber *> *advances;
@property(nonatomic, strong) NSMutableArray<CALayer *> *digits;
@property(nonatomic) CGSize layoutSize;
@property(nonatomic) CGFloat textWidth;
@property(nonatomic) CGFloat atlasSize;
@property(nonatomic) CGFloat atlasScale;
@property(nonatomic, strong) NSColor *atlasColor;
@property(nonatomic) BOOL rollEnabled;  // FB2：数字变化时末位做轻微上下滚动
- (BOOL)updateText:(NSString *)text size:(CGFloat)size color:(NSColor *)color;
- (void)rollLastDigitIfChangedFrom:(NSString *)oldText to:(NSString *)newText;
- (void)ensureGlyph:(NSString *)glyph;
@end
@implementation NMNumberLayer
- (BOOL)updateText:(NSString *)text size:(CGFloat)size color:(NSColor *)color {
  text=text ?: @"";
  CGFloat scale=MAX(1,self.contentsScale);
  BOOL rebuild=!self.glyphs || self.atlasSize!=size || self.atlasScale!=scale || ![self.atlasColor isEqual:color];
  if(!rebuild && [self.text isEqual:text]) return NO;
  if(rebuild) {
    self.glyphs=[NSMutableDictionary dictionary];self.advances=[NSMutableDictionary dictionary];
    self.atlasSize=size;self.atlasScale=scale;self.atlasColor=color;
  }
  if(!self.digits) self.digits=[NSMutableArray array];
  while(self.digits.count<text.length) { CALayer *digit=[CALayer layer];[self addSublayer:digit];[self.digits addObject:digit]; }
  while(self.digits.count>text.length) { [self.digits.lastObject removeFromSuperlayer];[self.digits removeLastObject]; }
  // FB5：按需为每个字符（数字、':'、'-'、货币符号、'.'、',' 等）生成字形，
  // 以便「今日工钱」金额能显示币种符号与小数点，而不是只剩数字。
  CGFloat total=0;
  for(NSUInteger i=0;i<text.length;i++) {
    NSString *g=[text substringWithRange:NSMakeRange(i,1)];
    [self ensureGlyph:g];
    total+=[self.advances[g] doubleValue];
  }
  BOOL layout=rebuild || self.text.length!=text.length || !CGSizeEqualToSize(self.layoutSize,self.bounds.size) || self.textWidth!=total;
  self.layoutSize=self.bounds.size;self.textWidth=total;
  CGFloat x=(self.bounds.size.width-total)/2;
  for(NSUInteger i=0;i<text.length;i++) {
    NSString *glyph=[text substringWithRange:NSMakeRange(i,1)];CALayer *digit=self.digits[i];
    CGFloat advance=[self.advances[glyph] doubleValue];
    if(rebuild || i>=self.text.length || ![[self.text substringWithRange:NSMakeRange(i,1)] isEqual:glyph]) digit.contents=self.glyphs[glyph];
    if(layout) {digit.contentsScale=scale;digit.frame=CGRectMake(x-4,self.bounds.size.height-40,ceil((advance+8)*scale)/scale,40);}
    x+=advance;
  }
  self.text=[text copy];return YES;
}

// 为单个字符按当前字号/缩放/颜色生成并缓存字形位图（按需构建，支持任意字符）。
- (void)ensureGlyph:(NSString *)glyph {
  if(!glyph.length || self.glyphs[glyph]) return;
  const CGFloat scale=MAX(1,self.atlasScale);
  NSFont *font=[NSFont monospacedDigitSystemFontOfSize:self.atlasSize weight:NSFontWeightRegular];
  NSShadow *shadow=[NSShadow new];shadow.shadowColor=[NSColor colorWithWhite:0 alpha:.8];
  shadow.shadowOffset=NSMakeSize(0,-1);shadow.shadowBlurRadius=2;
  NSDictionary *attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:self.atlasColor,
    NSStrokeColorAttributeName:[NSColor colorWithWhite:0 alpha:.7],NSStrokeWidthAttributeName:@(-2.5),NSShadowAttributeName:shadow};
  CGFloat advance=[glyph sizeWithAttributes:@{NSFontAttributeName:font}].width;
  NSInteger width=(NSInteger)ceil((advance+8)*scale),height=(NSInteger)ceil(40*scale);
  if(width<1) width=1;
  NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:width*4 bitsPerPixel:32];
  NSGraphicsContext *context=[NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  [NSGraphicsContext saveGraphicsState];NSGraphicsContext.currentContext=context;
  CGContextScaleCTM(context.CGContext,scale,scale);
  [glyph drawAtPoint:NSMakePoint(4,40-font.ascender+font.descender-2) withAttributes:attributes];
  [NSGraphicsContext restoreGraphicsState];
  self.glyphs[glyph]=(__bridge id)rep.CGImage;self.advances[glyph]=@(advance);
}

// FB7：里程表/老虎机式滚动——每个「变化的数字位」都做纵向滚轮动画：新数字从一侧滚入、
// 旧数字从另一侧滚出，方向按整体数值增减判定（金额增长时统一向上滚），因此 9→0 进位时
// 高位数字同步滚动，末位每次变化都在滚动，整体快速连续。仅 rollEnabled 时生效。
- (void)rollLastDigitIfChangedFrom:(NSString *)oldText to:(NSString *)newText {
  if (!self.rollEnabled || !self.digits.count) return;
  oldText = oldText ?: @"";
  newText = newText ?: @"";
  if (oldText.length == 0 || newText.length == 0) return;
  // 统一滚动方向：整体数值变大（含 9→0 进位）时向上滚，变小则向下滚。
  BOOL up = YES;
  if (newText.length > oldText.length) up = YES;
  else if (newText.length < oldText.length) up = NO;
  else up = ([newText compare:oldText] != NSOrderedAscending);
  const NSUInteger n = MIN(oldText.length, newText.length);
  const NSTimeInterval duration = 0.15;  // 比旧动画(0.28s)更快，形成连续滚动感
  CAMediaTimingFunction *curve =
      [CAMediaTimingFunction functionWithControlPoints:0.30f :0 :0.25f :1];
  for (NSUInteger k = 0; k < n; ++k) {
    unichar oc = [oldText characterAtIndex:oldText.length - 1 - k];
    unichar nc = [newText characterAtIndex:newText.length - 1 - k];
    if (oc == nc) continue;
    const BOOL od = (oc >= '0' && oc <= '9');
    const BOOL nd = (nc >= '0' && nc <= '9');
    if (!od || !nd) continue;  // 只滚动数字；货币符号/小数点直接就位
    const NSUInteger idx = newText.length - 1 - k;
    if (idx >= self.digits.count) continue;
    CALayer *digit = self.digits[idx];
    if (!digit) continue;
    const CGFloat h = digit.bounds.size.height > 0 ? digit.bounds.size.height : 40;
    const CGFloat travel = h * 0.9;
    // 旧数字滚出（临时叠层，动画结束后移除）。
    unichar oldChar = oc;
    id oldContents = self.glyphs[[NSString stringWithCharacters:&oldChar length:1]];
    if (oldContents) {
      CALayer *outgoing = [CALayer layer];
      outgoing.frame = digit.frame;
      outgoing.contents = oldContents;
      outgoing.contentsScale = digit.contentsScale;
      outgoing.contentsGravity = digit.contentsGravity;
      outgoing.minificationFilter = digit.minificationFilter;
      outgoing.magnificationFilter = digit.magnificationFilter;
      [self addSublayer:outgoing];
      CAKeyframeAnimation *outMove = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
      outMove.values = up ? @[@0, @(-travel)] : @[@0, @(travel)];
      outMove.keyTimes = @[@0, @1];
      outMove.duration = duration;
      outMove.timingFunction = curve;
      CAKeyframeAnimation *outFade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
      outFade.values = @[@1.0, @0.0];
      outFade.keyTimes = @[@0, @1];
      outFade.duration = duration;
      [CATransaction begin];
      [CATransaction setCompletionBlock:^{ [outgoing removeFromSuperlayer]; }];
      [outgoing addAnimation:outMove forKey:@"nmOutY"];
      [outgoing addAnimation:outFade forKey:@"nmOutFade"];
      [CATransaction commit];
    }
    // 新数字滚入。
    CAKeyframeAnimation *inMove = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.y"];
    inMove.values = up ? @[@(travel), @(0)] : @[@(-travel), @(0)];
    inMove.keyTimes = @[@0, @1];
    inMove.duration = duration;
    inMove.timingFunction = curve;
    CAKeyframeAnimation *inFade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    inFade.values = @[@0.35, @1.0];
    inFade.keyTimes = @[@0, @1];
    inFade.duration = duration;
    [digit addAnimation:inMove forKey:@"nmRollY"];
    [digit addAnimation:inFade forKey:@"nmRollFade"];
  }
}
@end

// FB7（重做）· 真·里程表/水表式连续滚动金额。
//
// 逐帧驱动（60fps NSTimer + 真实墙钟流逝时间），按「每秒金额」连续计算当前精确刻度
// （1e-5 元整数刻度 = double），每一位数字渲染成竖向数字带（0–9 循环），用裁剪只露一位；
// 低位连续移动 → 末位一直在转；某位 9→0 时高位自然跟着转（进位）；位数变长时平滑扩位。
// 降级：系统「减少动态」开启时直接显示静态数值，不滚动。分享卡不受影响（另走 §9 格式化）。
@interface NMOdometerLayer : CALayer
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic, strong) NSColor *numberColor;
@property(nonatomic) CGFloat fontSize;
@property(nonatomic) BOOL active;
@property(nonatomic) double wageTick;     // 「元 × 1e5」整数刻度/天（实值）
@property(nonatomic) int startSecond;     // 上班起（当日秒）
@property(nonatomic) int totalSeconds;    // 上学总秒
@property(nonatomic, strong) NSTimer *timer;
- (void)configureActive:(BOOL)active
               wageTick:(double)wageTick
            startSecond:(int)startSecond
           totalSeconds:(int)totalSeconds
                 symbol:(NSString *)symbol;
- (void)stop;
@end

@implementation NMOdometerLayer
- (instancetype)init {
  if ((self = [super init])) {
    _fontSize = 26.0;
    _numberColor = [NSColor colorWithCalibratedRed:.78 green:.39 blue:.12 alpha:1];
    self.masksToBounds = NO;
  }
  return self;
}
- (void)dealloc { [_timer invalidate]; }
- (BOOL)reduceMotion {
  if (@available(macOS 10.12, *)) return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
  return NO;
}
- (void)stop {
  [self.timer invalidate];
  self.timer = nil;
}
- (void)configureActive:(BOOL)active wageTick:(double)wageTick startSecond:(int)startSecond
           totalSeconds:(int)totalSeconds symbol:(NSString *)symbol {
  self.active = active;
  self.wageTick = wageTick;
  self.startSecond = startSecond;
  self.totalSeconds = totalSeconds;
  self.symbol = symbol ?: @"";
  [self stop];
  if (active) {
    const NSTimeInterval interval = [self reduceMotion] ? 1.0 : (1.0 / 60.0);
    self.timer = [NSTimer timerWithTimeInterval:interval target:self
        selector:@selector(frameTick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSModalPanelRunLoopMode];
  }
  [self setNeedsDisplay];
}
- (void)frameTick:(NSTimer *)timer { (void)timer; [self setNeedsDisplay]; }

// 连续的精确实值（刻度）：按真实墙钟（含小数秒）线性推算，到止点等于日薪 tick。
- (double)currentTickValue {
  if (self.totalSeconds <= 0 || self.wageTick <= 0) return 0.0;
  NSDate *now = NSDate.date;
  NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
  cal.timeZone = NSTimeZone.localTimeZone;
  NSDateComponents *c = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond)
                               fromDate:now];
  double sod = (double)c.hour * 3600.0 + (double)c.minute * 60.0 +
               (double)c.second + now.timeIntervalSince1970 - floor(now.timeIntervalSince1970);
  double elapsed = sod - (double)self.startSecond;
  if (elapsed < 0) elapsed = 0;
  if (elapsed > (double)self.totalSeconds) elapsed = (double)self.totalSeconds;
  return self.wageTick * elapsed / (double)self.totalSeconds;
}

- (void)drawInContext:(CGContextRef)ctx {
  NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = gc;

  const double V = self.active ? [self currentTickValue] : 0.0;
  NSFont *font = [NSFont monospacedDigitSystemFontOfSize:self.fontSize weight:NSFontWeightRegular];
  NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : self.numberColor};
  NSString *symbol = self.symbol ?: @"";
  const CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds);

  if ([self reduceMotion] || !self.active) {
    // 降级：直接显示静态数值（不滚动）。
    unsigned long long tick = (unsigned long long)llround(V < 0 ? 0 : V);
    unsigned long long whole = tick / 100000ULL, frac = tick % 100000ULL;
    NSString *text = [NSString stringWithFormat:@"%@%llu.%05llu", symbol, whole, frac];
    CGFloat tw = [text sizeWithAttributes:attrs].width;
    CGFloat th = [text sizeWithAttributes:attrs].height;
    [text drawAtPoint:NSMakePoint((W - tw) / 2.0, (H - th) / 2.0) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
    return;
  }

  // 固定等宽槽 + 统一基线 + 机械里程表位移模型（FB14 修对齐/宽度/基线）。
  const CGFloat symbolW = symbol.length ? [symbol sizeWithAttributes:attrs].width : 0.0;
  const CGFloat digitAdv = ceil([@"0" sizeWithAttributes:attrs].width) + 2.0;
  const CGFloat dotAdv = ceil([@"." sizeWithAttributes:attrs].width) + 2.0;
  // 当前整数位数（至少 1）；小数固定 5 位。位数随金额增长平滑扩位。
  unsigned long long whole = (unsigned long long)floor(V / 100000.0);
  int intDigits = 1;
  for (unsigned long long w = whole; w >= 10; w /= 10) ++intDigits;
  const int maxE = intDigits + 4;  // 指数：0=末位(1 tick)，4=第 5 位小数，maxE=最高整数位
  const int slotCount = maxE + 1;
  const CGFloat totalW = symbolW + (CGFloat)slotCount * digitAdv + dotAdv;
  CGFloat x = (W - totalW) / 2.0;
  if (x < 2) x = 2;
  const CGFloat lineH = H;          // 裁剪槽高 = 一行字高，只露一位
  const CGFloat slotY = 0;
  // 统一基线：所有数字轮 / 币种符号 / 小数点共用同一条基线，在槽内垂直居中。
  const CGFloat textH = font.ascender - font.descender;
  const CGFloat baselineY = slotY + (lineH - textH) / 2.0 - font.descender;

  if (symbolW > 0) { [symbol drawAtPoint:NSMakePoint(x, baselineY) withAttributes:attrs]; x += symbolW; }
  for (int e = maxE; e >= 0; --e) {
    if (e == 4) {  // 小数点：整数与 5 位小数之间（同基线静态排版）
      [@"." drawAtPoint:NSMakePoint(x, baselineY) withAttributes:attrs];
      x += dotAdv;
    }
    const double p = pow(10.0, (double)e);
    const long long digit = (long long)floor(V / p);
    const int cur = (int)(((digit % 10) + 10) % 10);
    // 机械里程表模型：末位(e=0)始终连续转；更高位仅在其低位临近进位(…99→…00)时
    // 0→1 滚动，其余时间静止对齐——避免每位各带随机小数导致整串散架。
    double frac;
    if (e == 0) {
      frac = V - floor(V);
    } else {
      const double lower = fmod(V, p);
      frac = lower - (p - 1.0);
      if (frac < 0) frac = 0;
      if (frac > 1) frac = 1;
    }
    const int next = (cur + 1) % 10;
    NSString *dcur = [NSString stringWithFormat:@"%d", cur];
    NSString *dnext = [NSString stringWithFormat:@"%d", next];
    const CGFloat gx = x + (digitAdv - [dcur sizeWithAttributes:attrs].width) / 2.0;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(x, slotY, digitAdv, lineH));
    // 当前位随 frac 上移出槽，下一位自下方滚入（同一条数字带、同一基线）。
    [dcur drawAtPoint:NSMakePoint(gx, baselineY + (CGFloat)frac * lineH) withAttributes:attrs];
    [dnext drawAtPoint:NSMakePoint(gx, baselineY + ((CGFloat)frac - 1.0) * lineH) withAttributes:attrs];
    CGContextRestoreGState(ctx);
    x += digitAdv;
  }
  [NSGraphicsContext restoreGraphicsState];
}
@end

// A scene owns only the current picture set. Cached pixels are submitted once;
// Core Animation interpolates each scalar using the pack's original curve.
@interface NMLayerScene : NSObject
@property(nonatomic, strong) CALayer *root;
@property(nonatomic, strong) CALayer *artwork;
@property(nonatomic, strong) NMNumberLayer *counter;
@property(nonatomic, strong) CATextLayer *feedback;
@property(nonatomic, strong) CATextLayer *offworkLabel;
@property(nonatomic, strong) NMNumberLayer *offworkDuration;
@property(nonatomic, strong) CATextLayer *encouragerLabel;
@property(nonatomic, strong) NMNumberLayer *encouragerAmount;
@property(nonatomic, strong) NMOdometerLayer *encouragerOdometer;  // FB7 连续里程表金额
@property(nonatomic) BOOL encouragerOdometerActive;
@property(nonatomic) BOOL encouragerVisible;
@property(nonatomic, strong) CALayer *encouragerBarBack;
@property(nonatomic, strong) CALayer *encouragerBarFill;
@property(nonatomic) double encouragerProgress;
@property(nonatomic) CGFloat layoutOffworkHeight;
@property(nonatomic) CGFloat layoutEncouragerHeight;
@property(nonatomic, copy) NSArray<NSDictionary *> *descriptors;
@property(nonatomic, copy) NSArray<NSArray<CALayer *> *> *nodes;
@property(nonatomic, copy) NSArray<NSDictionary *> *animationTemplates;
@property(nonatomic, strong) CAKeyframeAnimation *feedbackTemplate;
@property(nonatomic) CGFloat layoutScale;
@property(nonatomic) CGFloat layoutBacking;
@property(nonatomic) CGFloat layoutOffset;
@property(nonatomic) BOOL layoutPreview;
@property(nonatomic) BOOL layoutValid;
@property(nonatomic) NSUInteger sceneGeneration;
@property(nonatomic) NSUInteger sceneBuilds;
@property(nonatomic) NSUInteger animationSubmissions;
@property(nonatomic) NSUInteger textUpdates;
- (instancetype)initWithRoot:(CALayer *)root;
- (void)installLayers:(NSArray<NSDictionary *> *)layers images:(NSDictionary<NSString *,NSImage *> *)images;
- (void)layoutWithScale:(CGFloat)scale backing:(CGFloat)backing offset:(CGFloat)offset preview:(BOOL)preview;
- (void)layoutWithScale:(CGFloat)scale backing:(CGFloat)backing
          offworkHeight:(CGFloat)offworkHeight encouragerHeight:(CGFloat)encouragerHeight
                preview:(BOOL)preview;
- (void)setCounter:(NSString *)counter label:(NSString *)label duration:(NSString *)duration;
- (void)setEncouragerLabel:(NSString *)label amount:(NSString *)amount progress:(double)progress visible:(BOOL)visible;
- (void)setEncouragerOdometerActive:(BOOL)active wageTick:(double)wageTick
                        startSecond:(int)startSecond totalSeconds:(int)totalSeconds
                             symbol:(NSString *)symbol;
- (void)applyEncouragerBar;
- (void)play:(NSTimeInterval)duration;
- (void)play:(NSTimeInterval)duration atTime:(CFTimeInterval)start;
- (void)stop;
@end

static void NMNoImplicit(void (^changes)(void)) {
  [CATransaction begin]; [CATransaction setDisableActions:YES]; changes(); [CATransaction commit];
}
static CAKeyframeAnimation *NMScalarAnimation(NSDictionary *descriptor, NSString *property,
                                             NSString *field, double base, double factor,
                                             NSTimeInterval duration) {
  NSArray<NSDictionary *> *frames = descriptor[@"keyframes"];
  NSMutableArray *values = [NSMutableArray array], *times = [NSMutableArray array];
  NSMutableArray *curves = [NSMutableArray array];
  BOOL smooth = [descriptor[@"interpolation"] isEqual:@"smoothstep"];
  CAMediaTimingFunction *curve = smooth
      ? [CAMediaTimingFunction functionWithControlPoints:1.0f/3 :0 :2.0f/3 :1]
      : [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
  auto append = ^(double t, double value) {
    if (values.count) [curves addObject:curve];
    [times addObject:@(t)]; [values addObject:@(base + factor * value)];
  };
  double fallback = ([field isEqual:@"scale_y"] || [field isEqual:@"scale"]) ? 1 : 0;
  if ([frames.firstObject[@"t"] doubleValue] > 0)
    append(0, [(frames.firstObject[field] ?: @(fallback)) doubleValue]);
  for (NSDictionary *frame in frames) append([frame[@"t"] doubleValue], [(frame[field] ?: @(fallback)) doubleValue]);
  if ([times.lastObject doubleValue] < 1) append(1, [(frames.lastObject[field] ?: @(fallback)) doubleValue]);
  if (values.count == 1) append(1, [(frames.firstObject[field] ?: @(fallback)) doubleValue]);
  CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:property];
  animation.values = values; animation.keyTimes = times; animation.timingFunctions = curves;
  animation.duration = duration; animation.calculationMode = kCAAnimationLinear;
  animation.removedOnCompletion = YES;
  return animation;
}
static CATextLayer *NMSceneText(CGRect frame, CGFloat size, NSColor *color) {
  CATextLayer *layer = [CATextLayer layer]; layer.frame = frame;
  layer.fontSize = size; layer.alignmentMode = kCAAlignmentCenter;
  layer.foregroundColor = color.CGColor;
  layer.shadowColor = NSColor.blackColor.CGColor; layer.shadowOpacity = .8;
  layer.shadowOffset = CGSizeMake(0,-1); layer.shadowRadius = 2;
  return layer;
}
static void NMSetSceneText(CATextLayer *layer, NSString *value, CGFloat size, NSColor *color) {
  layer.string = value.length ? [[NSAttributedString alloc] initWithString:value attributes:@{
    NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular],
    NSForegroundColorAttributeName:color,
    NSStrokeColorAttributeName:[NSColor colorWithWhite:0 alpha:.7], NSStrokeWidthAttributeName:@(-2.5)
  }] : nil;
}
@implementation NMLayerScene
- (instancetype)initWithRoot:(CALayer *)root {
  if ((self = [super init])) {
    _root = [CALayer layer]; _root.anchorPoint = CGPointZero; _root.position = CGPointZero;
    [root addSublayer:_root];
    _artwork = [CALayer layer]; _artwork.frame = CGRectMake(0,0,240,170); _artwork.masksToBounds = YES;
    [_root addSublayer:_artwork];
    _counter = [NMNumberLayer layer];_counter.frame=CGRectMake(0,210,240,40);
    _feedback = NMSceneText(CGRectMake(0,174,240,30),23,NSColor.orangeColor); _feedback.opacity = 0;
    NMSetSceneText(_feedback,@"+1",23,[NSColor colorWithCalibratedRed:.94 green:.50 blue:.16 alpha:1]);
    _feedbackTemplate=[CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    _feedbackTemplate.values=@[@0,@1,@0,@0];_feedbackTemplate.keyTimes=@[@0,@.30,@.70,@1];
    _feedbackTemplate.calculationMode=kCAAnimationDiscrete;
    _offworkLabel = NMSceneText(CGRectMake(0,55,240,28),24,NSColor.orangeColor);
    _offworkDuration = [NMNumberLayer layer];_offworkDuration.frame=CGRectMake(0,14,240,35);
    _encouragerLabel = NMSceneText(CGRectMake(0,0,240,22),15,NSColor.orangeColor);
    _encouragerAmount = [NMNumberLayer layer];
    _encouragerAmount.frame = CGRectMake(0,0,240,30);
    _encouragerAmount.rollEnabled = YES;  // FB2 数字跳动动效（倒计时主信息用）
    _encouragerOdometer = [NMOdometerLayer layer];
    _encouragerOdometer.frame = CGRectMake(0,0,240,30);
    _encouragerOdometer.hidden = YES;
    _encouragerBarBack = [CALayer layer];
    _encouragerBarBack.backgroundColor = [NSColor colorWithCalibratedWhite:0 alpha:.18].CGColor;
    _encouragerBarBack.cornerRadius = 4;
    _encouragerBarFill = [CALayer layer];
    _encouragerBarFill.backgroundColor = NSColor.orangeColor.CGColor;
    _encouragerBarFill.cornerRadius = 4;
    [_encouragerBarBack addSublayer:_encouragerBarFill];
    for (CALayer *layer in @[_counter,_feedback,_offworkLabel,_offworkDuration,
                             _encouragerLabel,_encouragerAmount,_encouragerOdometer,_encouragerBarBack])
      [_root addSublayer:layer];
  } return self;
}
- (void)installLayers:(NSArray<NSDictionary *> *)layers images:(NSDictionary<NSString *,NSImage *> *)images {
  [self stop]; self.sceneGeneration++; self.sceneBuilds++;
  NMNoImplicit(^{ self.artwork.sublayers = nil; });
  NSMutableArray *nodes = [NSMutableArray array];
  for (NSDictionary *descriptor in layers) {
    NSArray *frame = descriptor[@"frame"], *anchor = descriptor[@"anchor"];
    double w=[frame[2] doubleValue], h=[frame[3] doubleValue];
    double ax=w*[anchor[0] doubleValue], ay=h*[anchor[1] doubleValue];
    CALayer *position=[CALayer layer], *rotation=[CALayer layer], *scale=[CALayer layer], *stretch=[CALayer layer];
    CALayer *image=[CALayer layer]; image.anchorPoint=CGPointZero;
    image.frame=CGRectMake(-ax,-ay,w,h);
    NSImage *source=images[descriptor[@"image"]];
    CGImageRef pixels=[source CGImageForProposedRect:NULL context:nil hints:nil];
    image.contents=(__bridge id)pixels; image.contentsGravity=kCAGravityResize;
    image.minificationFilter=kCAFilterTrilinear; image.magnificationFilter=kCAFilterLinear;
    if ([descriptor[@"contentsRect"] isKindOfClass:NSArray.class]) {
      NSArray *r=descriptor[@"contentsRect"];
      image.contentsRect=CGRectMake([r[0] doubleValue],[r[1] doubleValue],[r[2] doubleValue],[r[3] doubleValue]);
    }
    if ([descriptor[@"flip"] boolValue]) image.transform=CATransform3DMakeScale(1,-1,1);
    [stretch addSublayer:image]; [scale addSublayer:stretch]; [rotation addSublayer:scale];
    [position addSublayer:rotation]; [self.artwork addSublayer:position];
    [nodes addObject:@[position,rotation,scale,stretch]];
  }
  self.descriptors=layers; self.nodes=nodes; [self applyRestPose];
  NSMutableArray *templates=[NSMutableArray array];
  [self.nodes enumerateObjectsUsingBlock:^(NSArray<CALayer *> *node,NSUInteger i,BOOL *) {
    NSDictionary *d=self.descriptors[i];NSArray *r=d[@"frame"],*a=d[@"anchor"];
    double ax=[r[0] doubleValue]+[r[2] doubleValue]*[a[0] doubleValue];
    double ay=[r[1] doubleValue]+[r[3] doubleValue]*[a[1] doubleValue];
    NSArray *specs=@[@[@0,@"position.x",@"x",@(ax),@1],@[@0,@"position.y",@"y",@(ay),@1],
      @[@0,@"opacity",@"alpha",@0,@1],@[@1,@"transform.rotation.z",@"rotation",@0,@(M_PI/180)],
      @[@2,@"transform.scale",@"scale",@0,@1],@[@3,@"transform.scale.y",@"scale_y",@0,@1]];
    for(NSArray *spec in specs) {
      CAKeyframeAnimation *animation=NMScalarAnimation(d,spec[1],spec[2],[spec[3] doubleValue],[spec[4] doubleValue],1);
      BOOL constant=YES;for(NSNumber *v in animation.values) if(![v isEqual:animation.values.firstObject]) {constant=NO;break;}
      if(!constant) [templates addObject:@{@"layer":node[[spec[0] unsignedIntegerValue]],@"animation":animation,@"key":spec[1]}];
    }
  }];self.animationTemplates=templates;
}
- (void)layoutWithScale:(CGFloat)scale backing:(CGFloat)backing offset:(CGFloat)offset preview:(BOOL)preview {
  // Back-compat shim: treat offset as the offwork region only.
  [self layoutWithScale:scale backing:backing offworkHeight:offset encouragerHeight:0 preview:preview];
}
- (void)layoutWithScale:(CGFloat)scale backing:(CGFloat)backing
          offworkHeight:(CGFloat)offworkHeight encouragerHeight:(CGFloat)encouragerHeight
                preview:(BOOL)preview {
  if(self.layoutValid && self.layoutScale==scale && self.layoutBacking==backing &&
     self.layoutOffworkHeight==offworkHeight && self.layoutEncouragerHeight==encouragerHeight &&
     self.layoutPreview==preview) { [self applyEncouragerBar]; return; }
  self.layoutValid=YES;self.layoutScale=scale;self.layoutBacking=backing;
  self.layoutOffworkHeight=offworkHeight;self.layoutEncouragerHeight=encouragerHeight;
  self.layoutPreview=preview;
  const CGFloat bottom = offworkHeight + encouragerHeight;
  NMNoImplicit(^{
    self.root.affineTransform=CGAffineTransformMakeScale(scale,scale);
    self.root.bounds=CGRectMake(0,0,240,250+bottom);
    self.artwork.frame=CGRectMake(0,bottom,240,170);
    self.counter.frame=CGRectMake(0,210+bottom,240,40);
    self.feedback.frame=CGRectMake(0,174+bottom,240,30);
    self.counter.hidden=preview; self.feedback.hidden=preview;
    // 下班倒计时区域：位于鼓励器区域之上（若两者同开）。
    self.offworkLabel.frame=CGRectMake(0,encouragerHeight+55,240,28);
    self.offworkDuration.frame=CGRectMake(0,encouragerHeight+14,240,35);
    self.offworkLabel.hidden=preview || offworkHeight==0;
    self.offworkDuration.hidden=preview || offworkHeight==0;
    // 鼓励器区域：最底部 84pt。FB13：顶部进度条 + 主信息 + 副信息。
    self.encouragerBarBack.frame=CGRectMake(20,encouragerHeight-12,200,8);
    self.encouragerAmount.frame=CGRectMake(0,encouragerHeight-46,240,30);
    self.encouragerOdometer.frame=CGRectMake(0,encouragerHeight-46,240,30);
    self.encouragerLabel.frame=CGRectMake(0,encouragerHeight-72,240,22);
    const BOOL showEnc = !preview && encouragerHeight>0;
    self.encouragerVisible=showEnc;
    self.encouragerLabel.hidden=!showEnc;
    self.encouragerAmount.hidden=!showEnc || self.encouragerOdometerActive;
    self.encouragerOdometer.hidden=!showEnc || !self.encouragerOdometerActive;
    self.encouragerBarBack.hidden=!showEnc;
    for (CALayer *layer in @[self.counter,self.feedback,self.offworkLabel,self.offworkDuration,
                             self.encouragerLabel,self.encouragerAmount,self.encouragerOdometer,self.encouragerBarBack])
      layer.contentsScale=MAX(1,backing*scale);
    [self applyEncouragerBar];
  });
}
- (void)applyEncouragerBar {
  const CGFloat width = 200.0 * (CGFloat)std::clamp(self.encouragerProgress, 0.0, 1.0);
  CGFloat maxWidth = self.encouragerBarBack.bounds.size.width;
  if (maxWidth <= 0) maxWidth = 200;
  self.encouragerBarFill.frame = CGRectMake(0, 0, maxWidth * (CGFloat)std::clamp(self.encouragerProgress,0.0,1.0), 8);
  (void)width;
}
- (void)setCounter:(NSString *)counter label:(NSString *)label duration:(NSString *)duration {
  NSColor *color=[NSColor colorWithCalibratedRed:.78 green:.39 blue:.12 alpha:1];
  NMNoImplicit(^{
    if([self.counter updateText:counter size:counter.length>18?22:26 color:color]) self.textUpdates++;
    if([self.offworkDuration updateText:duration size:24 color:color]) self.textUpdates++;
    NSString *old=[self.offworkLabel.string isKindOfClass:NSAttributedString.class] ? [self.offworkLabel.string string] : self.offworkLabel.string;
    if(![old isEqual:label ?: @""]) { NMSetSceneText(self.offworkLabel,label,24,color);self.textUpdates++; }
  });
}
- (void)setEncouragerLabel:(NSString *)label amount:(NSString *)amount progress:(double)progress visible:(BOOL)visible {
  NSColor *color=[NSColor colorWithCalibratedRed:.78 green:.39 blue:.12 alpha:1];
  self.encouragerProgress = progress;
  self.encouragerVisible = visible;
  NMNoImplicit(^{
    NSString *oldLabel=[self.encouragerLabel.string isKindOfClass:NSAttributedString.class] ? [self.encouragerLabel.string string] : self.encouragerLabel.string;
    if(![oldLabel isEqual:label ?: @""]) { NMSetSceneText(self.encouragerLabel,label,15,color);self.textUpdates++; }
    // 里程表激活时金额由 NMOdometerLayer 逐帧绘制；此处只维护倒计时等文本金额。
    if (!self.encouragerOdometerActive) {
      NSString *oldAmount = self.encouragerAmount.text ?: @"";
      if(![oldAmount isEqual:amount ?: @""]) {
        [self.encouragerAmount updateText:(amount ?: @"") size:26 color:color];
        self.textUpdates++;
        [self.encouragerAmount rollLastDigitIfChangedFrom:oldAmount to:amount ?: @""];
      }
    }
    self.encouragerAmount.hidden = !visible || self.encouragerOdometerActive;
    self.encouragerOdometer.hidden = !visible || !self.encouragerOdometerActive;
    [self applyEncouragerBar];
  });
}

// FB7：配置/开关连续里程表金额层（主信息为「今日已赚」时启用）。
- (void)setEncouragerOdometerActive:(BOOL)active wageTick:(double)wageTick
                        startSecond:(int)startSecond totalSeconds:(int)totalSeconds
                             symbol:(NSString *)symbol {
  self.encouragerOdometerActive = active;
  [self.encouragerOdometer configureActive:active wageTick:wageTick startSecond:startSecond
                              totalSeconds:totalSeconds symbol:symbol];
  self.encouragerAmount.hidden = !self.encouragerVisible || active;
  self.encouragerOdometer.hidden = !self.encouragerVisible || !active;
}

- (void)applyRestPose {
  NMNoImplicit(^{
    [self.feedback removeAllAnimations]; self.feedback.opacity=0;
    [self.nodes enumerateObjectsUsingBlock:^(NSArray<CALayer *> *node, NSUInteger i, BOOL *) {
      NSDictionary *d=self.descriptors[i]; NSArray *r=d[@"frame"],*a=d[@"anchor"];
      NSDictionary *f=NMFrameAtPhase(d[@"keyframes"],0,[d[@"interpolation"] isEqual:@"smoothstep"]);
      for (CALayer *layer in node) [layer removeAllAnimations];
      node[0].position=CGPointMake([r[0] doubleValue]+[r[2] doubleValue]*[a[0] doubleValue]+[f[@"x"] doubleValue],
                                   [r[1] doubleValue]+[r[3] doubleValue]*[a[1] doubleValue]+[f[@"y"] doubleValue]);
      node[0].opacity=[f[@"alpha"] floatValue];
      node[1].transform=CATransform3DMakeRotation([f[@"rotation"] doubleValue]*M_PI/180,0,0,1);
      node[2].transform=CATransform3DMakeScale([f[@"scale"] doubleValue],[f[@"scale"] doubleValue],1);
      node[3].transform=CATransform3DMakeScale(1,[(f[@"scale_y"] ?: @1) doubleValue],1);
    }];
  });
}
- (void)stop {
  [self.encouragerOdometer stop];
  [self.feedback removeAllAnimations];
  for(NSArray<CALayer *> *node in self.nodes) for(CALayer *layer in node)
    if(layer.animationKeys.count) [layer removeAllAnimations];
}
- (void)play:(NSTimeInterval)duration { [self play:duration atTime:CACurrentMediaTime()]; }
- (void)play:(NSTimeInterval)duration atTime:(CFTimeInterval)start {
  self.animationSubmissions++;
  for(NSDictionary *item in self.animationTemplates) {
    CAKeyframeAnimation *animation=item[@"animation"];animation.duration=duration;
    animation.beginTime=[item[@"layer"] convertTime:start fromLayer:nil];
    [item[@"layer"] addAnimation:animation forKey:item[@"key"]];
  }
  self.feedbackTemplate.duration=duration;
  self.feedbackTemplate.beginTime=[self.feedback convertTime:start fromLayer:nil];
  [self.feedback addAnimation:self.feedbackTemplate forKey:@"feedback"];
}
@end
