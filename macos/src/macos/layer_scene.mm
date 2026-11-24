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
  NSDictionary *attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:self.atlasColor};
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
static NSInteger NMOdoDigits(unsigned long long v) { NSInteger n = 1; while (v >= 10) { v /= 10; ++n; } return n; }

@interface NMOdometerLayer : CALayer
@property(nonatomic, copy) NSString *symbol;
@property(nonatomic, strong) NSColor *numberColor;
@property(nonatomic) CGFloat fontSize;
@property(nonatomic) BOOL active;
@property(nonatomic) int decimals;
@property(nonatomic) double wageTick;
@property(nonatomic) int startSecond;
@property(nonatomic) int totalSeconds;
@property(nonatomic, strong) NSTimer *timer;
- (void)configureActive:(BOOL)active
               wageTick:(double)wageTick
            startSecond:(int)startSecond
           totalSeconds:(int)totalSeconds
                 symbol:(NSString *)symbol
               decimals:(int)decimals;
- (void)stop;
@end

static CGImageRef NMOdoCreateImage(CGFloat w, CGFloat h, CGFloat scale, void (^draw)(NSGraphicsContext *g)) {
  size_t pw = (size_t)ceil((double)w * scale), ph = (size_t)ceil((double)h * scale);
  if (pw < 1 || ph < 1) return NULL;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef c = CGBitmapContextCreate(NULL, pw, ph, 8, pw * 4, cs,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!c) return NULL;
  CGContextScaleCTM(c, scale, scale);
  NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithCGContext:c flipped:NO];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = g;
  if (draw) draw(g);
  [NSGraphicsContext restoreGraphicsState];
  CGImageRef img = CGBitmapContextCreateImage(c);
  CGContextRelease(c);
  return img;
}

@implementation NMOdometerLayer {
  NSMutableArray<CALayer *> *_slotLayers;
  NSMutableArray<CALayer *> *_stripLayers;
  NSMutableArray<NSNumber *> *_curDigit;
  NSMutableArray<NSNumber *> *_slotExp;
  CALayer *_staticLayer;
  CGImageRef _stripCG;
  CGFloat _cellW, _cellH, _lineH, _pad;
  NSInteger _builtIntDigits, _builtDec;
  BOOL _running, _caMode;
  BOOL _cfgActive; double _cfgWageTick; int _cfgStart, _cfgTotal, _cfgDec; NSString *_cfgSymbol;
}

- (instancetype)init {
  if ((self = [super init])) {
    _fontSize = 26.0; _decimals = 2;
    _numberColor = [NSColor colorWithCalibratedRed:.95 green:.72 blue:.33 alpha:1];
    self.masksToBounds = YES;
    _slotLayers = [NSMutableArray array]; _stripLayers = [NSMutableArray array];
    _curDigit = [NSMutableArray array]; _slotExp = [NSMutableArray array];
    _builtIntDigits = -1; _builtDec = -1; _pad = 1.0;
  }
  return self;
}
- (void)dealloc { [_timer invalidate]; if (_stripCG) CGImageRelease(_stripCG); }
- (BOOL)reduceMotion { if (@available(macOS 10.12, *)) return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion; return NO; }
- (void)stop { [self.timer invalidate]; self.timer = nil; _running = NO; }

- (double)currentTickValue {
  if (self.totalSeconds <= 0 || self.wageTick <= 0) return 0.0;
  NSDate *now = NSDate.date;
  NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
  cal.timeZone = NSTimeZone.localTimeZone;
  NSDateComponents *c = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond) fromDate:now];
  double sod = (double)c.hour * 3600.0 + (double)c.minute * 60.0 + (double)c.second + now.timeIntervalSince1970 - floor(now.timeIntervalSince1970);
  double elapsed = sod - (double)self.startSecond;
  if (elapsed < 0) elapsed = 0;
  if (elapsed > (double)self.totalSeconds) elapsed = (double)self.totalSeconds;
  return self.wageTick * elapsed / (double)self.totalSeconds;
}
- (unsigned long long)currentS {
  double unitVal = 0.0;
  if (self.totalSeconds > 0 && self.wageTick > 0) unitVal = [self currentTickValue] / 100000.0;
  const int dec = self.decimals < 0 ? 0 : self.decimals;
  double p = 1.0; for (int i = 0; i < dec; ++i) p *= 10.0;
  long double sv = (long double)unitVal * p;
  if (sv < 0) sv = 0;
  return (unsigned long long)llround((double)sv);
}
- (int)digitForExp:(int)exp S:(unsigned long long)S {
  unsigned long long d = S; for (int i = 0; i < exp; ++i) d /= 10ULL; return (int)(d % 10ULL);
}
- (void)buildStripImageIfNeeded {
  if (_stripCG) { CGImageRelease(_stripCG); _stripCG = NULL; }
  CGFloat scale = self.contentsScale > 0 ? self.contentsScale : 2.0;
  NSFont *font = [NSFont monospacedDigitSystemFontOfSize:self.fontSize weight:NSFontWeightRegular];
  CGFloat cellW = ceil([@"0" sizeWithAttributes:@{NSFontAttributeName : font}].width) + _pad + 1.0;
  NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : self.numberColor};
  CGFloat baseline = (_lineH - (font.ascender - font.descender)) / 2.0 - font.descender;
  _stripCG = NMOdoCreateImage(cellW, 21 * _lineH, scale, ^(NSGraphicsContext *g) {
    for (int i = 0; i < 21; ++i) {
      NSString *s = [NSString stringWithFormat:@"%d", i % 10];
      CGFloat sw = [s sizeWithAttributes:attrs].width;
      [s drawAtPoint:NSMakePoint((cellW - sw) / 2.0, i * self->_lineH + baseline) withAttributes:attrs];
    }
  });
  _cellW = cellW;
}
- (void)buildStaticImageWithFont:(NSFont *)font attrs:(NSDictionary *)attrs layout:(NSArray<NSDictionary *> *)items width:(CGFloat)W {
  CGFloat scale = self.contentsScale > 0 ? self.contentsScale : 2.0;
  CGFloat baseline = (_lineH - (font.ascender - font.descender)) / 2.0 - font.descender;
  CGImageRef img = NMOdoCreateImage(W, _lineH, scale, ^(NSGraphicsContext *g) {
    for (NSDictionary *it in items) {
      NSString *t = it[@"text"]; CGFloat x = [it[@"x"] doubleValue];
      if (t.length) [t drawAtPoint:NSMakePoint(x, baseline) withAttributes:attrs];
    }
  });
  if (!_staticLayer) { _staticLayer = [CALayer layer]; _staticLayer.anchorPoint = CGPointZero; [self addSublayer:_staticLayer]; }
  _staticLayer.frame = CGRectMake(0, 0, W, _lineH);
  _staticLayer.contentsScale = scale;
  _staticLayer.contents = (__bridge id)img;
  if (img) CGImageRelease(img);
}
- (void)addSlotX:(CGFloat)x exp:(int)exp {
  CALayer *slot = [CALayer layer];
  slot.frame = CGRectMake(x, 0, _cellW, _cellH);
  slot.masksToBounds = YES;
  [self addSublayer:slot];
  CALayer *strip = [CALayer layer];
  strip.anchorPoint = CGPointZero;
  strip.frame = CGRectMake(0, 0, _cellW, 21 * _cellH);
  strip.contentsScale = self.contentsScale > 0 ? self.contentsScale : 2.0;
  strip.contents = (__bridge id)_stripCG;
  [slot addSublayer:strip];
  [_slotLayers addObject:slot]; [_stripLayers addObject:strip];
  [_curDigit addObject:@0]; [_slotExp addObject:@(exp)];
}
- (void)snapToCurrent {
  if (!_caMode) return;
  unsigned long long S = [self currentS];
  for (NSInteger i = 0; i < _slotLayers.count; ++i) {
    int exp = [_slotExp[i] intValue];
    int d = [self digitForExp:exp S:S];
    _curDigit[i] = @(d);
    CALayer *strip = _stripLayers[i];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    strip.position = CGPointMake(0, -(CGFloat)d * _cellH);
    [CATransaction commit];
  }
}
- (void)rebuild {
  for (CALayer *l in _slotLayers) [l removeFromSuperlayer];
  [_slotLayers removeAllObjects]; [_stripLayers removeAllObjects];
  [_curDigit removeAllObjects]; [_slotExp removeAllObjects];
  const CGFloat W = NSWidth(self.bounds);
  _lineH = NSHeight(self.bounds);
  const int dec = self.decimals < 0 ? 0 : self.decimals;
  unsigned long long intPart = [self currentS];
  for (int i = 0; i < dec; ++i) intPart /= 10ULL;
  NSInteger intDigits = NMOdoDigits(intPart); if (intDigits < 1) intDigits = 1;
  NSString *symbol = self.symbol ?: @"";
  CGFloat use = self.fontSize, cellW = 0, symbolW = 0, commaW = 0, dotW = 0, totalW = 0;
  NSFont *font = nil; NSDictionary *attrs = nil;
  for (int pass = 0; pass < 6; ++pass) {
    font = [NSFont monospacedDigitSystemFontOfSize:use weight:NSFontWeightRegular];
    attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : self.numberColor};
    cellW = ceil([@"0" sizeWithAttributes:attrs].width) + _pad + 1.0;
    symbolW = symbol.length ? [symbol sizeWithAttributes:attrs].width : 0.0;
    commaW = ceil([@"," sizeWithAttributes:attrs].width);
    dotW = ceil([@"." sizeWithAttributes:attrs].width);
    NSInteger commas = (intDigits - 1) / 3;
    totalW = symbolW + cellW * (intDigits + dec) + commaW * commas + (dec > 0 ? dotW : 0.0);
    if (totalW <= W - 12.0 || use <= 9.0) break;
    use *= (W - 12.0) / totalW; if (use < 9.0) use = 9.0;
  }
  font = [NSFont monospacedDigitSystemFontOfSize:use weight:NSFontWeightRegular];
  attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : self.numberColor};
  cellW = ceil([@"0" sizeWithAttributes:attrs].width) + _pad + 1.0;
  symbolW = symbol.length ? [symbol sizeWithAttributes:attrs].width : 0.0;
  commaW = ceil([@"," sizeWithAttributes:attrs].width);
  dotW = ceil([@"." sizeWithAttributes:attrs].width);
  NSInteger commas = (intDigits - 1) / 3;
  totalW = symbolW + cellW * (intDigits + dec) + commaW * commas + (dec > 0 ? dotW : 0.0);
  _cellW = cellW; _cellH = _lineH;
  CGFloat x = (W - totalW) / 2.0; if (x < 2) x = 2;
  NSMutableArray<NSDictionary *> *statics = [NSMutableArray array];
  if (symbolW > 0) { [statics addObject:@{@"text": symbol, @"x": @(x)}]; x += symbolW; }
  for (NSInteger k = intDigits - 1; k >= 0; --k) {
    if (k < intDigits - 1 && ((k + 1) % 3 == 0)) { [statics addObject:@{@"text": @",", @"x": @(x)}]; x += commaW; }
    [self addSlotX:x exp:(int)(k + dec)];
    x += cellW;
  }
  if (dec > 0) { [statics addObject:@{@"text": @".", @"x": @(x)}]; x += dotW; }
  for (int j = 1; j <= dec; ++j) { [self addSlotX:x exp:(int)(dec - j)]; x += cellW; }
  [self buildStaticImageWithFont:font attrs:attrs layout:statics width:W];
  _builtIntDigits = intDigits; _builtDec = dec;
  [self snapToCurrent];
}
- (void)tick:(NSTimer *)timer {
  (void)timer;
  if (!_caMode) return;
  unsigned long long S = [self currentS];
  unsigned long long intPart = S; const int dec = self.decimals < 0 ? 0 : self.decimals;
  for (int i = 0; i < dec; ++i) intPart /= 10ULL;
  NSInteger idig = NMOdoDigits(intPart); if (idig < 1) idig = 1;
  if (idig != _builtIntDigits || dec != _builtDec) { [self rebuild]; return; }
  const NSTimeInterval dur = 0.12;
  for (NSInteger i = 0; i < _slotLayers.count; ++i) {
    int exp = [_slotExp[i] intValue];
    int target = [self digitForExp:exp S:S];
    int cur = [_curDigit[i] intValue];
    int steps = (target - cur + 10) % 10;
    if (steps == 0) continue;
    _curDigit[i] = @(target);
    CALayer *strip = _stripLayers[i];
    CGFloat fromY = -(CGFloat)cur * _cellH;
    CGFloat toY = -(CGFloat)(cur + steps) * _cellH;
    CGFloat modelY = -(CGFloat)target * _cellH;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.y"];
    a.fromValue = @(fromY); a.toValue = @(toY); a.duration = dur;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    a.removedOnCompletion = YES;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    strip.position = CGPointMake(0, modelY);
    [CATransaction commit];
    [strip addAnimation:a forKey:@"roll"];
  }
}
- (void)clearDynamic {
  _caMode = NO;
  for (CALayer *l in _slotLayers) l.hidden = YES;
  if (_staticLayer) _staticLayer.hidden = YES;
  [self setNeedsDisplay];
}
- (void)configureActive:(BOOL)active wageTick:(double)wageTick startSecond:(int)startSecond
           totalSeconds:(int)totalSeconds symbol:(NSString *)symbol decimals:(int)decimals {
  BOOL same = _running && active && active == _cfgActive && wageTick == _cfgWageTick &&
      startSecond == _cfgStart && totalSeconds == _cfgTotal && decimals == _cfgDec &&
      [(symbol ?: @"") isEqualToString:(_cfgSymbol ?: @"")];
  if (same) return;
  self.active = active; self.wageTick = wageTick; self.startSecond = startSecond;
  self.totalSeconds = totalSeconds; self.symbol = symbol ?: @""; self.decimals = decimals;
  _cfgActive = active; _cfgWageTick = wageTick; _cfgStart = startSecond; _cfgTotal = totalSeconds;
  _cfgDec = decimals; _cfgSymbol = [symbol copy] ?: @"";
  [self stop];
  if (!active || [self reduceMotion] || self.hidden) { [self clearDynamic]; return; }
  _caMode = YES;
  _lineH = NSHeight(self.bounds); _pad = 1.0;
  CGFloat bs = NSScreen.mainScreen ? NSScreen.mainScreen.backingScaleFactor : 2.0; if (bs < 1.0) bs = 2.0;
  self.contentsScale = bs;
  [self buildStripImageIfNeeded];
  [self rebuild];
  if (_staticLayer) _staticLayer.hidden = NO;
  _running = YES;
  self.timer = [NSTimer timerWithTimeInterval:0.2 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
  self.timer.tolerance = 0.05;
  [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
  [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSModalPanelRunLoopMode];
  [self tick:nil];
}
- (void)drawInContext:(CGContextRef)ctx {
  if (_caMode) return;
  NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
  [NSGraphicsContext saveGraphicsState]; NSGraphicsContext.currentContext = gc;
  const double V = self.active ? [self currentTickValue] : 0.0;
  NSString *symbol = self.symbol ?: @"";
  const CGFloat W = NSWidth(self.bounds), H = NSHeight(self.bounds);
  const int dec = self.decimals < 0 ? 0 : self.decimals;
  double unitVal = (V < 0 ? 0 : V) / 100000.0;
  double p10 = 1.0; for (int i = 0; i < dec; ++i) p10 *= 10.0;
  unsigned long long S = (unsigned long long)llround(unitVal * p10);
  unsigned long long whole = dec > 0 ? (unsigned long long)(S / (unsigned long long)p10) : S;
  unsigned long long frac = dec > 0 ? (unsigned long long)(S % (unsigned long long)p10) : 0;
  NSString *ws = [NSString stringWithFormat:@"%llu", whole];
  NSMutableString *g = [NSMutableString string]; int c = 0;
  for (NSInteger i = (NSInteger)ws.length - 1; i >= 0; --i) {
    unichar ch = [ws characterAtIndex:(NSUInteger)i];
    [g insertString:[NSString stringWithCharacters:&ch length:1] atIndex:0];
    if (++c % 3 == 0 && i > 0) [g insertString:@"," atIndex:0];
  }
  NSString *text;
  if (dec > 0) {
    NSMutableString *fs = [NSMutableString stringWithFormat:@"%llu", frac];
    while ((NSInteger)fs.length < dec) [fs insertString:@"0" atIndex:0];
    text = [NSString stringWithFormat:@"%@%@.%@", symbol, g, fs];
  } else { text = [NSString stringWithFormat:@"%@%@", symbol, g]; }
  CGFloat use = self.fontSize; NSFont *font = nil; NSDictionary *attrs = nil; CGFloat tw = 0, th = 0;
  for (int it = 0; it < 5; ++it) {
    font = [NSFont monospacedDigitSystemFontOfSize:use weight:NSFontWeightRegular];
    attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : self.numberColor};
    tw = [text sizeWithAttributes:attrs].width; th = [text sizeWithAttributes:attrs].height;
    if (tw <= W - 12.0 || use <= 9.0) break;
    use *= (W - 12.0) / tw; if (use < 9.0) use = 9.0;
  }
  font = [NSFont monospacedDigitSystemFontOfSize:use weight:NSFontWeightRegular];
  attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : self.numberColor};
  tw = [text sizeWithAttributes:attrs].width; th = [text sizeWithAttributes:attrs].height;
  [text drawAtPoint:NSMakePoint((W - tw) / 2.0, (H - th) / 2.0) withAttributes:attrs];
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
@property(nonatomic) CGFloat artworkShiftX;  // 形象主体水平居中校正(A)
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
                             symbol:(NSString *)symbol decimals:(int)decimals;
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
  return layer;
}
static void NMSetSceneText(CATextLayer *layer, NSString *value, CGFloat size, NSColor *color) {
  layer.string = value.length ? [[NSAttributedString alloc] initWithString:value attributes:@{
    NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightRegular],
    NSForegroundColorAttributeName:color
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
    _offworkLabel = NMSceneText(CGRectMake(0,55,240,28),24,[NSColor colorWithCalibratedRed:.95 green:.72 blue:.33 alpha:1]);
    _offworkDuration = [NMNumberLayer layer];_offworkDuration.frame=CGRectMake(0,14,240,40);
    _encouragerLabel = NMSceneText(CGRectMake(0,0,240,28),20,[NSColor colorWithCalibratedRed:.95 green:.72 blue:.33 alpha:1]);
    _encouragerAmount = [NMNumberLayer layer];
    _encouragerAmount.frame = CGRectMake(0,0,240,30);
    _encouragerAmount.rollEnabled = YES;  // FB2 数字跳动动效（倒计时主信息用）
    _encouragerOdometer = [NMOdometerLayer layer];
    _encouragerOdometer.frame = CGRectMake(0,0,240,30);
    _encouragerOdometer.hidden = YES;
    _encouragerBarBack = [CALayer layer];
    _encouragerBarBack.backgroundColor = [NSColor colorWithCalibratedWhite:0 alpha:.35].CGColor;
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
  // A：按“面积最大的形象层”的水平中心作为主体锚点，校正整幅形象居中（适配任意形象）。
  { double bestArea=-1, anchorX=120.0;
    for (NSDictionary *d in layers){ NSArray *f=d[@"frame"]; double w=[f[2] doubleValue], h=[f[3] doubleValue];
      if (w*h>bestArea){ bestArea=w*h; anchorX=[f[0] doubleValue]+w/2.0; } }
    self.artworkShiftX = 120.0 - anchorX; }
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
  { CGRect af=self.artwork.frame; af.origin.x=self.artworkShiftX; self.artwork.frame=af; }
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
    self.artwork.frame=CGRectMake(self.artworkShiftX,bottom,240,170);
    self.counter.frame=CGRectMake(0,210+bottom,240,40);
    self.feedback.frame=CGRectMake(0,174+bottom,240,30);
    self.counter.hidden=preview; self.feedback.hidden=preview;
    // 下班倒计时区域：位于鼓励器区域之上（若两者同开）。
    self.offworkLabel.frame=CGRectMake(0,encouragerHeight+55,240,28);
    self.offworkDuration.frame=CGRectMake(0,encouragerHeight+14,240,40);
    self.offworkLabel.hidden=preview || offworkHeight==0;
    self.offworkDuration.hidden=preview || offworkHeight==0;
    // 鼓励器区域：最底部 84pt。FB13：顶部进度条 + 主信息 + 副信息。
    self.encouragerBarBack.frame=CGRectMake(20,encouragerHeight-12,200,8);
    self.encouragerAmount.frame=CGRectMake(0,encouragerHeight-46,240,30);
    self.encouragerOdometer.frame=CGRectMake(0,encouragerHeight-46,240,30);
    self.encouragerLabel.frame=CGRectMake(0,encouragerHeight-78,240,28);
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
  NSColor *color=[NSColor colorWithCalibratedRed:.95 green:.72 blue:.33 alpha:1];
  NMNoImplicit(^{
    if([self.counter updateText:counter size:counter.length>18?22:26 color:color]) self.textUpdates++;
    if([self.offworkDuration updateText:duration size:30 color:color]) self.textUpdates++;
    NSString *old=[self.offworkLabel.string isKindOfClass:NSAttributedString.class] ? [self.offworkLabel.string string] : self.offworkLabel.string;
    if(![old isEqual:label ?: @""]) { NMSetSceneText(self.offworkLabel,label,24,color);self.textUpdates++; }
  });
}
- (void)setEncouragerLabel:(NSString *)label amount:(NSString *)amount progress:(double)progress visible:(BOOL)visible {
  NSColor *color=[NSColor colorWithCalibratedRed:.95 green:.72 blue:.33 alpha:1];
  self.encouragerProgress = progress;
  self.encouragerVisible = visible;
  NMNoImplicit(^{
    NSString *oldLabel=[self.encouragerLabel.string isKindOfClass:NSAttributedString.class] ? [self.encouragerLabel.string string] : self.encouragerLabel.string;
    if(![oldLabel isEqual:label ?: @""]) { NMSetSceneText(self.encouragerLabel,label,20,color);self.textUpdates++; }
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
                             symbol:(NSString *)symbol decimals:(int)decimals {
  self.encouragerOdometerActive = active;
  [self.encouragerOdometer configureActive:active wageTick:wageTick startSecond:startSecond
                              totalSeconds:totalSeconds symbol:symbol decimals:decimals];
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
