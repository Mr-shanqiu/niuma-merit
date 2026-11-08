#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreServices/CoreServices.h>
#import <mach/mach_time.h>
#import "login_startup.h"
#include "fullscreen_detection.h"
#import "appearance_pack.mm"
#import "layer_scene.mm"
#import "thumbnail_grid.mm"
#import "share_card.mm"
#include "../offwork_clock.h"
#include "../calendar_month_range.h"
#include "../work_encourager.h"
#include "../merit_curve.h"
#include "../medals.h"
#include "../client/core/visibility_state.h"
#include "../reminder_activity.h"
#include "../reminder_geometry.h"
#include "../reminder_policy.h"
#include "../reminder_status.h"
#include "../reminder_store.h"
#include "../reminder_catalog_store.h"
#include "../reminder_catalog_trust.h"

#include <algorithm>
#include <cmath>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <string>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>
#import "input_runtime.mm"
#import "ui_theme.h"
#import "installation_paths.h"
#import "metrics_store.h"
#import "ui_text_table.h"

// Explicit acceptance launches never consult the user's product preferences.
// The pack root must be an empty, private directory supplied by the runner;
// invalid or incomplete isolation settings fail before NSApplication starts.
static BOOL gIsolatedAcceptance = NO;
static BOOL gAcceptancePhysicalInput = NO;
static NSArray<NSString *> *gAcceptancePackPaths;
static BOOL gReminderPreviewAcceptance = NO;
static NSString *gAcceptanceRootPath;
static int gSingleInstanceLockFd = -1;

static std::uint64_t ReminderContinuousTimeMs(void) {
  static const mach_timebase_info_data_t timebase = [] {
    mach_timebase_info_data_t value{};
    mach_timebase_info(&value);
    return value;
  }();
  if (timebase.denom == 0) return 0;
  const long double nanoseconds = static_cast<long double>(mach_continuous_time()) *
      timebase.numer / timebase.denom;
  return static_cast<std::uint64_t>(nanoseconds / 1'000'000.0L);
}

static BOOL AcquireSingleInstanceLock(void) {
  NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
  if (bundleIdentifier.length > 0 && !gIsolatedAcceptance) {
    for (NSRunningApplication *application in
         [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier]) {
      if (application.processIdentifier != getpid()) return NO;
    }
  }

  char path[PATH_MAX];
  const char *privateRoot=getenv("NIUMA_ACCEPTANCE_ROOT");
  const int length=gIsolatedAcceptance
      ? snprintf(path,sizeof(path),"%s/instance.lock",privateRoot)
      : snprintf(path,sizeof(path),"/tmp/niuma-merit-client-%u.lock",(unsigned)geteuid());
  if (length <= 0 || (size_t)length >= sizeof(path)) return NO;

  const int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return NO;
  struct stat attributes;
  if (fstat(fd, &attributes) != 0 || !S_ISREG(attributes.st_mode) ||
      attributes.st_uid != geteuid() || attributes.st_nlink != 1 ||
      (attributes.st_mode & 0777) != 0600 || flock(fd, LOCK_EX | LOCK_NB) != 0) {
    close(fd);
    return NO;
  }
  gSingleInstanceLockFd = fd;
  return YES;
}

@protocol NMMeritPreferences <NMLoginStartupPreferences>
- (id)objectForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (NSDictionary *)dictionaryForKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
@end

@interface NMEphemeralMeritPreferences : NSObject <NMMeritPreferences>
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *values;
@end

@implementation NMEphemeralMeritPreferences
- (instancetype)init {
  self = [super init];
  if (self) self.values = [NSMutableDictionary dictionary];
  return self;
}
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (NSInteger)integerForKey:(NSString *)key { return [self.values[key] integerValue]; }
- (BOOL)boolForKey:(NSString *)key { return [self.values[key] boolValue]; }
- (NSString *)stringForKey:(NSString *)key {
  id value = self.values[key];
  return [value isKindOfClass:NSString.class] ? value : nil;
}
- (NSDictionary *)dictionaryForKey:(NSString *)key {
  id value = self.values[key];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { self.values[key] = @(value); }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key] = @(value); }
- (void)setObject:(id)value forKey:(NSString *)key {
  if (value) self.values[key] = [value copy];
  else [self.values removeObjectForKey:key];
}
@end

static NMEphemeralMeritPreferences *gAcceptancePreferences;

static BOOL InitializeAcceptanceContext(int argc, const char *argv[]) {
  BOOL requested = NO;
  BOOL reminderPreview = NO;
  BOOL physicalInput=NO;
  NSMutableArray<NSString *> *packs=[NSMutableArray array];
  for (int index = 1; index < argc; ++index) {
    if (strcmp(argv[index], "--isolated-acceptance") == 0) requested = YES;
    if (strcmp(argv[index], "--reminder-ui-preview") == 0) reminderPreview = YES;
    if (strcmp(argv[index], "--physical-input-acceptance") == 0) physicalInput=YES;
    if (strcmp(argv[index], "--acceptance-pack") == 0) {
      if(index+1>=argc) return NO;
      NSString *path=[NSString stringWithUTF8String:argv[++index]];
      if(!path.isAbsolutePath || ![path.pathExtension.lowercaseString isEqual:@"nmgpack"]) return NO;
      [packs addObject:path];
    }
  }
  const char *rootValue = getenv("NIUMA_ACCEPTANCE_ROOT");
  if (!requested && !rootValue && !reminderPreview && !physicalInput && !packs.count) return YES;
  if (!requested || !rootValue || !rootValue[0]) return NO;
  NSString *root = [NSString stringWithUTF8String:rootValue];
  if (!root.isAbsolutePath ||
      ![root.stringByDeletingLastPathComponent isEqualToString:@"/private/tmp"] ||
      ![root.lastPathComponent hasPrefix:@"niuma-merit-acceptance-"]) return NO;
  char resolved[PATH_MAX];
  struct stat attributes;
  if (!realpath(rootValue, resolved) || strcmp(rootValue, resolved) != 0 ||
      lstat(rootValue, &attributes) != 0 || !S_ISDIR(attributes.st_mode) ||
      attributes.st_uid != geteuid() || (attributes.st_mode & 0777) != 0700) return NO;
  const char *packValue = getenv("NIUMA_PACK_ROOT");
  NSString *packRoot = packValue ? [NSString stringWithUTF8String:packValue] : nil;
  if (![packRoot isEqualToString:[root stringByAppendingPathComponent:@"AppearancePacks"]]) return NO;
  NSError *error = nil;
  NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:&error];
  if (!entries || error || entries.count != 0) return NO;
  gAcceptancePreferences = [[NMEphemeralMeritPreferences alloc] init];
  gIsolatedAcceptance = YES;
  gAcceptancePhysicalInput=physicalInput;gAcceptancePackPaths=[packs copy];
  gReminderPreviewAcceptance = reminderPreview;
  gAcceptanceRootPath = [root copy];
  return YES;
}

static id<NMMeritPreferences> MeritPreferences(void) {
  if (gIsolatedAcceptance) return gAcceptancePreferences;
  return (id<NMMeritPreferences>)NSUserDefaults.standardUserDefaults;
}

// Decode chroma-keyed artwork once, never during an animation frame.
static NSImage *LoadHamsterSprite(NSString *name) {
  static NSMutableDictionary<NSString *, NSImage *> *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
  if (cache[name]) return cache[name];
  NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"png"];
  NSBitmapImageRep *source = path ? [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:path]] : nil;
  if (!source) return nil;
  NSInteger width = source.pixelsWide, height = source.pixelsHigh;
  NSBitmapImageRep *rgba = [[NSBitmapImageRep alloc]
      initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
      bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
      colorSpaceName:NSDeviceRGBColorSpace
      bitmapFormat:0 bytesPerRow:width * 4 bitsPerPixel:32];
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CGContextRef context = CGBitmapContextCreate(rgba.bitmapData, width, height, 8,
      rgba.bytesPerRow, space, kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (!context) return nil;
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), source.CGImage);
  CGContextRelease(context);
  for (NSInteger y = 0; y < height; ++y) {
    for (NSInteger x = 0; x < width; ++x) {
      unsigned char *pixel = rgba.bitmapData + y * rgba.bytesPerRow + x * 4;
      CGFloat originalAlpha = pixel[3] / 255.0;
      if (originalAlpha == 0) continue;
      CGFloat r = pixel[0] / (255.0 * originalAlpha);
      CGFloat g = pixel[1] / (255.0 * originalAlpha);
      CGFloat b = pixel[2] / (255.0 * originalAlpha);
      CGFloat a = originalAlpha;
      CGFloat excess = g - std::max(r, b);
      if (excess > .08) {
        a *= 1.0 - std::clamp((excess - .08) / .22, 0.0, 1.0);
        g = std::min(g, std::max(r, b));
      }
      pixel[0] = (unsigned char)(r * a * 255); pixel[1] = (unsigned char)(g * a * 255);
      pixel[2] = (unsigned char)(b * a * 255); pixel[3] = (unsigned char)(a * 255);
    }
  }
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
  [image addRepresentation:rgba];
  cache[name] = image;
  return image;
}

static NSString *const kTotal = @"total";
static NSString *const kDailyTotals = @"dailyTotals";
static NSString *const kSelectedScene = @"selectedScene";
static NSString *const kSelectedAppearance = @"selectedAppearanceId";
// CONTRACT_096 §3/§4.2: appearance_scale defaults to 1.0 and clamps to
// 0.6..1.8. It is namespaced so the 0.9.5 keyspace stays untouched; when the
// metrics-096.json sidecar lands this value migrates into prefs.appearance_scale.
static NSString *const kAppearanceScale = @"niuma.gongde.v096.prefs.appearance_scale";
// Keep countdown preferences and snapshots independent of merit persistence.
static NSString *const kOffworkEnabled = @"offwork.enabled";
static NSString *const kOffworkHour = @"offwork.hour";
static NSString *const kOffworkMinute = @"offwork.minute";
static NSString *const kOffworkDailySnapshots = @"offwork.dailySnapshots";
static constexpr CGFloat kOffworkRegionHeight = 96.0;
// F2 上班鼓励器在桌面组件底部叠加一个独立区域（今日已赚 + 进度条）。
static constexpr CGFloat kEncouragerRegionHeight = 84.0;
static constexpr CGFloat kCalendarLeft = 24.0;
static constexpr CGFloat kCalendarTop = 218.0;
static constexpr CGFloat kCalendarCellWidth = 96.0;
static constexpr CGFloat kCalendarCellHeight = 64.0;
static constexpr CGFloat kArtworkTop = 170.0;
static constexpr CGFloat kFeedbackY = 174.0;
static constexpr CGFloat kCounterY = 210.0;
// CONTRACT_096 §10: 支持语言 zh-Hans / zh-Hant / ja / en，未知回落 zh-Hans。
typedef NS_ENUM(NSInteger, NMUiLanguage) {
  NMUiLanguageSimplifiedChinese = 0,
  NMUiLanguageTraditionalChinese = 1,
  NMUiLanguageJapanese = 2,
  NMUiLanguageEnglish = 3,
};

// 语言归一化统一走 S0 的 LocaleFromLanguageTag（reminder_policy.h）：
// ja* → 日语；en* → 英语；zh + Hant/-TW/-HK/-MO → 繁中；其余（含未知/空）→ 简中。
static NMUiLanguage NMLanguageFromTag(NSString *tag) {
  if (tag.length == 0) return NMUiLanguageSimplifiedChinese;
  switch (niuma::reminder::LocaleFromLanguageTag(tag.UTF8String)) {
    case niuma::reminder::Locale::ChineseTraditional: return NMUiLanguageTraditionalChinese;
    case niuma::reminder::Locale::Japanese: return NMUiLanguageJapanese;
    case niuma::reminder::Locale::English: return NMUiLanguageEnglish;
    case niuma::reminder::Locale::Chinese: break;
  }
  return NMUiLanguageSimplifiedChinese;
}

// UI 语言只解析一次：环境变量 NIUMA_UI_LANGUAGE（验收/测试用，接受同一套标签，
// 兼容旧值 zh/en）优先，否则取系统首选语言。
static NMUiLanguage NMCurrentUiLanguage(void) {
  static NMUiLanguage resolved = NMUiLanguageSimplifiedChinese;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *override = NSProcessInfo.processInfo.environment[@"NIUMA_UI_LANGUAGE"];
    resolved = NMLanguageFromTag(override.length > 0 ? override
                                                   : NSLocale.preferredLanguages.firstObject);
  });
  return resolved;
}

// L2 多语查表（ui_text_table.h）。键 = 简中原文；zh-Hant / ja 缺词条时回落简中。
// 词条覆盖率由 scripts/check-ui-strings.py 校验。
static NSDictionary<NSString *, NSString *> *NMUiTextTable(NMUiLanguage language) {
  static NSDictionary<NSString *, NSString *> *zhHant;
  static NSDictionary<NSString *, NSString *> *ja;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableDictionary *hant = [NSMutableDictionary dictionaryWithCapacity:kNMUiTextEntryCount];
    NSMutableDictionary *japanese = [NSMutableDictionary dictionaryWithCapacity:kNMUiTextEntryCount];
    for (std::size_t index = 0; index < kNMUiTextEntryCount; ++index) {
      const NMUiTextEntry &entry = kNMUiTextEntries[index];
      hant[@(entry.zhHans)] = @(entry.zhHant);
      japanese[@(entry.zhHans)] = @(entry.ja);
    }
    zhHant = hant;
    ja = japanese;
  });
  return language == NMUiLanguageTraditionalChinese ? zhHant : ja;
}

// UiText(简中, English)：zh-Hans 取第一参数；en 取第二参数；zh-Hant / ja 查表。
static NSString *UiText(NSString *chinese, NSString *english) {
  switch (NMCurrentUiLanguage()) {
    case NMUiLanguageEnglish: return english;
    case NMUiLanguageTraditionalChinese:
    case NMUiLanguageJapanese:
      return NMUiTextTable(NMCurrentUiLanguage())[chinese] ?: chinese;
    case NMUiLanguageSimplifiedChinese: return chinese;
  }
  return chinese;
}

// 周标签（x 轴，索引 0 = 周一）：zh-Hans/zh-Hant 一..日；ja 月..日；en MON..SUN。
static NSArray<NSString *> *NMWeekdayLabels(void) {
  switch (NMCurrentUiLanguage()) {
    case NMUiLanguageJapanese:
      return @[ @"月", @"火", @"水", @"木", @"金", @"土", @"日" ];
    case NMUiLanguageEnglish:
      return @[ @"MON", @"TUE", @"WED", @"THU", @"FRI", @"SAT", @"SUN" ];
    case NMUiLanguageSimplifiedChinese:
    case NMUiLanguageTraditionalChinese:
      break;
  }
  return @[ @"一", @"二", @"三", @"四", @"五", @"六", @"日" ];
}

// 内容语言（reminder catalog）与 UI 语言同一映射（CONTRACT_096 §10）：
// LocaleLanguage(NMReminderLocale()) 即规范内容语言标签；旧 zh-CN 包由
// CanonicalContentLanguage 在 EligibleItems 内与 zh-Hans 互认（S0 规则）。
static niuma::reminder::Locale NMReminderLocale(void) {
  switch (NMCurrentUiLanguage()) {
    case NMUiLanguageTraditionalChinese: return niuma::reminder::Locale::ChineseTraditional;
    case NMUiLanguageJapanese: return niuma::reminder::Locale::Japanese;
    case NMUiLanguageEnglish: return niuma::reminder::Locale::English;
    case NMUiLanguageSimplifiedChinese: break;
  }
  return niuma::reminder::Locale::Chinese;
}

// CONTRACT_096 §10: 规范语言标签（zh-Hans / zh-Hant / ja / en），无法识别回落 zh-Hans。
// 复用 NMCurrentUiLanguage 的归一化结果 + S0 的 LocaleLanguage 标签映射，保证
// UI 文案、内容语言（reminder catalog，NMReminderLocale）与货币默认三处同一规则。
static NSString *CurrentUiLanguageTag(void) {
  return [NSString stringWithUTF8String:niuma::reminder::LocaleLanguage(NMReminderLocale())];
}

static niuma::encourager::CurrencyInfo DefaultCurrencyForCurrentLanguage(void) {
  return niuma::encourager::CurrencyForLanguage(
      std::string(CurrentUiLanguageTag().UTF8String ?: "zh-Hans"));
}

static NMUiAlert *NMPermissionIntroAlert(NSString *applicationName) {
  NMUiAlert *alert = [[NMUiAlert alloc] init];
  alert.messageText = UiText(@"还差一步：开启输入监控", @"One more step: allow Input Monitoring");
  alert.informativeText = [NSString stringWithFormat:UiText(
      @"1. 点击下方按钮，打开系统的“输入监控”设置。\n\n2. 为“%@”打开开关。列表中没有时，点“＋”，从“应用程序”中选择它。\n\n3. 按系统提示退出，再重新打开牛马。\n\n只统计操作次数，不读取输入内容。",
      @"1. Click below to open Input Monitoring in System Settings.\n\n2. Enable “%@”. If it is missing, click + and select it in Applications.\n\n3. Quit when macOS asks, then reopen NiuMa.\n\nOnly operation counts are used; typed content is never read."), applicationName];
  [alert addButtonWithTitle:UiText(@"去开启输入监控", @"Open Input Monitoring")];
  [alert addButtonWithTitle:UiText(@"稍后", @"Later")];
  return alert;
}

static NSString *OffworkDurationText(long long seconds) {
  return [NSString stringWithUTF8String:niuma::OffworkDuration(seconds).c_str()];
}

// Persisted record keys and the calendar grid share the local Gregorian date
// axis, regardless of the user's preferred display calendar.
static NSCalendar *RecordCalendar() {
  NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
  calendar.timeZone = NSTimeZone.localTimeZone;
  return calendar;
}

static NSString *DateKeyForDate(NSDate *date) {
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = RecordCalendar();
    formatter.dateFormat = @"yyyy-MM-dd";
  });
  formatter.timeZone = NSTimeZone.localTimeZone;
  return [formatter stringFromDate:date];
}

// The desktop widget is laid out on a 240x250 design canvas. At 100% the
// canvas maps to points using kBaseUiScale; F1 lets the user scale that by
// 60%..180% (appearanceScale), so the effective point scale is the product.
static const CGFloat kBaseUiScale = 0.5;
static const CGFloat kWindowWidth = 240;
static const CGFloat kWindowHeight = 250;
static const CGFloat kMinAppearanceScale = 0.6;
static const CGFloat kMaxAppearanceScale = 1.8;
static const CGFloat kDefaultAppearanceScale = 1.0;

static const NSTimeInterval kDefaultStrikeDuration = 0.220;
static const NSTimeInterval kMinStrikeDuration = 0.120;
static const NSTimeInterval kMaxStrikeDuration = 0.240;
static const NSTimeInterval kPauseForResetGap = 0.600;
static const NSTimeInterval kPermissionPollInterval = 1.0;
static constexpr double kEmaWeight = 0.35;

static NSAffineTransform *LuckyCatPawTransform(NSRect actorRect, double amount) {
  // The sprite's attachment point is (362, 488) in its 600px top-down canvas.
  // Convert it to AppKit coordinates. Foreshorten vertically around the fixed
  // attachment to suggest a forward/downward beckon without a sideways swing.
  NSPoint shoulder = NSMakePoint(NSMinX(actorRect) + NSWidth(actorRect) * 362.0 / 600.0,
      NSMinY(actorRect) + NSHeight(actorRect) * (600.0 - 488.0) / 600.0);
  NSAffineTransform *transform = [NSAffineTransform transform];
  [transform translateXBy:shoulder.x yBy:shoulder.y];
  [transform scaleXBy:1.0 yBy:1.0 - .20 * amount];
  [transform translateXBy:-shoulder.x yBy:-shoulder.y];
  return transform;
}

typedef NS_ENUM(NSInteger, MeritScene) {
  MeritSceneWoodfish = 0,
  MeritSceneLuckyCat = 1,
  MeritSceneSeaLionBellyPat = 2,
  MeritSceneHamsterWheel = 3,
  MeritSceneEncourager = 4,  // F2: 上班鼓励器专属内置场景
};

static NSString *const kBuiltinWoodfishId = @"builtin.woodfish";
static NSString *const kBuiltinEncouragerId = @"builtin.encourager";

static BOOL NMIsKnownBuiltinId(NSString *identifier) {
  return [identifier isEqualToString:kBuiltinWoodfishId] ||
         [identifier isEqualToString:kBuiltinEncouragerId];
}
static MeritScene NMSceneForBuiltinId(NSString *identifier) {
  return [identifier isEqualToString:kBuiltinEncouragerId] ? MeritSceneEncourager
                                                            : MeritSceneWoodfish;
}

// F2: a small built-in "salary" illustration so the encourager is a real scene
// that can be selected alongside other appearances. Drawn once, never per frame.
static NSImage *NMEncouragerArtwork(void) {
  const CGFloat w = 240, h = 170;
  NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
  [image lockFocus];
  [NSGraphicsContext saveGraphicsState];
  NSRect card = NSMakeRect(30, 14, 180, 132);
  NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:card xRadius:18 yRadius:18];
  [[NSColor colorWithCalibratedRed:.99 green:.96 blue:.88 alpha:1] setFill];
  [cardPath fill];
  [[NSColor colorWithCalibratedRed:.78 green:.39 blue:.12 alpha:1] setStroke];
  cardPath.lineWidth = 3; [cardPath stroke];
  // 工牌夹
  NSRect ring = NSMakeRect(96, 132, 48, 14);
  [[NSColor colorWithCalibratedRed:.55 green:.55 blue:.58 alpha:1] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:ring xRadius:6 yRadius:6] fill];
  // 大号货币符号
  NSDictionary *symAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:64 weight:NSFontWeightBold],
    NSForegroundColorAttributeName : [NSColor colorWithCalibratedRed:.78 green:.39 blue:.12 alpha:1],
  };
  NSString *symbol = @"¥";
  NSSize symSize = [symbol sizeWithAttributes:symAttrs];
  [symbol drawAtPoint:NSMakePoint(NSMidX(card) - symSize.width / 2,
                                  36 - symSize.height / 2 + 54)
       withAttributes:symAttrs];
  // 两条“工资条”
  [[NSColor colorWithCalibratedRed:.78 green:.70 blue:.55 alpha:1] setFill];
  NSRectFill(NSMakeRect(52, 62, 136, 6));
  NSRectFill(NSMakeRect(52, 48, 96, 6));
  [NSGraphicsContext restoreGraphicsState];
  [image unlockFocus];
  return image;
}

@class MeritController;
@class MeritCalendarView;
@class NMCurveView;
static CGEventRef EventTapCallback(CGEventTapProxy, CGEventType, CGEventRef, void *);

@interface MeritView : NSView
@property(nonatomic, strong) NMLayerScene *renderer;
@property(nonatomic, copy) NSString *renderedIdentity;
@property(nonatomic) NSInteger renderedScene;
@property(nonatomic) BOOL presentationPending;
@property(nonatomic) NSTimeInterval pendingAnimationDuration;
@property(nonatomic) CFTimeInterval pendingAnimationStart;
- (void)requestAnimation:(NSTimeInterval)duration atTime:(CFTimeInterval)start;
- (void)syncPresentation;
- (NSArray<NSDictionary *> *)sceneDescriptors;
- (NSDictionary<NSString *, NSImage *> *)sceneImages;
@property(nonatomic, weak) MeritController *controller;
@property(nonatomic, strong) NSImage *woodfishImage;
@property(nonatomic, strong) NSImage *malletImage;
@property(nonatomic, strong) NSImage *luckyCatBaseImage;
@property(nonatomic, strong) NSImage *luckyCatActorImage;
@property(nonatomic, strong) NSImage *seaLionBodyImage;
@property(nonatomic, strong) NSImage *seaLionFlipperImage;
@property(nonatomic, strong) NSImage *hamsterBaseImage;
@property(nonatomic, strong) NSImage *hamsterWheelImage;
@property(nonatomic, strong) NSImage *hamsterActorImage;
@property(nonatomic, strong) NSImage *encouragerImage;  // F2 synthesized salary scene
@property(nonatomic, strong) NMAppearancePack *appearancePack;
@property(nonatomic) MeritScene scene;
@property(nonatomic) BOOL previewOnly;
@end

@interface MeritController : NSObject <NSApplicationDelegate, NSWindowDelegate> {
  niuma::OffworkSnapshot _offworkSnapshot;
  niuma::client::core::VisibilityState _visibility;
  NMSynchronizedActivity _reminderActivity;
  // F0 fallback path (CGEventTap -> receiveGlobalEvent) shares the mailbox's
  // distance/gesture rules via this counter.
  niuma::macos::ScrollTickCounter _scrollCounter;
  niuma::reminder::WallClockGuard _reminderClockGuard;
  bool _reminderStorageFault;
  std::unique_ptr<niuma::reminder::ReminderStore> _reminderStore;
  std::unique_ptr<niuma::reminder::CatalogUpdateStore> _catalogStore;
  std::shared_ptr<niuma::reminder::ValidatedCatalog> _reminderCatalog;
  bool _reminderCatalogCommitUncertain;
  // F4 曲线：本地日 → 96 桶 + 覆盖位图（内存态；定期批量落盘）。
  std::map<std::string, niuma::curve::CurveDay> _curveDays;
  bool _curveDirty;
  NSTimeInterval _curveLastFlushUptime;
  // F3 勋章：从每日累计派生的达成状态（内存态 + 侧车持久化）。
  niuma::medal::EarnedMap _medalEarned;
  bool _medalDirty;
}
@property(nonatomic) BOOL readyForOpenedFiles;
@property(nonatomic, strong) NSMutableArray<NSString *> *pendingOpenFiles;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSStatusItem *visibilityStatusItem;
@property(nonatomic) BOOL appearanceHidden;
@property(nonatomic) BOOL displaySuspended;
@property(nonatomic) BOOL screenLocked;
@property(nonatomic) BOOL systemSleeping;
@property(nonatomic, strong) MeritView *view;
@property(nonatomic, strong) NSTimer *animationTimer;
@property(nonatomic, strong) NSTimer *permissionPollTimer;
@property(nonatomic, strong) NSTimer *saveTimer;
@property(nonatomic, strong) NSTimer *dayTimer;
@property(nonatomic, strong) NSTimer *reminderTimer;
@property(nonatomic, strong) NSPanel *reminderPanel;
@property(nonatomic, strong) NSTimer *reminderDismissTimer;
@property(nonatomic, strong) NSWindow *calendarWindow;
@property(nonatomic, strong) MeritCalendarView *calendarView;
@property(nonatomic, strong) NSTimer *offworkTimer;
@property(nonatomic, strong) NSWindow *offworkSettingsWindow;
@property(nonatomic, strong) NSButton *offworkEnableControl;
@property(nonatomic, strong) NSPopUpButton *offworkHourControl;
@property(nonatomic, strong) NSPopUpButton *offworkMinuteControl;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *offworkDailySnapshots;
@property(nonatomic) BOOL offworkEnabled;
@property(nonatomic) NSInteger offworkHour;
@property(nonatomic) NSInteger offworkMinute;
@property(nonatomic) BOOL offworkDirty;
@property(nonatomic) BOOL offworkHasSnapshot;
@property(nonatomic) BOOL offworkSuspended;
@property(nonatomic) CGFloat regionLayoutHeight;  // 当前已应用的底部叠加区高度
// F2 上班鼓励器
@property(nonatomic, strong) NMMetricsStore *metrics;
@property(nonatomic, strong) NSTimer *encouragerTimer;
@property(nonatomic) BOOL encouragerEnabled;
@property(nonatomic) unsigned long long encouragerDailyWageMinor;
@property(nonatomic, copy) NSString *encouragerCurrency;
@property(nonatomic) BOOL encouragerCurrencyOverride;
@property(nonatomic) NSInteger encouragerStartMinute;
@property(nonatomic) NSInteger encouragerEndMinute;
@property(nonatomic) BOOL encouragerActive;  // enabled && wage>0 && 合法时段
@property(nonatomic, copy) NSString *encouragerDisplayLabel;
@property(nonatomic, copy) NSString *encouragerDisplayAmount;
@property(nonatomic) double encouragerProgress;
@property(nonatomic, strong) NSWindow *encouragerSettingsWindow;
@property(nonatomic, strong) NSButton *encouragerEnableControl;
@property(nonatomic, strong) NSTextField *encouragerWageField;
@property(nonatomic, strong) NSButton *encouragerCurrencyOverrideControl;
@property(nonatomic, strong) NSPopUpButton *encouragerCurrencyControl;
@property(nonatomic, strong) NSPopUpButton *encouragerStartHourControl;
@property(nonatomic, strong) NSPopUpButton *encouragerStartMinuteControl;
@property(nonatomic, strong) NSPopUpButton *encouragerEndHourControl;
@property(nonatomic, strong) NSPopUpButton *encouragerEndMinuteControl;
// F4 牛马曲线
@property(nonatomic, strong) NSWindow *curveWindow;
@property(nonatomic, strong) NMCurveView *curveView;
@property(nonatomic, strong) NSSegmentedControl *curveModeControl;
// F3 勋章墙
@property(nonatomic, strong) NSWindow *medalWindow;
@property(nonatomic, strong) NSTextField *medalSummaryLabel;
@property(nonatomic, strong) NSButton *medalWallToggle;
@property(nonatomic, strong) NSView *medalWallContainer;
@property(nonatomic, strong) NSPopUpButton *medalShareControl;
@property(nonatomic, strong) NSButton *medalShareButton;
// F1: user-selectable appearance multiplier (1.0 = 100%), applied to the whole
// desktop widget. uiScale is the effective design->point scale (base * factor,
// capped by the visible screen area).
@property(nonatomic) CGFloat appearanceScale;
@property(nonatomic, readonly) CGFloat uiScale;
@property(nonatomic, strong) NSWindow *appearanceScaleWindow;
@property(nonatomic, strong) NSSlider *appearanceScaleSlider;
@property(nonatomic, strong) NSTextField *appearanceScaleValueLabel;
@property(nonatomic) BOOL offworkIsOvertime;
@property(nonatomic, copy) NSString *offworkDayKey;
@property(nonatomic, copy) NSString *offworkDisplayLabel;
@property(nonatomic, copy) NSString *offworkDisplayDuration;
@property(nonatomic) NSTimeInterval offworkLastSampleUptime;
@property(nonatomic) NSTimeInterval offworkLastFlushUptime;
@property(nonatomic) CFMachPortRef eventTap;
@property(nonatomic, strong) NMEventTapThread *inputThread;
@property(nonatomic, strong) NMInputMailbox *inputMailbox;
@property(nonatomic, strong) dispatch_source_t inputNotification;
- (void)prepareInputDelivery;
- (void)captureInputType:(CGEventType)type event:(CGEventRef)event;
- (void)drainInput;

@property(nonatomic) CFRunLoopSourceRef eventSource;
@property(nonatomic) BOOL eventTapOperationInProgress;
@property(nonatomic) BOOL eventTapRecoveryStopped;
@property(nonatomic) BOOL eventTapDisabledPending;
@property(nonatomic) BOOL eventTapStopping;
@property(nonatomic) NSUInteger eventTapRecoveryAttempts;
@property(nonatomic) NSTimeInterval eventTapNextAttempt;
@property(nonatomic) long long total;
@property(nonatomic) long long todayTotal;
@property(nonatomic, copy) NSString *currentDayKey;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *dailyTotals;
@property(nonatomic) BOOL dirty;
@property(nonatomic) BOOL strikeActive;
@property(nonatomic) BOOL inputMonitoringAuthorized;
@property(nonatomic) BOOL launchedAutomatically;
@property(nonatomic) NSTimeInterval lastInputTime;
@property(nonatomic) NSTimeInterval lastScrollEventTime;
@property(nonatomic) double smoothedInputInterval;
@property(nonatomic) NSTimeInterval strikeStartTime;
@property(nonatomic) NSTimeInterval activeStrikeDuration;
@property(nonatomic) MeritScene selectedScene;
@property(nonatomic) NSInteger pendingScene;
@property(nonatomic, strong) NSArray<NSButton *> *appearanceButtons;
@property(nonatomic, copy) NSString *selectedAppearanceId;
@property(nonatomic, copy) NSString *pendingAppearanceId;
@property(nonatomic, copy) NSString *suggestedAppearanceId;
@property(nonatomic, strong) NSArray<NMAppearancePack *> *installedAppearancePacks;
@property(nonatomic, strong) NSArray<NSDictionary *> *appearanceItems;
@property(nonatomic) BOOL diagnostics;
@property(nonatomic) NSUInteger receivedEvents;
@property(nonatomic) NSUInteger receivedKeys;
@property(nonatomic) NSUInteger receivedClicks;
@property(nonatomic) NSUInteger receivedScrolls;
@property(nonatomic, strong) NSWindow *countStatusWindow;
@property(nonatomic, strong) NSTextView *countStatusText;
@property(nonatomic, strong) NSButton *selfCheckButton;
@property(nonatomic, strong) NSTimer *countStatusTimer;
@property(nonatomic) BOOL globalCountConfirmed;
@property(nonatomic) BOOL listenerNeedsCheck;
@property(nonatomic) BOOL selfCheckActive;
@property(nonatomic) BOOL selfCheckCountingEvent;
@property(nonatomic) BOOL selfCheckInterrupted;
@property(nonatomic) NSTimeInterval selfCheckStarts;
@property(nonatomic) NSTimeInterval selfCheckEnds;
@property(nonatomic) NSTimeInterval selfCheckLastEvent;
@property(nonatomic) NSUInteger selfCheckKeys;
@property(nonatomic) NSUInteger selfCheckClicks;
@property(nonatomic) NSUInteger selfCheckScrolls;
@property(nonatomic) NSUInteger selfCheckExpected;
@property(nonatomic) NSUInteger selfCheckCounted;
@property(nonatomic, copy) NSString *selfCheckResult;
@property(nonatomic, copy) NSSet<NSString *> *newlyImportedIds;
@property(nonatomic, copy) NSSet<NSString *> *lastImportedIds;
@property(nonatomic, strong) NSAlert *appearancePickerAlert;
@property(nonatomic, strong) NSError *appearanceLoadError;
@property(nonatomic) BOOL resourceLoadBusy;
@property(nonatomic) NSUInteger resourceGeneration;
@property(nonatomic, strong) NMAppearancePack *pendingScenePack;
@property(nonatomic, weak) NMThumbnailGrid *thumbnailGrid;
@property(nonatomic, strong) dispatch_source_t memoryPressure;
- (void)discardRebuildableResources;
- (void)pumpSceneLoad;

@property(nonatomic, strong) NMLoginStartupCoordinator *loginStartup;
@property(nonatomic, strong) NSError *loginStartupError;
- (BOOL)hasLiveEventTap;
- (NSString *)countStatusTitle;
- (void)receiveGlobalEvent:(CGEventType)type event:(CGEventRef)event;
- (void)receiveReminderKeyUp;
- (void)reminderWillPause:(NSNotification *)notification;
- (void)reminderDidResume:(NSNotification *)notification;
- (void)reminderObservationInterrupted:(NSNotification *)notification;
- (void)evaluateReminderActivity:(NSTimer *)timer;
- (void)presentReminderForTrigger:(niuma::reminder::ActivitySampler::Trigger)trigger;
- (void)positionReminderPanel:(NSPanel *)panel;
- (void)reminderScreensDidChange:(NSNotification *)notification;
- (void)dismissReminder:(id)sender;
- (void)countPetClickIfNeeded;
- (void)showCountStatus:(id)sender;
- (void)refreshCountStatus:(NSTimer *)timer;
- (void)startSelfCheck:(id)sender;
- (void)retryListener:(id)sender;
- (void)closeCountStatus:(id)sender;
- (void)showFirstUseGuide:(id)sender;
- (void)count;
- (void)countScrollGesture:(CGEventRef)event;
- (void)showContextMenu:(NSEvent *)event;
- (NSMenu *)contextMenu;
- (void)refreshAppearanceVisibility:(id)sender;
- (void)applyAppearanceVisibility;
- (void)toggleAppearanceVisibility:(id)sender;
- (void)toggleAutoHideFullscreen:(id)sender;
- (void)showStatusMenu:(id)sender;

- (void)startStrikeWithDuration:(NSTimeInterval)duration;
- (void)animate:(NSTimer *)timer;
- (void)showPermissionIntroIfNeeded;
- (void)requestListenPermission;
- (void)installEventTap;
- (void)createEventTapOnce;
- (void)removeEventTap;
- (void)handleEventTapDisabled:(CGEventType)type;
- (void)showAbout:(id)sender;
- (void)showAppearancePicker:(id)sender;
- (BOOL)importOfficialMessagesAtPath:(NSString *)filename;
- (void)showMeritCalendar:(id)sender;
- (void)shiftCalendarMonth:(NSButton *)sender;
- (void)ensureCurrentDay;
- (void)checkPermission:(NSTimer *)timer;
- (void)stopPermissionPoll;
- (void)configureLaunchAtLogin;
- (NMLoginStartupState)loginStartupState;
- (void)showLoginStartupApproval;
- (void)toggleLaunchAtLogin:(id)sender;
- (NSView *)appearanceGrid;
- (void)selectAppearance:(NSButton *)sender;
- (void)reloadAppearancePacks;
- (NMAppearancePack *)appearancePackWithId:(NSString *)identifier;
- (void)applyAppearanceId:(NSString *)identifier;
- (void)loadOffworkState;
- (void)startOffworkTimer;
- (void)refreshOffworkAllowRollover:(BOOL)allowRollover;
- (void)flushOffwork:(BOOL)durable;
- (void)showOffworkSettings:(id)sender;
- (void)offworkEnableChanged:(id)sender;
- (void)saveOffworkSettings:(id)sender;
- (void)cancelOffworkSettings:(id)sender;
- (NSDictionary *)offworkRecordForDay:(NSString *)key;
- (void)showCalendarDay:(NSString *)key;
- (CGFloat)maxUiScaleForScreen;
- (void)resizeAppearanceWindow;
- (void)applyAppearanceScale:(CGFloat)scale persist:(BOOL)persist;
- (void)updateAppearanceScaleLabels;
- (void)showAppearanceScaleSettings:(id)sender;
- (void)appearanceScaleSliderChanged:(id)sender;
- (void)resetAppearanceScale:(id)sender;
- (void)closeAppearanceScaleSettings:(id)sender;
// F2 上班鼓励器
- (void)loadEncouragerState;
- (void)startEncouragerTimer;
- (void)encouragerTick:(NSTimer *)timer;
- (void)refreshEncouragerDisplay;
- (void)showEncouragerSettings:(id)sender;
- (void)encouragerCurrencyOverrideChanged:(id)sender;
- (void)saveEncouragerSettings:(id)sender;
- (void)cancelEncouragerSettings:(id)sender;
- (CGFloat)desiredExtraRegionHeight;
- (void)updateRegionLayout;
- (void)saveMetrics;
// F4 牛马曲线
- (void)loadCurveState;
- (void)flushCurve;
- (void)markCurveHeartbeat;
- (void)mergeCurveDeltas:(NSDictionary *)deltas;
- (void)recordCurveIncrementAtWall:(std::time_t)wall;
- (void)pruneCurveDays;
- (NSDictionary *)curveDayForDisplay:(NSString *)key;
- (void)showMeritCurve:(id)sender;
- (void)exportCurveShareCard:(id)sender;
- (void)curveModeChanged:(id)sender;
// F3 勋章
- (void)loadMedalsState;
- (void)backfillMedalsFromHistory;
- (void)evaluateMedals;
- (void)saveMedals;
- (void)showMedals:(id)sender;
- (void)toggleMedalWall:(id)sender;
- (void)refreshMedalWall;
- (void)shareSelectedMedal:(id)sender;
- (unsigned long long)medalPeriodValue:(niuma::medal::Period)period;
@end

@implementation MeritView
@synthesize appearancePack=_appearancePack;
- (void)setAppearancePack:(NMAppearancePack *)pack {
  if(_appearancePack==pack) return;
  _appearancePack=pack;self.renderedIdentity=nil;
  // Even a switch while hidden releases the old scene's retained CGImages.
  [self.renderer installLayers:@[] images:@{}];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    self.renderer = [[NMLayerScene alloc] initWithRoot:self.layer];
    self.renderedScene = -1;
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *woodfishPath = [bundle pathForResource:@"woodfish" ofType:@"png"];
    NSString *malletPath = [bundle pathForResource:@"mallet" ofType:@"png"];
    if (woodfishPath) self.woodfishImage = [[NSImage alloc] initWithContentsOfFile:woodfishPath];
    if (malletPath) self.malletImage = [[NSImage alloc] initWithContentsOfFile:malletPath];
    NSArray<NSString *> *names = @[
      @"lucky-cat-base", @"lucky-cat-actor",
      @"sea-lion-body", @"sea-lion-flipper",
      @"hamster-wheel-base", @"hamster-wheel-wheel", @"hamster-wheel-actor"
    ];
    NSMutableArray<NSImage *> *images = [NSMutableArray arrayWithCapacity:names.count];
    for (NSString *name in names) {
      NSString *path = [bundle pathForResource:name ofType:@"png"];
      NSImage *image = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
      [images addObject:image ?: [[NSImage alloc] init]];
    }
    self.luckyCatBaseImage = images[0];
    self.luckyCatActorImage = images[1];
    self.seaLionBodyImage = images[2];
    self.seaLionFlipperImage = images[3];
    self.hamsterBaseImage = LoadHamsterSprite(@"hamster-habitat");
    self.hamsterActorImage = LoadHamsterSprite(@"hamster-pet");
    self.encouragerImage = NMEncouragerArtwork();
  }
  return self;
}

- (BOOL)isOpaque { return NO; }

- (BOOL)mouseDownCanMoveWindow { return YES; }

- (void)mouseDown:(NSEvent *)event {
  if (self.previewOnly) return;
  [self.controller countPetClickIfNeeded];
  [self.window performWindowDragWithEvent:event];
}

- (void)otherMouseDown:(NSEvent *)event {
  (void)event;
  if (!self.previewOnly) [self.controller countPetClickIfNeeded];
}

- (void)rightMouseDown:(NSEvent *)event {
  if (self.previewOnly) return;
  [self.controller countPetClickIfNeeded];
  [self.controller showContextMenu:event];
}

- (void)drawCenteredText:(NSString *)text
                    rect:(NSRect)rect
                    font:(NSFont *)font
                   color:(NSColor *)color {
  NSColor *glow = [NSColor colorWithCalibratedWhite:0 alpha:.8];
  NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
  center.alignment = NSTextAlignmentCenter;
  NSShadow *shadow = [[NSShadow alloc] init];
  shadow.shadowColor = glow;
  shadow.shadowOffset = NSMakeSize(0, -1);
  shadow.shadowBlurRadius = 2;
  NSDictionary *attributes = @{
    NSFontAttributeName: font,
    NSForegroundColorAttributeName: color,
    NSParagraphStyleAttributeName: center,
    NSStrokeColorAttributeName: [NSColor colorWithCalibratedWhite:0 alpha:.7],
    NSStrokeWidthAttributeName: @(-2.5),
    NSShadowAttributeName: shadow
  };
  [text drawInRect:rect withAttributes:attributes];
}

- (void)setNeedsDisplay:(BOOL)flag {
  if (!flag || self.presentationPending) return;
  self.presentationPending=YES;
  __weak MeritView *weakSelf=self;
  dispatch_async(dispatch_get_main_queue(), ^{ MeritView *view=weakSelf; view.presentationPending=NO; [view syncPresentation]; });
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self syncPresentation]; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self syncPresentation]; }
- (NSDictionary<NSString *,NSImage *> *)sceneImages {
  if (self.appearancePack) return self.appearancePack.images;
  if (self.scene==MeritSceneLuckyCat) return @{@"base":self.luckyCatBaseImage,@"actor":self.luckyCatActorImage};
  if (self.scene==MeritSceneSeaLionBellyPat) return @{@"base":self.seaLionBodyImage,@"actor":self.seaLionFlipperImage};
  if (self.scene==MeritSceneHamsterWheel) return @{@"base":self.hamsterBaseImage ?: [NSImage new],@"actor":self.hamsterActorImage ?: [NSImage new]};
  if (self.scene==MeritSceneEncourager) return @{@"base":self.encouragerImage ?: [NSImage new]};
  NSImage *shadow=[[NSImage alloc] initWithSize:NSMakeSize(160,16)];
  [shadow lockFocus]; [[NSColor colorWithWhite:0 alpha:.25] setFill];
  [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0,0,160,16)] fill]; [shadow unlockFocus];
  return @{@"woodfish":self.woodfishImage ?: [NSImage new],@"mallet":self.malletImage ?: [NSImage new],@"shadow":shadow};
}
- (NSArray<NSDictionary *> *)sceneDescriptors {
  if (self.appearancePack) return self.appearancePack.layers;
  NSDictionary *(^frame)(double,double,double,double,double)=^(double t,double x,double y,double r,double scale) {
    return @{@"t":@(t),@"x":@(x),@"y":@(y),@"rotation":@(r),@"scale":@(scale),@"scale_y":@1,@"alpha":@1};
  };
  NSDictionary *(^layer)(NSString *,NSArray *,NSArray *,NSArray *)=^(NSString *name,NSArray *rect,NSArray *anchor,NSArray *frames) {
    return @{@"image":name,@"frame":rect,@"anchor":anchor,@"keyframes":frames,@"interpolation":@"smoothstep"};
  };
  NSArray *still=@[frame(0,0,0,0,1)];
  if (self.scene==MeritSceneLuckyCat) {
    NSMutableDictionary *peak=[frame(.42,0,0,0,1) mutableCopy]; peak[@"scale_y"]=@.8;
    return @[layer(@"base",@[@5,@-35,@230,@230],@[@0,@0],still),
      layer(@"actor",@[@30,@-35,@230,@230],@[@(362.0/600),@(112.0/600)],
            @[frame(0,0,0,0,1),peak,frame(1,0,0,0,1)])];
  }
  if (self.scene==MeritSceneSeaLionBellyPat) return @[layer(@"base",@[@34,@0,@172,@168],@[@0,@0],still),
    layer(@"actor",@[@152,@44,@51,@66],@[@.15,@.9],@[frame(0,0,0,0,1),frame(.42,-3,-2,-48,1),frame(1,0,0,0,1)])];
  if (self.scene==MeritSceneHamsterWheel) {
    NSMutableDictionary *peak=[frame(.42,0,0,-2,1.012) mutableCopy]; peak[@"scale_y"]=@(.975/1.012);
    return @[layer(@"base",@[@35,@0,@170,@170],@[@0,@0],still),
      layer(@"actor",@[@41,@15,@154,@154],@[@(88.0/154),@(41.0/154)],@[frame(0,0,0,0,1),peak,frame(1,0,0,0,1)])];
  }
  if (self.scene==MeritSceneEncourager)
    return @[layer(@"base",@[@0,@0,@240,@170],@[@0,@0],still)];
  // The two mallet slices preserve the undistorted head and extended shaft.
  double sw=MAX(145,self.malletImage.size.width);
  NSMutableDictionary *shaft=[layer(@"mallet",@[@(120+.88*(417-260-120)),@(.88*(180-26)),@(.88*266),@(.88*54)],
      @[@(260.0/266),@(26.0/54)],@[frame(0,0,0,3,1),frame(.42,0,0,5.2,1),frame(1,0,0,3,1)]) mutableCopy];
  // Both slices rotate around the same off-screen pivot, expressed in each slice's coordinates.
  shaft[@"anchor"]=@[@(260.0/266),@(26.0/54)];
  shaft[@"contentsRect"]=@[@(108/sw),@0,@((sw-108)/sw),@1];
  NSMutableDictionary *head=[layer(@"mallet",@[@(120+.88*(417-309-120)),@(.88*(180-27)),@(.88*60),@(.88*54)],
      @[@(309.0/60),@.5],@[frame(0,0,0,3,1),frame(.42,0,0,5.2,1),frame(1,0,0,3,1)]) mutableCopy];
  head[@"contentsRect"]=@[@0,@0,@(145/sw),@1];
  return @[layer(@"shadow",@[@(120+.88*(40-120)),@(.88*3),@(.88*160),@(.88*16)],@[@0,@0],still),
    layer(@"woodfish",@[@(120+.88*(26-120)),@0,@(.88*214),@(.88*129)],@[@0,@0],still),shaft,head];
}
- (void)requestAnimation:(NSTimeInterval)duration atTime:(CFTimeInterval)start {
  self.pendingAnimationDuration=duration;self.pendingAnimationStart=start;[self setNeedsDisplay:YES];
}
- (void)syncPresentation {
  if (!self.renderer || (!self.previewOnly && self.controller.appearanceHidden)) return;
  [CATransaction begin];[CATransaction setDisableActions:YES];
  NSString *identity=self.appearancePack ? [NSString stringWithFormat:@"%@:%@",self.appearancePack.identifier,self.appearancePack.contentFingerprint]
                                       : [NSString stringWithFormat:@"builtin:%ld",(long)self.scene];
  if (![self.renderedIdentity isEqual:identity]) {
    [self.renderer installLayers:[self sceneDescriptors] images:[self sceneImages]];
    self.renderedIdentity=identity; self.renderedScene=self.scene;
  }
  CGFloat offworkHeight=(!self.previewOnly && self.controller.offworkEnabled) ? kOffworkRegionHeight : 0;
  CGFloat encouragerHeight=(!self.previewOnly && self.controller.encouragerActive) ? kEncouragerRegionHeight : 0;
  [self.renderer layoutWithScale:self.controller.uiScale backing:self.window.backingScaleFactor ?: 2
                   offworkHeight:offworkHeight encouragerHeight:encouragerHeight preview:self.previewOnly];
  [self.renderer setCounter:[NSString stringWithFormat:@"%lld",self.controller.todayTotal]
                      label:self.controller.offworkDisplayLabel duration:self.controller.offworkDisplayDuration];
  [self.renderer setEncouragerLabel:self.controller.encouragerDisplayLabel
                             amount:self.controller.encouragerDisplayAmount
                           progress:self.controller.encouragerProgress
                            visible:encouragerHeight>0];
  if(self.pendingAnimationDuration>0) {
    if(CACurrentMediaTime()-self.pendingAnimationStart<self.pendingAnimationDuration)
      [self.renderer play:self.pendingAnimationDuration atTime:self.pendingAnimationStart];
    self.pendingAnimationDuration=0;
  }
  [CATransaction commit];
}

#if defined(NIUMA_MAC_REFERENCE_RENDERER)
- (void)drawReferenceRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSGraphicsContext *ctx = NSGraphicsContext.currentContext;
  [ctx saveGraphicsState];
  ctx.imageInterpolation = NSImageInterpolationHigh;
  NSAffineTransform *canvas = [NSAffineTransform transform];
  [canvas scaleBy:self.controller.uiScale];
  [canvas concat];

  // Extend below the existing canvas, leaving every artwork/counter coordinate intact.
  [ctx saveGraphicsState];
  if (!self.previewOnly && self.controller.offworkEnabled) {
    NSAffineTransform *layout = [NSAffineTransform transform];
    [layout translateXBy:0 yBy:kOffworkRegionHeight];
    [layout concat];
  }

  MeritController *controller = self.controller;
  NSTimeInterval now = CACurrentMediaTime();
  NSTimeInterval age = now - controller.strikeStartTime;
  BOOL striking = controller.strikeActive && age >= 0 &&
                  age < controller.activeStrikeDuration;
  double phase = 0.0;
  if (striking && controller.activeStrikeDuration > 0) {
    phase = std::clamp(age / controller.activeStrikeDuration, 0.0, 1.0);
  }

  double strikeAmount = 0.0;
  if (striking && phase < 0.42) {
    double t = phase / 0.42;
    strikeAmount = t * t * (3.0 - 2.0 * t);
  } else if (striking) {
    double t = (phase - 0.42) / 0.58;
    double eased = t * t * (3.0 - 2.0 * t);
    strikeAmount = 1.0 - eased;
  }

  // Three non-overlapping layout regions: artwork 0...170, transient feedback
  // 174...204, and the daily counter 210...250. Artwork is clipped so a
  // malformed or oversized appearance can never cover either number.
  [ctx saveGraphicsState];
  [[NSBezierPath bezierPathWithRect:NSMakeRect(0, 0, kWindowWidth, kArtworkTop)] addClip];
  if (self.appearancePack) {
    [self.appearancePack drawAtPhase:striking ? phase : 0.0];
  } else if (self.scene == MeritSceneLuckyCat) {
    NSRect baseRect = NSMakeRect(5, -35, 230, 230);
    NSRect actorRect = NSMakeRect(30, -35, 230, 230);
    [self.luckyCatBaseImage drawInRect:baseRect
                              fromRect:NSZeroRect
                             operation:NSCompositingOperationSourceOver
                              fraction:1.0
                        respectFlipped:YES
                                 hints:nil];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *paw = LuckyCatPawTransform(actorRect, strikeAmount);
    [paw concat];
    [self.luckyCatActorImage drawInRect:actorRect
                                fromRect:NSZeroRect
                               operation:NSCompositingOperationSourceOver
                                fraction:1.0
                          respectFlipped:YES
                                   hints:nil];
    [NSGraphicsContext restoreGraphicsState];
  } else if (self.scene == MeritSceneSeaLionBellyPat) {
    [self.seaLionBodyImage drawInRect:NSMakeRect(34, 0, 172, 168)
                             fromRect:NSZeroRect
                            operation:NSCompositingOperationSourceOver
                             fraction:1.0
                       respectFlipped:NO
                                hints:nil];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *flipper = [NSAffineTransform transform];
    [flipper translateXBy:159.65 - 3.0 * strikeAmount
                      yBy:103.4 - 2.0 * strikeAmount];
    [flipper rotateByDegrees:-48.0 * strikeAmount];
    [flipper translateXBy:-159.65 yBy:-103.4];
    [flipper concat];
    [self.seaLionFlipperImage drawInRect:NSMakeRect(152, 44, 51, 66)
                                fromRect:NSZeroRect
                               operation:NSCompositingOperationSourceOver
                                fraction:1.0
                          respectFlipped:NO
                                   hints:nil];
    [NSGraphicsContext restoreGraphicsState];
  } else if (self.scene == MeritSceneHamsterWheel) {
    // Fit the complete perspective wheel inside the shared 0...170 artwork zone.
    NSRect hamsterRect = NSMakeRect(35, 0, 170, 170);
    [self.hamsterBaseImage drawInRect:hamsterRect
                             fromRect:NSZeroRect
                            operation:NSCompositingOperationSourceOver
                             fraction:1.0
                       respectFlipped:YES
                                hints:nil];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *hamster = [NSAffineTransform transform];
    // Keep the perspective wheel fixed. A small foot-anchored stride moves
    // the animal; rotating a projected ellipse would make the whole wheel wobble.
    [hamster translateXBy:129 yBy:56];
    [hamster rotateByDegrees:-2.0 * strikeAmount];
    [hamster scaleXBy:1.0 + .012 * strikeAmount yBy:1.0 - .025 * strikeAmount];
    [hamster translateXBy:-129 yBy:-56];
    [hamster concat];
    [self.hamsterActorImage drawInRect:NSMakeRect(41, 15, 154, 154)
                              fromRect:NSZeroRect
                             operation:NSCompositingOperationSourceOver
                              fraction:1.0
                        respectFlipped:YES
                                 hints:nil];
    [NSGraphicsContext restoreGraphicsState];
  } else {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *woodfishScale = [NSAffineTransform transform];
    [woodfishScale translateXBy:120 yBy:0];
    [woodfishScale scaleBy:0.88];
    [woodfishScale translateXBy:-120 yBy:0];
    [woodfishScale concat];
    NSRect shadowRect = NSMakeRect(40, 3, 160, 16);
    NSBezierPath *groundShadow = [NSBezierPath bezierPathWithOvalInRect:shadowRect];
    [[NSColor colorWithWhite:0 alpha:0.25] setFill];
    [groundShadow fill];

    [self.woodfishImage drawInRect:NSMakeRect(26, 0, 214, 129)
                          fromRect:NSZeroRect
                         operation:NSCompositingOperationSourceOver
                          fraction:1.0
                    respectFlipped:YES
                             hints:nil];

    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *malletTransform = [NSAffineTransform transform];
    // Keep the round head undistorted and extend only the wooden shaft by 30%.
    // The farther off-screen pivot uses a smaller arc to land on the same apex.
    [malletTransform translateXBy:417 yBy:180];
    [malletTransform rotateByDegrees:3.0 + 2.2 * strikeAmount];
    [malletTransform concat];
    NSSize malletSourceSize = self.malletImage.size;
    NSRect shaftSource = NSMakeRect(108, 0, MAX(1, malletSourceSize.width - 108),
                                    malletSourceSize.height);
    [self.malletImage drawInRect:NSMakeRect(-260, -26, 266, 54)
                        fromRect:shaftSource
                       operation:NSCompositingOperationSourceOver
                        fraction:1.0
                  respectFlipped:YES
                           hints:nil];
    NSRect headSource = NSMakeRect(0, 0, MIN(145, malletSourceSize.width),
                                   malletSourceSize.height);
    [self.malletImage drawInRect:NSMakeRect(-309, -27, 60, 54)
                        fromRect:headSource
                       operation:NSCompositingOperationSourceOver
                        fraction:1.0
                  respectFlipped:YES
                           hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext restoreGraphicsState];
  }
  [ctx restoreGraphicsState];

  if (!self.previewOnly && striking && phase >= .30 && phase <= .70) {
    [self drawCenteredText:@"+1"
                      rect:NSMakeRect(0, kFeedbackY, kWindowWidth, 30)
                      font:[NSFont monospacedDigitSystemFontOfSize:23
                                                           weight:NSFontWeightBold]
                     color:[NSColor colorWithCalibratedRed:.94 green:.50 blue:.16 alpha:1]];
  }

  // The counter is the product's source of truth and must never be hidden by
  // a scene or one of its moving layers, so it is deliberately drawn last.
  if (!self.previewOnly) {
  NSString *totalText = [NSString stringWithFormat:@"%lld", controller.todayTotal];
  CGFloat totalFont = totalText.length > 18 ? 22 : 26;
  if (totalText.length > 24) totalFont = 18;
  [self drawCenteredText:totalText
                    rect:NSMakeRect(0, kCounterY, kWindowWidth, 40)
                    font:[NSFont monospacedDigitSystemFontOfSize:totalFont
                                                         weight:NSFontWeightRegular]
                   color:NMUiMeritGold()];
  }

  [ctx restoreGraphicsState];
  if (!self.previewOnly && controller.offworkEnabled) {
    NSColor *color = NMUiMeritGold();
    [self drawCenteredText:controller.offworkDisplayLabel ?: UiText(@"距下班", @"Until off work")
                     rect:NSMakeRect(0, 55, kWindowWidth, 28)
                     font:[NSFont systemFontOfSize:24 weight:NSFontWeightMedium]
                    color:color];
    [self drawCenteredText:controller.offworkDisplayDuration ?: @"--:--:--"
                     rect:NSMakeRect(0, 14, kWindowWidth, 35)
                     font:[NSFont monospacedDigitSystemFontOfSize:24 weight:NSFontWeightRegular]
                    color:color];
  }
  [ctx restoreGraphicsState];
}

#endif

@end

@interface MeritCalendarView : NSView {
  niuma::CalendarMonthRange _monthRange;
}
@property(nonatomic, strong) NSButton *previousButton;
@property(nonatomic, strong) NSButton *nextButton;
@property(nonatomic, weak) MeritController *controller;
@property(nonatomic) NSInteger year;
@property(nonatomic) NSInteger month;
@property(nonatomic) NSInteger selectedDay;
@property(nonatomic, copy) NSArray<NSButton *> *dayButtons;
- (NSString *)selectedKey;
- (void)goToday:(id)sender;
- (void)showCurrentMonth;
- (void)shiftMonth:(NSInteger)delta;
- (void)reloadMonthRange;
- (void)refreshNavigation;
@end

#import "calendar_view.mm"

// F4 曲线视图：日（96 桶）/ 周（7 天日总）/ 月（当月日总）。
@interface NMCurveView : NSView
@property(nonatomic, weak) MeritController *controller;
@property(nonatomic) NSInteger mode;  // 0=日 1=周 2=月
- (void)refreshToToday;
@end

#import "curve_view.mm"

@implementation MeritController

- (void)loadOffworkState {
  id<NMMeritPreferences> defaults = MeritPreferences();
  self.offworkEnabled = [defaults boolForKey:kOffworkEnabled];
  NSInteger hour = [defaults objectForKey:kOffworkHour] ? [defaults integerForKey:kOffworkHour] : 18;
  NSInteger minute = [defaults objectForKey:kOffworkMinute] ? [defaults integerForKey:kOffworkMinute] : 0;
  self.offworkHour = hour >= 0 && hour <= 23 ? hour : 18;
  self.offworkMinute = minute >= 0 && minute <= 59 ? minute : 0;
  NSDictionary *stored = [defaults dictionaryForKey:kOffworkDailySnapshots];
  self.offworkDailySnapshots = stored ? [stored mutableCopy] : [NSMutableDictionary dictionary];
  self.offworkLastFlushUptime = NSProcessInfo.processInfo.systemUptime;
}

- (NSDictionary *)offworkRecordForDay:(NSString *)key {
  id record = self.offworkDailySnapshots[key];
  if (![record isKindOfClass:NSDictionary.class]) return nil;
  id seconds = record[@"seconds"], target = record[@"targetMinutes"], sampled = record[@"sampledAt"];
  if (![seconds isKindOfClass:NSNumber.class] || [seconds longLongValue] <= 0 ||
      ![target isKindOfClass:NSNumber.class] || [target integerValue] < 0 ||
      [target integerValue] >= 1440 || ![sampled isKindOfClass:NSNumber.class] ||
      !std::isfinite([sampled doubleValue])) return nil;
  return record;
}

- (void)flushOffwork:(BOOL)durable {
  if (self.offworkDirty) {
    [MeritPreferences() setObject:[self.offworkDailySnapshots copy] forKey:kOffworkDailySnapshots];
    self.offworkDirty = NO;
  }
  self.offworkLastFlushUptime = NSProcessInfo.processInfo.systemUptime;
  // Best effort at lifecycle boundaries only; normal per-second updates stay in memory.
  if (durable && !gIsolatedAcceptance) [NSUserDefaults.standardUserDefaults synchronize];
}

- (CGFloat)desiredExtraRegionHeight {
  CGFloat extra = 0;
  if (self.offworkEnabled) extra += kOffworkRegionHeight;
  if (self.encouragerActive) extra += kEncouragerRegionHeight;
  return extra;
}

// 统一处理底部叠加区（下班倒计时 + 上班鼓励器）导致的主窗口高度变化。
- (void)updateRegionLayout {
  if (!self.window) return;
  CGFloat desired = [self desiredExtraRegionHeight];
  if (self.regionLayoutHeight == desired) return;
  CGFloat delta = (desired - self.regionLayoutHeight) * self.uiScale;
  NSRect frame = self.window.frame;
  frame.origin.y -= delta;
  frame.size.height += delta;
  NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
  if (screen) {
    NSRect visible = screen.visibleFrame;
    frame.origin.x = MAX(NSMinX(visible), MIN(frame.origin.x, NSMaxX(visible) - NSWidth(frame)));
    frame.origin.y = MAX(NSMinY(visible), MIN(frame.origin.y, NSMaxY(visible) - NSHeight(frame)));
  }
  self.regionLayoutHeight = desired;
  [self.window setFrame:frame display:NO];
  [self.view setFrameSize:frame.size];
  [self.view setNeedsDisplay:YES];
}

- (void)refreshOffworkAllowRollover:(BOOL)allowRollover {
  if (!self.offworkEnabled || self.offworkSuspended) return;
  const time_t now = std::time(nullptr);
  const NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
  const auto next = niuma::EvaluateOffwork(now, (int)self.offworkHour, (int)self.offworkMinute);
  if (!next.valid) {
    self.offworkHasSnapshot = NO;
    self.offworkIsOvertime = NO;
    self.offworkDisplayLabel = UiText(@"时间不可用", @"Time unavailable");
    self.offworkDisplayDuration = @"--:--:--";
    [self.view setNeedsDisplay:YES];
    return;
  }
  NSString *key = DateKeyForDate([NSDate dateWithTimeIntervalSince1970:next.sampledAt]);
  BOOL changedDay = self.offworkHasSnapshot && ![key isEqualToString:self.offworkDayKey];
  if (changedDay) {
    double wallGap = std::difftime(next.sampledAt, _offworkSnapshot.sampledAt);
    double uptimeGap = uptime - self.offworkLastSampleUptime;
    // Only adjacent live samples may finalize yesterday. Sleep, unlock, clock changes,
    // long run-loop stalls and missed days must never fabricate a historical day.
    BOOL continuousMidnight = allowRollover && wallGap >= 0 && wallGap <= 5 &&
        uptimeGap >= 0 && uptimeGap <= 5 && std::abs(wallGap - uptimeGap) <= 2 &&
        next.sampledAt >= _offworkSnapshot.nextMidnightAt &&
        std::difftime(next.sampledAt, _offworkSnapshot.nextMidnightAt) <= 5 &&
        _offworkSnapshot.targetMinutes == self.offworkHour * 60 + self.offworkMinute;
    if (continuousMidnight) {
      long long seconds = niuma::OffworkFinalDaySeconds(_offworkSnapshot);
      if (seconds > 0) {
        self.offworkDailySnapshots[self.offworkDayKey] = @{
          @"seconds": @(seconds), @"targetMinutes": @(_offworkSnapshot.targetMinutes),
          @"sampledAt": @(_offworkSnapshot.nextMidnightAt - 1),
          @"targetAt": @(_offworkSnapshot.targetAt)
        };
        self.offworkDirty = YES;
      }
    }
  }
  _offworkSnapshot = next;
  self.offworkHasSnapshot = YES;
  self.offworkDayKey = key;
  self.offworkLastSampleUptime = uptime;
  self.offworkIsOvertime = next.overtime;
  self.offworkDisplayLabel = next.overtime ? UiText(@"已加班", @"Overtime")
                                          : UiText(@"距下班", @"Until off work");
  self.offworkDisplayDuration = OffworkDurationText(next.overtime ? next.overtimeSeconds : next.remainingSeconds);
  if (next.overtime && next.overtimeSeconds > 0) {
    self.offworkDailySnapshots[key] = @{
      @"seconds": @(next.overtimeSeconds), @"targetMinutes": @(next.targetMinutes),
      @"sampledAt": @(next.sampledAt), @"targetAt": @(next.targetAt)
    };
    self.offworkDirty = YES;
  } else if (self.offworkDailySnapshots[key]) {
    // Rewinding the clock or moving today's target forward removes only today's result.
    [self.offworkDailySnapshots removeObjectForKey:key];
    self.offworkDirty = YES;
  }
  self.view.accessibilityLabel = [NSString stringWithFormat:@"%@ %lld, %@ %@",
      UiText(@"今日功德", @"Today's merit"), self.todayTotal,
      self.offworkDisplayLabel, self.offworkDisplayDuration];
  if (!self.appearanceHidden) [self.view setNeedsDisplay:YES];
  if (self.calendarWindow.isVisible) [self.calendarView setNeedsDisplay:YES];
  if (changedDay) [self flushOffwork:YES];
  else if (uptime - self.offworkLastFlushUptime >= 60) [self flushOffwork:NO];
}

- (void)offworkTick:(NSTimer *)timer {
  (void)timer;
  [self refreshOffworkAllowRollover:YES];
}

- (void)startOffworkTimer {
  [self.offworkTimer invalidate];
  self.offworkTimer = nil;
  [self updateRegionLayout];
  if (!self.offworkEnabled) {
    self.offworkHasSnapshot = NO;
    self.view.accessibilityLabel = nil;
    return;
  }
  [self refreshOffworkAllowRollover:NO];
  NSDate *firstTick = [NSDate dateWithTimeIntervalSince1970:std::floor(NSDate.date.timeIntervalSince1970) + 1];
  self.offworkTimer = [[NSTimer alloc] initWithFireDate:firstTick interval:1
      target:self selector:@selector(offworkTick:) userInfo:nil repeats:YES];
  self.offworkTimer.tolerance = .05;
  [NSRunLoop.mainRunLoop addTimer:self.offworkTimer forMode:NSRunLoopCommonModes];
  [NSRunLoop.mainRunLoop addTimer:self.offworkTimer forMode:NSModalPanelRunLoopMode];
}

- (void)offworkWillSleep:(NSNotification *)notification {
  (void)notification;
  _reminderActivity.BeginSuspend(ReminderContinuousTimeMs());
  [self refreshOffworkAllowRollover:YES];
  [self flushOffwork:YES];
  self.offworkSuspended = YES;
  self.systemSleeping=YES; self.displaySuspended=YES; [self applyAppearanceVisibility];
}

- (void)offworkClockChanged:(NSNotification *)notification {
  (void)notification;
  [NSTimeZone resetSystemTimeZone];
  tzset();
  [self.inputMailbox invalidateDate];
  self.offworkSuspended = NO;
  if([notification.name isEqual:NSWorkspaceDidWakeNotification]) self.systemSleeping=NO;
  if([notification.name isEqual:@"com.apple.screenIsUnlocked"] || [notification.name isEqual:NSWorkspaceSessionDidBecomeActiveNotification]) self.screenLocked=NO;
  self.displaySuspended=self.screenLocked || self.systemSleeping; [self refreshAppearanceVisibility:nil];
  [self ensureCurrentDay];
  [self refreshOffworkAllowRollover:NO];
  [self flushOffwork:YES];
}

- (void)reminderWillPause:(NSNotification *)notification {
  (void)notification;
  self.screenLocked=YES; self.displaySuspended=YES; [self applyAppearanceVisibility];
  _reminderActivity.BeginSuspend(ReminderContinuousTimeMs());
}

- (void)reminderDidResume:(NSNotification *)notification {
  (void)notification;
  self.displaySuspended=self.screenLocked || self.systemSleeping; [self refreshAppearanceVisibility:nil];
  const std::uint64_t nowMs = ReminderContinuousTimeMs();
  const bool paired = _reminderActivity.suspended();
  const std::uint64_t startMs = _reminderActivity.suspend_started_ms();
  const bool trusted = paired && nowMs >= startMs;
  const std::uint64_t duration = trusted ? nowMs - startMs : 0;
  const bool wasConsumed = _reminderActivity.segment_consumed();
  _reminderActivity.ResumeFromSuspend(nowMs, paired, trusted, duration);
  if (wasConsumed && !_reminderActivity.segment_consumed()) {
    const auto result = _reminderStore
        ? _reminderStore->SetSegmentConsumed(false,
            static_cast<std::int64_t>(NSDate.date.timeIntervalSince1970))
        : niuma::reminder::StoreResult::IoError;
    if (result != niuma::reminder::StoreResult::Success) {
      _reminderStorageFault = true;
      _reminderActivity.RestoreSegmentConsumed(true);
    } else {
      _reminderStorageFault = false;
    }
  }
}

- (void)reminderObservationInterrupted:(NSNotification *)notification {
  if ([notification.name isEqualToString:NSSystemClockDidChangeNotification]) {
    const auto nowUtc = static_cast<std::int64_t>(NSDate.date.timeIntervalSince1970);
    const auto nowMs = ReminderContinuousTimeMs();
    const auto transition = _reminderClockGuard.NotifyClockChange(nowUtc, nowMs);
    if (transition == niuma::reminder::WallClockGuard::Transition::Guarded && _reminderStore) {
      NSString *dateText = DateKeyForDate(NSDate.date);
      if (_reminderStore->SetClockGuard(true, nowUtc, dateText.UTF8String) !=
          niuma::reminder::StoreResult::Success) _reminderStorageFault = true;
    }
  }
  if (_reminderActivity.suspended()) return;
  const bool wasConsumed = _reminderActivity.segment_consumed();
  _reminderActivity.ResumeFromSuspend(ReminderContinuousTimeMs(), false, false, 0);
  if (wasConsumed) _reminderActivity.RestoreSegmentConsumed(true);
}

- (void)offworkWillPowerOff:(NSNotification *)notification {
  (void)notification;
  [self refreshOffworkAllowRollover:YES];
  [self flushOffwork:YES];
}

- (void)showOffworkSettings:(id)sender {
  (void)sender;
  if (!self.offworkSettingsWindow) {
    self.offworkSettingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 290)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self.offworkSettingsWindow.title = UiText(@"下班倒计时", @"Off-work Countdown");
    self.offworkSettingsWindow.releasedWhenClosed = NO;
    self.offworkSettingsWindow.delegate = self;
    if (gIsolatedAcceptance) self.offworkSettingsWindow.restorable = NO;
    NSView *content = self.offworkSettingsWindow.contentView;
    self.offworkEnableControl = [NSButton checkboxWithTitle:UiText(@"启用下班倒计时", @"Enable off-work countdown")
        target:self action:@selector(offworkEnableChanged:)];
    self.offworkEnableControl.frame = NSMakeRect(24, 240, 392, 26);
    [content addSubview:self.offworkEnableControl];
    NSTextField *label = [NSTextField labelWithString:UiText(@"下班时间（24小时制）", @"Off-work time (24-hour)")];
    label.frame = NSMakeRect(24, 196, 214, 24);
    [content addSubview:label];
    self.offworkHourControl = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(244, 192, 70, 28) pullsDown:NO];
    self.offworkMinuteControl = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(336, 192, 70, 28) pullsDown:NO];
    for (NSInteger hour = 0; hour < 24; ++hour)
      [self.offworkHourControl addItemWithTitle:[NSString stringWithFormat:@"%02ld", (long)hour]];
    for (NSInteger minute = 0; minute < 60; ++minute)
      [self.offworkMinuteControl addItemWithTitle:[NSString stringWithFormat:@"%02ld", (long)minute]];
    self.offworkHourControl.accessibilityLabel = UiText(@"下班小时", @"Off-work hour");
    self.offworkMinuteControl.accessibilityLabel = UiText(@"下班分钟", @"Off-work minute");
    [content addSubview:self.offworkHourControl];
    [content addSubview:self.offworkMinuteControl];
    NSTextField *colon = [NSTextField labelWithString:@":"];
    colon.frame = NSMakeRect(319, 197, 12, 22);
    [content addSubview:colon];
    NSTextField *explanation = [NSTextField wrappingLabelWithString:UiText(
        @"每天按本地下班时间重新计算，超过即为加班。开启时自动保存当天加班快照，关闭保留历史。仅本地运行，不需要输入监控权限，不判断实际劳动或离岗时间。",
        @"Recalculates daily using local time. Time past your target is overtime. While enabled, daily snapshots are saved; disabling keeps history. Local only, no Input Monitoring needed. This is not work or attendance detection.")];
    explanation.frame = NSMakeRect(24, 66, 392, 108);
    explanation.font = [NSFont systemFontOfSize:13];
    [content addSubview:explanation];
    NSButton *cancel = [NSButton buttonWithTitle:UiText(@"取消", @"Cancel")
        target:self action:@selector(cancelOffworkSettings:)];
    cancel.frame = NSMakeRect(232, 20, 88, 30);
    cancel.keyEquivalent = @"\033";
    [content addSubview:cancel];
    NSButton *save = [NSButton buttonWithTitle:UiText(@"保存", @"Save")
        target:self action:@selector(saveOffworkSettings:)];
    save.frame = NSMakeRect(328, 20, 88, 30);
    save.keyEquivalent = @"\r";
    [content addSubview:save];
    NMUiWindow(self.offworkSettingsWindow);
    [self.offworkSettingsWindow center];
  }
  if (!self.offworkSettingsWindow.isVisible) {
    self.offworkEnableControl.state = self.offworkEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self.offworkHourControl selectItemAtIndex:self.offworkHour];
    [self.offworkMinuteControl selectItemAtIndex:self.offworkMinute];
    [self offworkEnableChanged:nil];
  }
  [NSApp activateIgnoringOtherApps:YES];
  [self.offworkSettingsWindow makeKeyAndOrderFront:nil];
}

- (void)offworkEnableChanged:(id)sender {
  (void)sender;
  BOOL enabled = self.offworkEnableControl.state == NSControlStateValueOn;
  self.offworkHourControl.enabled = enabled;
  self.offworkMinuteControl.enabled = enabled;
}

- (void)cancelOffworkSettings:(id)sender {
  (void)sender;
  [self.offworkSettingsWindow close];
}

- (void)saveOffworkSettings:(id)sender {
  (void)sender;
  [self refreshOffworkAllowRollover:YES];
  [self flushOffwork:YES];
  self.offworkEnabled = self.offworkEnableControl.state == NSControlStateValueOn;
  self.offworkHour = self.offworkHourControl.indexOfSelectedItem;
  self.offworkMinute = self.offworkMinuteControl.indexOfSelectedItem;
  id<NMMeritPreferences> defaults = MeritPreferences();
  [defaults setBool:self.offworkEnabled forKey:kOffworkEnabled];
  [defaults setInteger:self.offworkHour forKey:kOffworkHour];
  [defaults setInteger:self.offworkMinute forKey:kOffworkMinute];
  [self startOffworkTimer];
  [self flushOffwork:YES];
  if (self.calendarWindow.isVisible) [self.calendarView setNeedsDisplay:YES];
  [self.offworkSettingsWindow close];
}

- (void)showCalendarDay:(NSString *)key {
  [self refreshOffworkAllowRollover:YES];
  NSAlert *alert = [[NMUiAlert alloc] init];
  alert.messageText = key;
  NSString *merit = [NSString stringWithFormat:@"%@ %llu", UiText(@"功德", @"Merit"),
      self.dailyTotals[key].unsignedLongLongValue];
  NSDictionary *record = [self offworkRecordForDay:key];
  if (record) {
    NSInteger minutes = [record[@"targetMinutes"] integerValue];
    NSString *updated = [NSDateFormatter localizedStringFromDate:
        [NSDate dateWithTimeIntervalSince1970:[record[@"sampledAt"] doubleValue]]
        dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterMediumStyle];
    alert.informativeText = [NSString stringWithFormat:UiText(
        @"%@\n加班快照：%@\n当日预定下班：%02ld:%02ld\n最后更新：%@\n\n本地时间快照，不代表实际劳动或离岗时刻。历史日期不随当前设置回算。",
        @"%@\nOvertime snapshot: %@\nOff-work target: %02ld:%02ld\nLast updated: %@\n\nA local time snapshot, not actual work or departure time. Historical dates are not recalculated with current settings."),
        merit, OffworkDurationText([record[@"seconds"] longLongValue]),
        (long)(minutes / 60), (long)(minutes % 60), updated];
  } else {
    alert.informativeText = [NSString stringWithFormat:@"%@\n\n%@", merit,
        UiText(@"没有加班快照，不代表当天准时下班。", @"No overtime snapshot. This does not mean an on-time departure.")];
  }
  [alert addButtonWithTitle:UiText(@"关闭", @"Close")];
  [alert runModal];
}

// ---- F2 上班鼓励器 ----

// 解析用户输入的“主单位”金额（如 200.50）为最小货币单位整数，全程整数、不用浮点。
static BOOL NMParseAmountToMinor(NSString *text, int exponent, unsigned long long *out) {
  if (!out) return NO;
  if (exponent < 0) exponent = 0;
  if (exponent > 6) exponent = 6;
  NSString *trimmed = [text stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (trimmed.length == 0) return NO;
  NSMutableString *digits = [NSMutableString string];
  NSInteger dotCount = 0;
  for (NSUInteger i = 0; i < trimmed.length; ++i) {
    unichar c = [trimmed characterAtIndex:i];
    if (c >= '0' && c <= '9') {
      [digits appendFormat:@"%C", c];
    } else if (c == '.' || c == ',') {
      // 允许千分位逗号与一个小数点；逗号忽略。
      if (c == '.') {
        if (++dotCount > 1) return NO;
        [digits appendString:@"."];
      }
    } else {
      return NO;
    }
  }
  if (digits.length == 0) return NO;
  NSArray<NSString *> *parts = [digits componentsSeparatedByString:@"."];
  NSString *whole = parts.firstObject ?: @"0";
  NSString *frac = parts.count > 1 ? parts[1] : @"";
  if (whole.length > 15) return NO;  // 防止溢出
  unsigned long long wholeValue = 0;
  for (NSUInteger i = 0; i < whole.length; ++i) {
    unichar c = [whole characterAtIndex:i];
    if (c < '0' || c > '9') return NO;
    wholeValue = wholeValue * 10 + (unsigned long long)(c - '0');
  }
  // 取 exponent 位小数，多余位四舍五入（half-up）。
  unsigned long long fracValue = 0;
  BOOL roundUp = NO;
  for (int i = 0; i < exponent; ++i) {
    unsigned long long d = 0;
    if (i < (int)frac.length) {
      unichar c = [frac characterAtIndex:(NSUInteger)i];
      if (c < '0' || c > '9') return NO;
      d = (unsigned long long)(c - '0');
    }
    fracValue = fracValue * 10 + d;
  }
  if ((int)frac.length > exponent) {
    unichar next = [frac characterAtIndex:(NSUInteger)exponent];
    if (next >= '5' && next <= '9') roundUp = YES;
  }
  unsigned long long unit = 1;
  for (int i = 0; i < exponent; ++i) unit *= 10;
  unsigned long long result = wholeValue * unit + fracValue;
  if (roundUp) result += 1;
  *out = result;
  return YES;
}

- (void)loadEncouragerState {
  if (!self.metrics) return;
  NSDictionary *block = [self.metrics encourager];
  self.encouragerEnabled = [block[@"enabled"] boolValue];
  self.encouragerDailyWageMinor = [block[@"daily_wage_minor"] unsignedLongLongValue];
  self.encouragerCurrency = block[@"currency"] ?: @"CNY";
  self.encouragerCurrencyOverride = [block[@"currency_override"] boolValue];
  self.encouragerStartMinute = [block[@"start_minute"] integerValue];
  self.encouragerEndMinute = [block[@"end_minute"] integerValue];
  if (!self.encouragerCurrencyOverride) {
    niuma::encourager::CurrencyInfo info = DefaultCurrencyForCurrentLanguage();
    self.encouragerCurrency = [NSString stringWithUTF8String:info.code];
  }
  niuma::encourager::Window window{(int)self.encouragerStartMinute,
                                   (int)self.encouragerEndMinute};
  self.encouragerActive = self.encouragerEnabled && self.encouragerDailyWageMinor > 0 &&
                          window.Valid();
  [self refreshEncouragerDisplay];
}

- (void)refreshEncouragerDisplay {
  niuma::encourager::Window window{(int)self.encouragerStartMinute,
                                   (int)self.encouragerEndMinute};
  std::time_t now = std::time(nullptr);
  std::tm local = {};
  int secondOfDay = 0;
  if (niuma::OffworkLocalTime(now, &local)) secondOfDay = local.tm_hour * 3600 +
      local.tm_min * 60 + local.tm_sec;
  niuma::encourager::Status status = niuma::encourager::Evaluate(
      self.encouragerDailyWageMinor, self.encouragerEnabled, window, secondOfDay);
  self.encouragerActive = status.valid;
  NSString *code = self.encouragerCurrency.length ? self.encouragerCurrency : @"CNY";
  int exponent = niuma::encourager::ExponentForCode(std::string(code.UTF8String ?: "CNY"));
  std::string symbol = niuma::encourager::SymbolForCode(std::string(code.UTF8String ?: "CNY"));
  self.encouragerDisplayAmount = [NSString stringWithUTF8String:
      niuma::encourager::FormatAmountMinor(status.earned_minor, exponent, symbol).c_str()];
  self.encouragerDisplayLabel = UiText(@"今日已赚", @"Earned today");
  self.encouragerProgress = status.progress;
  if (!self.appearanceHidden) [self.view setNeedsDisplay:YES];
}

- (void)encouragerTick:(NSTimer *)timer {
  (void)timer;
  [self refreshEncouragerDisplay];
}

- (void)startEncouragerTimer {
  [self.encouragerTimer invalidate];
  self.encouragerTimer = nil;
  [self updateRegionLayout];
  if (!self.encouragerActive) {
    [self refreshEncouragerDisplay];
    return;
  }
  [self refreshEncouragerDisplay];
  NSDate *firstTick = [NSDate dateWithTimeIntervalSince1970:
      std::floor(NSDate.date.timeIntervalSince1970) + 1];
  self.encouragerTimer = [[NSTimer alloc] initWithFireDate:firstTick interval:1
      target:self selector:@selector(encouragerTick:) userInfo:nil repeats:YES];
  self.encouragerTimer.tolerance = .05;
  [NSRunLoop.mainRunLoop addTimer:self.encouragerTimer forMode:NSRunLoopCommonModes];
  [NSRunLoop.mainRunLoop addTimer:self.encouragerTimer forMode:NSModalPanelRunLoopMode];
}

- (void)showEncouragerSettings:(id)sender {
  (void)sender;
  if (!self.encouragerSettingsWindow) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 470, 400)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = UiText(@"上班鼓励器", @"Work Encourager");
    window.releasedWhenClosed = NO;
    window.delegate = self;
    if (gIsolatedAcceptance) window.restorable = NO;
    NSView *content = window.contentView;
    self.encouragerEnableControl =
        [NSButton checkboxWithTitle:UiText(@"启用上班鼓励器", @"Enable work encourager")
            target:self action:@selector(encouragerCurrencyOverrideChanged:)];
    self.encouragerEnableControl.frame = NSMakeRect(24, 352, 380, 26);
    [content addSubview:self.encouragerEnableControl];

    NSTextField *wageLabel = [NSTextField labelWithString:UiText(@"日薪", @"Daily wage")];
    wageLabel.frame = NSMakeRect(24, 312, 120, 22);
    [content addSubview:wageLabel];
    self.encouragerWageField = [[NSTextField alloc] initWithFrame:NSMakeRect(150, 308, 160, 26)];
    self.encouragerWageField.placeholderString = UiText(@"如 200.00", @"e.g. 200.00");
    [content addSubview:self.encouragerWageField];
    NSTextField *wageHint = [NSTextField labelWithString:UiText(
        @"按上班时段平均累计；为 0 时关闭", @"Spread across the work window; 0 disables")];
    wageHint.frame = NSMakeRect(320, 312, 128, 22);
    wageHint.font = [NSFont systemFontOfSize:10];
    wageHint.textColor = NMUiMuted();
    [content addSubview:wageHint];

    self.encouragerCurrencyOverrideControl =
        [NSButton checkboxWithTitle:UiText(@"手动指定货币", @"Override currency")
            target:self action:@selector(encouragerCurrencyOverrideChanged:)];
    self.encouragerCurrencyOverrideControl.frame = NSMakeRect(24, 272, 180, 24);
    [content addSubview:self.encouragerCurrencyOverrideControl];
    self.encouragerCurrencyControl = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(210, 268, 150, 28) pullsDown:NO];
    NSArray<NSString *> *codes = @[ @"CNY", @"TWD", @"JPY", @"USD", @"EUR", @"GBP" ];
    NSArray<NSString *> *titles = @[ @"CN¥ CNY", @"NT$ TWD", @"JP¥ JPY", @"US$ USD",
                                     @"€ EUR", @"£ GBP" ];
    for (NSUInteger i = 0; i < codes.count; ++i) {
      [self.encouragerCurrencyControl addItemWithTitle:titles[i]];
      self.encouragerCurrencyControl.lastItem.representedObject = codes[i];
    }
    [content addSubview:self.encouragerCurrencyControl];

    NSTextField *windowLabel = [NSTextField labelWithString:UiText(
        @"上班时段（起 < 止，24 小时制）", @"Work window (start < end, 24-hour)")];
    windowLabel.frame = NSMakeRect(24, 232, 300, 22);
    [content addSubview:windowLabel];
    self.encouragerStartHourControl = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(24, 198, 66, 28) pullsDown:NO];
    self.encouragerStartMinuteControl = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(96, 198, 66, 28) pullsDown:NO];
    for (NSInteger h = 0; h < 24; ++h)
      [self.encouragerStartHourControl addItemWithTitle:[NSString stringWithFormat:@"%02ld", (long)h]];
    for (NSInteger m = 0; m < 60; ++m)
      [self.encouragerStartMinuteControl addItemWithTitle:[NSString stringWithFormat:@"%02ld", (long)m]];
    NSTextField *dash = [NSTextField labelWithString:@"→"];
    dash.frame = NSMakeRect(170, 203, 20, 20);
    [content addSubview:dash];
    self.encouragerEndHourControl = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(196, 198, 66, 28) pullsDown:NO];
    self.encouragerEndMinuteControl = [[NSPopUpButton alloc] initWithFrame:
        NSMakeRect(268, 198, 66, 28) pullsDown:NO];
    for (NSInteger h = 0; h <= 24; ++h)
      [self.encouragerEndHourControl addItemWithTitle:[NSString stringWithFormat:@"%02ld", (long)h]];
    for (NSInteger m = 0; m < 60; ++m)
      [self.encouragerEndMinuteControl addItemWithTitle:[NSString stringWithFormat:@"%02ld", (long)m]];
    [content addSubview:self.encouragerStartHourControl];
    [content addSubview:self.encouragerStartMinuteControl];
    [content addSubview:self.encouragerEndHourControl];
    [content addSubview:self.encouragerEndMinuteControl];

    NSTextField *explanation = [NSTextField wrappingLabelWithString:UiText(
        @"显示「今日已赚」与今日上班进度条：时段内按墙钟每秒累计，到止点等于日薪；时段外暂停，每日零点归零，周末同样生效。跨午夜时段本期不支持。金额仅本地保存与展示，不写入日志、分享卡或网络。",
        @"Shows “Earned today” and a work-progress bar: accrues by the wall clock within the window, reaching the daily wage at the end; pauses outside it, resets at midnight, and applies on weekends too. Overnight windows are not supported yet. Amounts stay local and are never logged, shared, or sent.")];
    explanation.frame = NSMakeRect(24, 92, 422, 92);
    explanation.font = [NSFont systemFontOfSize:12];
    explanation.textColor = NMUiMuted();
    [content addSubview:explanation];

    NSButton *cancel = [NSButton buttonWithTitle:UiText(@"取消", @"Cancel")
        target:self action:@selector(cancelEncouragerSettings:)];
    cancel.frame = NSMakeRect(262, 20, 88, 30);
    cancel.keyEquivalent = @"\033";
    [content addSubview:cancel];
    NSButton *save = [NSButton buttonWithTitle:UiText(@"保存", @"Save")
        target:self action:@selector(saveEncouragerSettings:)];
    save.frame = NSMakeRect(358, 20, 88, 30);
    save.keyEquivalent = @"\r";
    [content addSubview:save];
    self.encouragerSettingsWindow = window;
    NMUiWindow(window);
    [window center];
  }
  // 打开时用当前值填充，不提交。
  self.encouragerEnableControl.state = self.encouragerEnabled ? NSControlStateValueOn : NSControlStateValueOff;
  int exponent = niuma::encourager::ExponentForCode(
      std::string(self.encouragerCurrency.UTF8String ?: "CNY"));
  self.encouragerWageField.stringValue = [NSString stringWithUTF8String:
      niuma::encourager::FormatAmountMinor(self.encouragerDailyWageMinor, exponent, "").c_str()];
  self.encouragerCurrencyOverrideControl.state =
      self.encouragerCurrencyOverride ? NSControlStateValueOn : NSControlStateValueOff;
  NSString *code = self.encouragerCurrencyOverride ? self.encouragerCurrency
      : [NSString stringWithUTF8String:DefaultCurrencyForCurrentLanguage().code];
  for (NSMenuItem *item in self.encouragerCurrencyControl.itemArray) {
    if ([item.representedObject isEqualToString:code]) {
      [self.encouragerCurrencyControl selectItem:item];
      break;
    }
  }
  [self.encouragerStartHourControl selectItemAtIndex:self.encouragerStartMinute / 60];
  [self.encouragerStartMinuteControl selectItemAtIndex:self.encouragerStartMinute % 60];
  [self.encouragerEndHourControl selectItemAtIndex:self.encouragerEndMinute / 60];
  [self.encouragerEndMinuteControl selectItemAtIndex:self.encouragerEndMinute % 60];
  [self encouragerCurrencyOverrideChanged:nil];
  [NSApp activateIgnoringOtherApps:YES];
  [self.encouragerSettingsWindow makeKeyAndOrderFront:nil];
}

- (void)encouragerCurrencyOverrideChanged:(id)sender {
  (void)sender;
  BOOL overrideOn = self.encouragerCurrencyOverrideControl.state == NSControlStateValueOn;
  self.encouragerCurrencyControl.enabled = overrideOn;
}

- (void)cancelEncouragerSettings:(id)sender {
  (void)sender;
  [self.encouragerSettingsWindow close];
}

- (void)saveEncouragerSettings:(id)sender {
  (void)sender;
  BOOL enabled = self.encouragerEnableControl.state == NSControlStateValueOn;
  BOOL overrideOn = self.encouragerCurrencyOverrideControl.state == NSControlStateValueOn;
  NSString *code = overrideOn
      ? (self.encouragerCurrencyControl.selectedItem.representedObject ?: @"CNY")
      : [NSString stringWithUTF8String:DefaultCurrencyForCurrentLanguage().code];
  int exponent = niuma::encourager::ExponentForCode(std::string(code.UTF8String ?: "CNY"));
  unsigned long long wageMinor = 0;
  if (!NMParseAmountToMinor(self.encouragerWageField.stringValue, exponent, &wageMinor)) {
    NSAlert *alert = [[NMUiAlert alloc] init];
    alert.messageText = UiText(@"日薪格式无效", @"Invalid Daily Wage");
    alert.informativeText = UiText(@"请填写非负金额，例如 200 或 200.50。",
        @"Enter a non-negative amount such as 200 or 200.50.");
    [alert addButtonWithTitle:UiText(@"好", @"OK")];
    [alert runModal];
    return;
  }
  NSInteger startMinute = self.encouragerStartHourControl.indexOfSelectedItem * 60 +
      self.encouragerStartMinuteControl.indexOfSelectedItem;
  NSInteger endHour = self.encouragerEndHourControl.indexOfSelectedItem;
  NSInteger endMinute = endHour * 60 + self.encouragerEndMinuteControl.indexOfSelectedItem;
  if (endHour == 24 && self.encouragerEndMinuteControl.indexOfSelectedItem != 0) endMinute = -1;
  if (startMinute < 0 || endMinute <= startMinute || endMinute > 1440) {
    NSAlert *alert = [[NMUiAlert alloc] init];
    alert.messageText = UiText(@"上班时段无效", @"Invalid Work Window");
    alert.informativeText = UiText(@"开始时间必须早于结束时间（24:00 仅可作结束且分钟为 0）。跨午夜暂不支持。",
        @"Start must be earlier than end (24:00 allowed only as end with 0 minutes). Overnight windows are not supported yet.");
    [alert addButtonWithTitle:UiText(@"好", @"OK")];
    [alert runModal];
    return;
  }

  self.encouragerEnabled = enabled;
  self.encouragerDailyWageMinor = wageMinor;
  self.encouragerCurrency = code;
  self.encouragerCurrencyOverride = overrideOn;
  self.encouragerStartMinute = startMinute;
  self.encouragerEndMinute = endMinute;

  if (self.metrics) {
    NSMutableDictionary *block = [self.metrics encourager];
    block[@"enabled"] = @(enabled);
    block[@"daily_wage_minor"] = @(wageMinor);
    block[@"currency"] = code;
    block[@"currency_override"] = @(overrideOn);
    block[@"start_minute"] = @(startMinute);
    block[@"end_minute"] = @(endMinute);
  }
  niuma::encourager::Window window{(int)startMinute, (int)endMinute};
  self.encouragerActive = enabled && wageMinor > 0 && window.Valid();
  [self refreshEncouragerDisplay];
  [self startEncouragerTimer];
  [self saveMetrics];
  [self.encouragerSettingsWindow close];
}

- (void)saveMetrics {
  if (!self.metrics) return;
  NSMutableDictionary *prefs = [self.metrics prefs];
  prefs[@"ui_language"] = CurrentUiLanguageTag();
  prefs[@"appearance_scale"] = @(self.appearanceScale);
  [self.metrics save];
}

// ---- F4 牛马曲线 ----

static BOOL NMParseU64(const char *text, std::uint64_t *out) {
  if (!text || !*text || !out) return NO;
  char *end = nullptr;
  errno = 0;
  unsigned long long v = std::strtoull(text, &end, 10);
  if (end == text || (end && *end) || errno == ERANGE) return NO;
  *out = (std::uint64_t)v;
  return YES;
}

- (void)loadCurveState {
  _curveDays.clear();
  _curveDirty = NO;
  _curveLastFlushUptime = NSProcessInfo.processInfo.systemUptime;
  if (!self.metrics) return;
  NSDictionary *curveBlock = [self.metrics curve];
  NSDictionary *days = curveBlock[@"days"];
  if (![days isKindOfClass:NSDictionary.class]) return;
  for (NSString *key in days) {
    NSString *keyString = [key isKindOfClass:NSString.class] ? key : nil;
    if (!keyString) continue;
    NSDictionary *record = days[key];
    if (![record isKindOfClass:NSDictionary.class]) continue;
    NSArray *buckets = record[@"buckets"];
    NSString *coverageHex = record[@"coverage"];
    if (![buckets isKindOfClass:NSArray.class] || buckets.count != 96) continue;
    if (![coverageHex isKindOfClass:NSString.class]) continue;
    niuma::curve::Coverage coverage;
    if (!niuma::curve::Coverage::FromHex(std::string(coverageHex.UTF8String ?: ""), &coverage))
      continue;
    niuma::curve::CurveDay day;
    day.coverage = coverage;
    BOOL ok = YES;
    for (int i = 0; i < 96; ++i) {
      id value = buckets[(NSUInteger)i];
      std::uint64_t parsed = 0;
      if ([value isKindOfClass:NSNumber.class]) {
        parsed = [value unsignedLongLongValue];
      } else if ([value isKindOfClass:NSString.class]) {
        if (!NMParseU64([value UTF8String], &parsed)) { ok = NO; break; }
      } else {
        ok = NO;
        break;
      }
      day.buckets[(std::size_t)i] = parsed;
    }
    if (!ok) continue;
    _curveDays[std::string(keyString.UTF8String)] = day;
  }
  [self pruneCurveDays];
}

- (void)pruneCurveDays {
  if (_curveDays.empty()) return;
  std::vector<std::string> keys;
  keys.reserve(_curveDays.size());
  for (const auto &entry : _curveDays) keys.push_back(entry.first);
  NSString *today = DateKeyForDate(NSDate.date);
  std::vector<std::string> remove = niuma::curve::KeysToPrune(
      keys, std::string(today.UTF8String ?: ""), niuma::curve::kRetentionDays);
  for (const std::string &key : remove) _curveDays.erase(key);
}

// 合并来自输入邮箱的按日桶增量（NSData：96×uint64 + 12 字节覆盖位图）。
- (void)mergeCurveDeltas:(NSDictionary *)deltas {
  if (![deltas isKindOfClass:NSDictionary.class] || deltas.count == 0) return;
  for (NSString *key in deltas) {
    NSDictionary *record = deltas[key];
    if (![record isKindOfClass:NSDictionary.class]) continue;
    NSData *bucketData = record[@"buckets"];
    NSData *coverageData = record[@"coverage"];
    if (bucketData.length != 96 * sizeof(std::uint64_t) || coverageData.length != 12) continue;
    std::uint64_t values[96];
    std::memcpy(values, bucketData.bytes, sizeof(values));
    niuma::curve::CurveDay &day = _curveDays[std::string(key.UTF8String)];
    for (int i = 0; i < 96; ++i) {
      if (values[i] == 0) continue;
      std::uint64_t &cell = day.buckets[(std::size_t)i];
      cell = (values[i] > UINT64_MAX - cell) ? UINT64_MAX : cell + values[i];
    }
    const unsigned char *coverage = static_cast<const unsigned char *>(coverageData.bytes);
    for (int i = 0; i < 12; ++i) day.coverage.bytes[(std::size_t)i] |= coverage[i];
    _curveDirty = YES;
  }
}

- (void)recordCurveIncrementAtWall:(std::time_t)wall {
  struct tm local = {};
  if (!niuma::OffworkLocalTime(wall, &local)) return;
  char key[32] = {};
  if (!std::strftime(key, sizeof(key), "%Y-%m-%d", &local)) return;
  const int bucket = niuma::curve::BucketForMinute(local.tm_hour * 60 + local.tm_min);
  _curveDays[std::string(key)].AddCount(bucket, 1);
  _curveDirty = YES;
}

// 心跳：应用运行期间把当前桶标记为「已观测」（coverage=1），用于区分真零与未采集。
- (void)markCurveHeartbeat {
  const std::time_t now = std::time(nullptr);
  struct tm local = {};
  if (!niuma::OffworkLocalTime(now, &local)) return;
  char key[32] = {};
  if (!std::strftime(key, sizeof(key), "%Y-%m-%d", &local)) return;
  const int bucket = niuma::curve::BucketForMinute(local.tm_hour * 60 + local.tm_min);
  niuma::curve::CurveDay &day = _curveDays[std::string(key)];
  if (!day.coverage.Get(bucket)) {
    day.MarkObserved(bucket);
    _curveDirty = YES;
  }
}

- (void)flushCurve {
  _curveLastFlushUptime = NSProcessInfo.processInfo.systemUptime;
  if (!self.metrics || !_curveDirty) return;
  [self pruneCurveDays];
  NSMutableDictionary *curveBlock = [self.metrics curve];
  NSMutableDictionary *days = [NSMutableDictionary dictionaryWithCapacity:_curveDays.size()];
  for (const auto &entry : _curveDays) {
    NSMutableArray *buckets = [NSMutableArray arrayWithCapacity:96];
    for (int i = 0; i < 96; ++i) {
      std::uint64_t value = entry.second.buckets[(std::size_t)i];
      // 契约允许十进制字符串以无损表示 >2^53 的 64 位值；小值写 JSON 数字。
      if (value <= 9007199254740992ULL)
        [buckets addObject:@(value)];
      else
        [buckets addObject:[NSString stringWithFormat:@"%llu", (unsigned long long)value]];
    }
    days[[NSString stringWithUTF8String:entry.first.c_str()]] = @{
      @"coverage" : [NSString stringWithUTF8String:entry.second.coverage.ToHex().c_str()],
      @"buckets" : buckets,
    };
  }
  curveBlock[@"bucket_minutes"] = @15;
  curveBlock[@"buckets_per_day"] = @96;
  curveBlock[@"retention_days"] = @60;
  curveBlock[@"days"] = days;
  [self.metrics save];
  _curveDirty = NO;
}

- (NSDictionary *)curveDayForDisplay:(NSString *)key {
  if (![key isKindOfClass:NSString.class]) return nil;
  auto it = _curveDays.find(std::string(key.UTF8String ?: ""));
  if (it == _curveDays.end()) return nil;
  NSMutableArray *buckets = [NSMutableArray arrayWithCapacity:96];
  for (int i = 0; i < 96; ++i) [buckets addObject:@(it->second.buckets[(std::size_t)i])];
  return @{
    @"buckets" : buckets,
    @"coverage" : [NSString stringWithUTF8String:it->second.coverage.ToHex().c_str()],
  };
}

// ---- F3 勋章 ----
static NSString *NMMedalPeriodLabel(niuma::medal::Period period) {
  switch (period) {
    case niuma::medal::Period::Day: return UiText(@"日", @"Day");
    case niuma::medal::Period::Week: return UiText(@"周", @"Week");
    case niuma::medal::Period::Month: return UiText(@"月", @"Month");
  }
  return UiText(@"日", @"Day");
}
static NSString *NMMedalTierLabel(int tier) {
  if (tier == 0) return UiText(@"铜", @"Bronze");
  if (tier == 1) return UiText(@"银", @"Silver");
  return UiText(@"金", @"Gold");
}
static NSString *NMMedalTierEnglish(int tier) {
  if (tier == 0) return @"Bronze";
  if (tier == 1) return @"Silver";
  return @"Gold";
}
static NSString *NMMedalPeriodEnglish(niuma::medal::Period period) {
  switch (period) {
    case niuma::medal::Period::Day: return @"Daily";
    case niuma::medal::Period::Week: return @"Weekly";
    case niuma::medal::Period::Month: return @"Monthly";
  }
  return @"Daily";
}
static NSString *NMMedalIcon(int tier) {
  if (tier == 0) return @"🥉";
  if (tier == 1) return @"🥈";
  return @"🥇";
}

- (void)loadMedalsState {
  _medalEarned.clear();
  _medalDirty = false;
  if (!self.metrics) return;
  NSDictionary *medals = [self.metrics medals];
  NSDictionary *earned = medals[@"earned"];
  if (![earned isKindOfClass:NSDictionary.class]) return;
  for (NSString *key in earned) {
    if (![key isKindOfClass:NSString.class]) continue;
    NSDictionary *record = earned[key];
    if (![record isKindOfClass:NSDictionary.class]) continue;
    niuma::medal::Earned value;
    id first = record[@"first_earned_day"];
    id count = record[@"count"];
    id last = record[@"last_period"];
    if ([first isKindOfClass:NSString.class]) value.first_earned_day = [first UTF8String] ?: "";
    if ([count isKindOfClass:NSNumber.class]) value.count = [count unsignedIntValue];
    if ([last isKindOfClass:NSString.class]) value.last_period = [last UTF8String] ?: "";
    value.lit = value.count > 0 || value.first_earned_day.size() > 0;
    _medalEarned[std::string(key.UTF8String)] = value;
  }
}

// CONTRACT_096 §12.1（选择「基于旧日总数静默补授」）：升级后按旧存储
// dailyTotals 的历史一次性补授勋章，不弹窗、不伪造曲线数据。
// 幂等守门：migration.medals_backfilled 置位后不再执行（重放会对跨多个周期
// 获得的勋章重复计次，见 medals.h BackfillHistory 注释）。
- (void)backfillMedalsFromHistory {
  if (!self.metrics) return;
  NSMutableDictionary *migration = [self.metrics migration];
  if ([migration[@"medals_backfilled"] boolValue]) return;
  // 先置位再补授：即使中途失败也不在下次启动重复计次。
  migration[@"medals_backfilled"] = @YES;

  std::vector<std::string> dayKeys;
  for (NSString *key in self.dailyTotals) {
    if (![key isKindOfClass:NSString.class]) continue;
    const char *utf8 = key.UTF8String;
    int year = 0, month = 0, day = 0;
    if (!utf8 || !niuma::curve::ParseDateKey(std::string(utf8), &year, &month, &day)) continue;
    dayKeys.push_back(std::string(utf8));
  }
  std::sort(dayKeys.begin(), dayKeys.end());
  NSDictionary<NSString *, NSNumber *> *totals = self.dailyTotals;
  const bool changed = niuma::medal::BackfillHistory(&_medalEarned,
      niuma::medal::BuiltinThresholds(), dayKeys,
      [&totals](const std::string &day) -> std::uint64_t {
        NSString *key = [NSString stringWithUTF8String:day.c_str()];
        return [totals[key] unsignedLongLongValue];
      });
  if (changed) _medalDirty = true;
  [self saveMedals];
}

- (unsigned long long)medalPeriodValue:(niuma::medal::Period)period {
  NSDateComponents *comp = [RecordCalendar() components:
      NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:NSDate.date];
  const int year = (int)comp.year, month = (int)comp.month, day = (int)comp.day;
  if (period == niuma::medal::Period::Day)
    return [self.dailyTotals[DateKeyForDate(NSDate.date)] unsignedLongLongValue];
  std::vector<std::string> keys = period == niuma::medal::Period::Week
      ? niuma::curve::WeekDayKeys(year, month, day)
      : niuma::curve::MonthDayKeys(year, month);
  return niuma::medal::SumRange(keys, [self](const std::string &key) -> std::uint64_t {
    NSString *k = [NSString stringWithUTF8String:key.c_str()];
    return [self.dailyTotals[k] unsignedLongLongValue];
  });
}

- (void)evaluateMedals {
  NSDateComponents *comp = [RecordCalendar() components:
      NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:NSDate.date];
  const int year = (int)comp.year, month = (int)comp.month, day = (int)comp.day;
  NSString *todayKey = DateKeyForDate(NSDate.date);
  const std::string today(todayKey.UTF8String ?: "");
  const niuma::medal::Thresholds thresholds = niuma::medal::BuiltinThresholds();
  bool changed = false;
  changed |= niuma::medal::EvaluatePeriod(&_medalEarned, niuma::medal::Period::Day, thresholds,
      niuma::medal::DayPeriodKey(today), today,
      [self.dailyTotals[todayKey] unsignedLongLongValue]);
  changed |= niuma::medal::EvaluatePeriod(&_medalEarned, niuma::medal::Period::Week, thresholds,
      niuma::medal::WeekPeriodKey(year, month, day), today, [self medalPeriodValue:niuma::medal::Period::Week]);
  changed |= niuma::medal::EvaluatePeriod(&_medalEarned, niuma::medal::Period::Month, thresholds,
      niuma::medal::MonthPeriodKey(year, month), today, [self medalPeriodValue:niuma::medal::Period::Month]);
  changed |= niuma::medal::UpdateAchievement(&_medalEarned, today);
  if (changed) {
    _medalDirty = true;
    [self saveMedals];
    if (self.medalWindow.isVisible) [self refreshMedalWall];
  }
}

- (void)saveMedals {
  if (!self.metrics) return;
  NSMutableDictionary *medals = [self.metrics medals];
  medals[@"thresholds_version"] = kNiuMa096ThresholdsVersion;
  NSMutableDictionary *earned = [NSMutableDictionary dictionaryWithCapacity:_medalEarned.size()];
  for (const auto &entry : _medalEarned) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"count"] = @(entry.second.count);
    if (!entry.second.first_earned_day.empty())
      record[@"first_earned_day"] = [NSString stringWithUTF8String:entry.second.first_earned_day.c_str()];
    if (!entry.second.last_period.empty())
      record[@"last_period"] = [NSString stringWithUTF8String:entry.second.last_period.c_str()];
    earned[[NSString stringWithUTF8String:entry.first.c_str()]] = record;
  }
  medals[@"earned"] = earned;
  [self.metrics save];
  _medalDirty = false;
}

- (void)toggleMedalWall:(id)sender {
  (void)sender;
  BOOL expanded = self.medalWallToggle.state == NSControlStateValueOn;
  self.medalWallContainer.hidden = !expanded;
  [self refreshMedalWall];
}

- (void)refreshMedalWall {
  if (!self.medalWindow) return;
  int litCount = 0;
  for (const auto &entry : _medalEarned)
    if (entry.second.lit) ++litCount;
  BOOL achievement = _medalEarned.count("achievement.all") && _medalEarned["achievement.all"].lit;
  self.medalSummaryLabel.stringValue = [NSString stringWithFormat:
      UiText(@"已点亮 %d / 9 枚勋章 · 集齐成就：%@", @"Unlocked %d / 9 medals · Collector: %@"),
      litCount, achievement ? UiText(@"已达成", @"Achieved") : UiText(@"未达成", @"Not yet")];

  // 重建勋章墙网格（默认收起时隐藏）。
  for (NSView *view in self.medalWallContainer.subviews) [view removeFromSuperview];
  const niuma::medal::Thresholds thresholds = niuma::medal::BuiltinThresholds();
  const CGFloat cellW = 190, cellH = 96;
  for (int row = 0; row < 3; ++row) {
    niuma::medal::Period period = (niuma::medal::Period)row;
    CGFloat rowY = 300 - row * 104;
    for (int tier = 0; tier < 3; ++tier) {
      std::string key = niuma::medal::MedalKey(period, tier);
      auto it = _medalEarned.find(key);
      BOOL lit = it != _medalEarned.end() && it->second.lit;
      NSString *text;
      if (lit) {
        NSString *first = [NSString stringWithUTF8String:it->second.first_earned_day.c_str()];
        text = [NSString stringWithFormat:@"%@ %@ · %@\n%@ ×%u\n%@ %@",
            NMMedalIcon(tier), NMMedalPeriodLabel(period), NMMedalTierLabel(tier),
            UiText(@"已点亮", @"Unlocked"), it->second.count,
            UiText(@"首次", @"First"), first.length ? first : @"—"];
      } else {
        text = [NSString stringWithFormat:@"🔒 %@ · %@\n%@\n%@ %llu",
            NMMedalPeriodLabel(period), NMMedalTierLabel(tier),
            UiText(@"未点亮", @"Locked"),
            UiText(@"阈值", @"Threshold"), (unsigned long long)thresholds.For(period)[tier]];
      }
      NSTextField *cell = [NSTextField wrappingLabelWithString:text];
      cell.frame = NSMakeRect(tier * (cellW + 10), rowY, cellW, cellH);
      cell.font = [NSFont systemFontOfSize:12];
      cell.textColor = lit ? NMUiInk() : NMUiMuted();
      cell.alignment = NSTextAlignmentCenter;
      cell.wantsLayer = YES;
      cell.layer.backgroundColor = (lit ? [NSColor colorWithCalibratedRed:.99 green:.95 blue:.86 alpha:1]
                                        : [NSColor colorWithCalibratedWhite:.96 alpha:1]).CGColor;
      cell.layer.cornerRadius = 10;
      [self.medalWallContainer addSubview:cell];
    }
  }
  // 集齐成就
  BOOL achLit = _medalEarned.count("achievement.all") && _medalEarned["achievement.all"].lit;
  NSTextField *ach = [NSTextField wrappingLabelWithString:achLit
      ? [NSString stringWithFormat:@"🏆 %@\n%@ %@", UiText(@"集齐成就", @"Collector Achievement"),
          UiText(@"已于", @"Achieved"), [NSString stringWithUTF8String:_medalEarned["achievement.all"].first_earned_day.c_str()]]
      : [NSString stringWithFormat:@"🏆 %@\n%@", UiText(@"集齐成就", @"Collector Achievement"), UiText(@"集齐 9 枚勋章后解锁", @"Unlocks after all 9 medals")]];
  ach.frame = NSMakeRect(0, 0, cellW * 3 + 20, 80);
  ach.font = [NSFont systemFontOfSize:12];
  ach.alignment = NSTextAlignmentCenter;
  ach.textColor = achLit ? NMUiInk() : NMUiMuted();
  [self.medalWallContainer addSubview:ach];

  // 分享下拉：只列出已点亮的勋章。
  [self.medalShareControl removeAllItems];
  for (int row = 0; row < 3; ++row) {
    niuma::medal::Period period = (niuma::medal::Period)row;
    for (int tier = 0; tier < 3; ++tier) {
      std::string key = niuma::medal::MedalKey(period, tier);
      auto it = _medalEarned.find(key);
      if (it == _medalEarned.end() || !it->second.lit) continue;
      NSString *title = [NSString stringWithFormat:@"%@ %@ · %@", NMMedalIcon(tier),
          NMMedalPeriodLabel(period), NMMedalTierLabel(tier)];
      [self.medalShareControl addItemWithTitle:title];
      self.medalShareControl.lastItem.representedObject =
          [NSString stringWithUTF8String:key.c_str()];
    }
  }
  if (achLit) {
    [self.medalShareControl addItemWithTitle:[NSString stringWithFormat:@"🏆 %@",
        UiText(@"集齐成就", @"Collector Achievement")]];
    self.medalShareControl.lastItem.representedObject = @"achievement.all";
  }
  BOOL any = self.medalShareControl.numberOfItems > 0;
  self.medalShareControl.enabled = any;
  self.medalShareButton.enabled = any;
  if (!any) {
    [self.medalShareControl addItemWithTitle:UiText(@"暂无已点亮勋章", @"No medals yet")];
    self.medalShareControl.enabled = NO;
  }
}

- (void)showMedals:(id)sender {
  (void)sender;
  if (!self.medalWindow) {
    NSRect frame = NSMakeRect(0, 0, 660, 680);
    NSView *content = [[NSView alloc] initWithFrame:frame];
    self.medalSummaryLabel = [NSTextField labelWithString:@""];
    self.medalSummaryLabel.frame = NSMakeRect(24, 632, 612, 26);
    self.medalSummaryLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    [content addSubview:self.medalSummaryLabel];
    self.medalWallToggle = [NSButton checkboxWithTitle:UiText(@"展开勋章墙", @"Show medal wall")
        target:self action:@selector(toggleMedalWall:)];
    self.medalWallToggle.frame = NSMakeRect(24, 598, 240, 24);
    self.medalWallToggle.state = NSControlStateValueOff;  // 设置内默认收起
    [content addSubview:self.medalWallToggle];
    self.medalWallContainer = [[NSView alloc] initWithFrame:NSMakeRect(24, 170, 612, 400)];
    self.medalWallContainer.hidden = YES;
    [content addSubview:self.medalWallContainer];
    NSTextField *shareLabel = [NSTextField labelWithString:UiText(@"勋章分享图", @"Medal share image")];
    shareLabel.frame = NSMakeRect(24, 140, 200, 20);
    shareLabel.font = [NSFont systemFontOfSize:12];
    shareLabel.textColor = NMUiMuted();
    [content addSubview:shareLabel];
    self.medalShareControl = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(24, 106, 300, 28) pullsDown:NO];
    [content addSubview:self.medalShareControl];
    self.medalShareButton = [NSButton buttonWithTitle:UiText(@"导出分享图…", @"Export Share Image…")
        target:self action:@selector(shareSelectedMedal:)];
    self.medalShareButton.frame = NSMakeRect(336, 104, 180, 30);
    [content addSubview:self.medalShareButton];
    NSTextField *explanation = [NSTextField wrappingLabelWithString:UiText(
        @"勋章按自然日 / 自然周（周一–周日）/ 自然月归集，达到阈值即永久点亮并记录次数。阈值为 v3 占位值（thresholds_version = builtin-2026-11-08），上线后按 F0 新口径校准。分享图由用户主动导出，单张 PNG，不含本机路径、账号或原始时段数据。",
        @"Medals tally by natural day / week (Mon–Sun) / month; reaching a threshold permanently unlocks it and records the count. Thresholds are v3 placeholders (thresholds_version = builtin-2026-11-08) pending F0 calibration. Share images are exported by the user as a single PNG with no local paths, account IDs, or raw interval data.")];
    explanation.frame = NSMakeRect(24, 20, 470, 76);
    explanation.font = [NSFont systemFontOfSize:11];
    explanation.textColor = NMUiMuted();
    [content addSubview:explanation];
    NSButton *close = [NSButton buttonWithTitle:UiText(@"关闭", @"Close")
        target:self action:@selector(closeMedals:)];
    close.frame = NSMakeRect(540, 20, 96, 30);
    close.keyEquivalent = @"\r";
    [content addSubview:close];
    self.medalWindow = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self.medalWindow.title = UiText(@"勋章与成就", @"Medals & Achievements");
    self.medalWindow.contentView = content;
    self.medalWindow.releasedWhenClosed = NO;
    if (gIsolatedAcceptance) self.medalWindow.restorable = NO;
    NMUiWindow(self.medalWindow);
    [self.medalWindow center];
  }
  [self evaluateMedals];
  [self refreshMedalWall];
  [NSApp activateIgnoringOtherApps:YES];
  [self.medalWindow makeKeyAndOrderFront:nil];
}

- (void)closeMedals:(id)sender {
  (void)sender;
  [self.medalWindow close];
}

- (void)shareSelectedMedal:(id)sender {
  (void)sender;
  NSString *key = self.medalShareControl.selectedItem.representedObject;
  if (![key isKindOfClass:NSString.class]) return;
  const std::string medalKey(key.UTF8String ?: "");
  niuma::medal::Period period = niuma::medal::Period::Day;
  int tier = 0;
  const bool isAchievement = medalKey == "achievement.all";
  if (!isAchievement && !niuma::medal::ParseMedalKey(medalKey, &period, &tier)) return;
  auto it = _medalEarned.find(medalKey);
  if (it == _medalEarned.end() || !it->second.lit) return;

  NMShareCardModel *model = [NMShareCardModel new];
  model.kind = NMShareCardKindMedal;
  model.locale = CurrentUiLanguageTag();
  model.appVersion = kNiuMa096AppVersion;
  model.generatedOn = DateKeyForDate(NSDate.date);
  model.title = UiText(@"牛马电子功德", @"NiuMa Merit");
  model.footerProduct = UiText(@"牛马电子功德", @"NiuMa Merit");
  model.footerWatermark = @"niuma-merit 0.9.6";
  model.medalEarnedDay = [NSString stringWithUTF8String:it->second.first_earned_day.c_str()];
  model.medalCount = it->second.count;
  if (isAchievement) {
    model.subtitle = UiText(@"集齐成就", @"Collector Achievement");
    model.meritPeriod = @"all";
    unsigned long long total = 0;
    for (NSString *k in self.dailyTotals) {
      unsigned long long v = [self.dailyTotals[k] unsignedLongLongValue];
      total = (v > ULLONG_MAX - total) ? ULLONG_MAX : total + v;
    }
    model.meritValue = total;
    model.medalPeriod = @"all";
    model.medalTier = @"gold";
  } else {
    model.medalPeriod = [NSString stringWithUTF8String:niuma::medal::PeriodName(period)];
    model.medalTier = [NSString stringWithUTF8String:niuma::medal::TierName(tier)];
    model.meritPeriod = model.medalPeriod;
    model.meritValue = [self medalPeriodValue:period];
    NSString *periodName = NMMedalPeriodLabel(period);
    // zh-Hans/zh-Hant:「月金牌」；ja:「月の金」；en:「Monthly Gold」。
    switch (NMCurrentUiLanguage()) {
      case NMUiLanguageSimplifiedChinese:
      case NMUiLanguageTraditionalChinese:
        model.subtitle = [NSString stringWithFormat:@"%@%@牌", periodName, NMMedalTierLabel(tier)];
        break;
      case NMUiLanguageJapanese:
        model.subtitle = [NSString stringWithFormat:@"%@の%@", periodName, NMMedalTierLabel(tier)];
        break;
      case NMUiLanguageEnglish:
        model.subtitle = [NSString stringWithFormat:@"%@ %@", NMMedalPeriodEnglish(period),
            NMMedalTierEnglish(tier)];
        break;
    }
  }
  if (self.encouragerActive) {
    model.moneyDisplay = self.encouragerDisplayAmount;
    model.moneyCurrency = self.encouragerCurrency;
    model.moneyExponent = niuma::encourager::ExponentForCode(
        std::string(self.encouragerCurrency.UTF8String ?: "CNY"));
    model.moneyAmountMinor = 0;
  }
  NSData *png = NMRenderShareCardPNG(model, 1000, 1250);
  NSString *defaultName = isAchievement ? @"niuma-merit-achievement.png"
      : [NSString stringWithFormat:@"niuma-merit-medal-%@-%@.png",
          model.medalPeriod, model.medalTier];
  if (!png || !NMSaveShareCardPNG(png, self.medalWindow, defaultName)) {
    if (!png) {
      NSAlert *alert = [[NMUiAlert alloc] init];
      alert.messageText = UiText(@"导出失败", @"Export Failed");
      alert.informativeText = UiText(@"未能生成分享图，请稍后重试。",
          @"Could not generate the share image. Please try again.");
      [alert addButtonWithTitle:UiText(@"好", @"OK")];
      [alert runModal];
    }
  }
}

- (void)loadState {
  id<NMMeritPreferences> defaults = MeritPreferences();
  self.total = [defaults integerForKey:kTotal];
  NSDictionary *storedDaily = [defaults dictionaryForKey:kDailyTotals];
  self.dailyTotals = storedDaily ? [storedDaily mutableCopy] : [NSMutableDictionary dictionary];
  self.currentDayKey = DateKeyForDate(NSDate.date);
  self.todayTotal = self.dailyTotals[self.currentDayKey].longLongValue;
  self.strikeActive = NO;
  self.strikeStartTime = -1;
  self.lastInputTime = 0;
  self.smoothedInputInterval = kDefaultStrikeDuration;
  self.activeStrikeDuration = kDefaultStrikeDuration;
  self.inputMonitoringAuthorized = NO;
  self.selectedAppearanceId = [defaults stringForKey:kSelectedAppearance];
  if (!self.selectedAppearanceId.length ||
      ([self.selectedAppearanceId hasPrefix:@"builtin."] &&
       !NMIsKnownBuiltinId(self.selectedAppearanceId))) {
    self.selectedAppearanceId = kBuiltinWoodfishId;
  }
  self.selectedScene = NMSceneForBuiltinId(self.selectedAppearanceId);
  id storedScale = [defaults objectForKey:kAppearanceScale];
  CGFloat appearanceScale = storedScale ? [storedScale doubleValue] : kDefaultAppearanceScale;
  if (!std::isfinite(appearanceScale)) appearanceScale = kDefaultAppearanceScale;
  self.appearanceScale = std::clamp(appearanceScale, kMinAppearanceScale, kMaxAppearanceScale);
}

- (void)saveState {
  [self drainInput];
  [self markCurveHeartbeat];
  [self evaluateMedals];
  if (_curveDirty &&
      NSProcessInfo.processInfo.systemUptime - _curveLastFlushUptime >= 15)
    [self flushCurve];
  if (!self.dirty) return;
  id<NMMeritPreferences> defaults = MeritPreferences();
  [defaults setInteger:self.total forKey:kTotal];
  [defaults setObject:self.dailyTotals forKey:kDailyTotals];
  self.dirty = NO;
}

// Largest effective scale that keeps the whole widget inside the active
// screen's usable area (F1: clamp the upper bound to the screen).
- (CGFloat)maxUiScaleForScreen {
  NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
  if (!screen) return CGFLOAT_MAX;
  NSRect visible = screen.visibleFrame;
  const CGFloat margin = 8.0;
  const CGFloat extra = [self desiredExtraRegionHeight];
  const CGFloat byWidth = (NSWidth(visible) - margin * 2) / kWindowWidth;
  const CGFloat byHeight = (NSHeight(visible) - margin * 2) / (kWindowHeight + extra);
  return MAX(kBaseUiScale * kMinAppearanceScale, MIN(byWidth, byHeight));
}

- (CGFloat)uiScale {
  const CGFloat requested = kBaseUiScale * self.appearanceScale;
  return MIN(requested, [self maxUiScaleForScreen]);
}

- (void)resizeAppearanceWindow {
  if (!self.window) { [self.view setNeedsDisplay:YES]; return; }
  const CGFloat ui = self.uiScale;
  const CGFloat extra = [self desiredExtraRegionHeight];
  CGFloat width = std::round(kWindowWidth * ui);
  CGFloat height = std::round((kWindowHeight + extra) * ui);
  NSRect old = self.window.frame;
  // Anchor the top-left corner so resizing grows/shrinks toward the screen
  // center instead of sliding the widget off an edge.
  const CGFloat top = NSMaxY(old);
  const CGFloat left = NSMinX(old);
  NSRect frame = NSMakeRect(left, top - height, width, height);
  NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
  if (screen) {
    NSRect visible = screen.visibleFrame;
    if (NSWidth(frame) > NSWidth(visible)) frame.size.width = NSWidth(visible);
    if (NSHeight(frame) > NSHeight(visible)) frame.size.height = NSHeight(visible);
    // Re-clamp the origin so the resized window stays fully on screen (F1).
    frame.origin.x = MIN(MAX(NSMinX(visible), frame.origin.x), NSMaxX(visible) - NSWidth(frame));
    frame.origin.y = MIN(MAX(NSMinY(visible), frame.origin.y), NSMaxY(visible) - NSHeight(frame));
  }
  self.regionLayoutHeight = extra;
  [self.window setFrame:frame display:YES];
  [self.view setFrameSize:frame.size];
  [self.view setNeedsDisplay:YES];
}

- (void)updateAppearanceScaleLabels {
  if (!self.appearanceScaleValueLabel) return;
  const NSInteger requested = (NSInteger)std::lround(self.appearanceScale * 100.0);
  const NSInteger effective = (NSInteger)std::lround((self.uiScale / kBaseUiScale) * 100.0);
  self.appearanceScaleValueLabel.stringValue = effective < requested - 1
      ? [NSString stringWithFormat:UiText(@"%ld%%（屏幕限制 %ld%%）", @"%ld%% (screen limit %ld%%)"),
            (long)requested, (long)effective]
      : [NSString stringWithFormat:@"%ld%%", (long)requested];
}

- (void)applyAppearanceScale:(CGFloat)scale persist:(BOOL)persist {
  if (!std::isfinite(scale)) scale = kDefaultAppearanceScale;
  scale = std::clamp(scale, kMinAppearanceScale, kMaxAppearanceScale);
  self.appearanceScale = scale;
  if (persist) [MeritPreferences() setObject:@(scale) forKey:kAppearanceScale];
  [self updateAppearanceScaleLabels];
  [self resizeAppearanceWindow];
}

- (void)appearanceScaleSliderChanged:(id)sender {
  (void)sender;
  [self applyAppearanceScale:self.appearanceScaleSlider.doubleValue persist:YES];
}

- (void)resetAppearanceScale:(id)sender {
  (void)sender;
  self.appearanceScaleSlider.doubleValue = kDefaultAppearanceScale;
  [self applyAppearanceScale:kDefaultAppearanceScale persist:YES];
}

- (void)closeAppearanceScaleSettings:(id)sender {
  (void)sender;
  [self.appearanceScaleWindow close];
}

- (void)showAppearanceScaleSettings:(id)sender {
  (void)sender;
  if (!self.appearanceScaleWindow) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 210)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = UiText(@"形象大小", @"Appearance Size");
    window.releasedWhenClosed = NO;
    window.delegate = self;
    if (gIsolatedAcceptance) window.restorable = NO;
    NSView *content = window.contentView;
    NSTextField *title = [NSTextField labelWithString:UiText(@"形象大小（拖动实时预览）", @"Appearance size (live preview)")];
    title.frame = NSMakeRect(24, 168, 280, 22);
    [content addSubview:title];
    self.appearanceScaleValueLabel = [NSTextField labelWithString:@"100%"];
    self.appearanceScaleValueLabel.frame = NSMakeRect(300, 168, 96, 22);
    self.appearanceScaleValueLabel.alignment = NSTextAlignmentRight;
    self.appearanceScaleValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    [content addSubview:self.appearanceScaleValueLabel];
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(24, 126, 372, 26)];
    slider.minValue = kMinAppearanceScale;
    slider.maxValue = kMaxAppearanceScale;
    slider.doubleValue = self.appearanceScale;
    slider.continuous = YES;
    slider.numberOfTickMarks = 13;  // 60%..180% in 10% steps (cosmetic only)
    slider.allowsTickMarkValuesOnly = NO;
    slider.tickMarkPosition = NSTickMarkPositionBelow;
    slider.target = self;
    slider.action = @selector(appearanceScaleSliderChanged:);
    slider.accessibilityLabel = UiText(@"形象大小", @"Appearance size");
    self.appearanceScaleSlider = slider;
    [content addSubview:slider];
    NSTextField *minLabel = [NSTextField labelWithString:UiText(@"60% 最小", @"60% Smallest")];
    minLabel.frame = NSMakeRect(24, 104, 120, 16);
    minLabel.font = [NSFont systemFontOfSize:11];
    minLabel.textColor = NMUiMuted();
    [content addSubview:minLabel];
    NSTextField *maxLabel = [NSTextField labelWithString:UiText(@"180% 最大", @"180% Largest")];
    maxLabel.frame = NSMakeRect(276, 104, 120, 16);
    maxLabel.font = [NSFont systemFontOfSize:11];
    maxLabel.textColor = NMUiMuted();
    maxLabel.alignment = NSTextAlignmentRight;
    [content addSubview:maxLabel];
    NSTextField *hint = [NSTextField wrappingLabelWithString:UiText(
        @"窗口、形象和气泡一起等比缩放；超出屏幕可用区域时会限制大小并重新放进屏幕。仅主窗口变化，日历与设置窗口保持原尺寸。",
        @"The window, artwork and bubble scale together. On small screens the size is capped and kept on-screen. Only the main widget changes; the calendar and settings windows keep their size.")];
    hint.frame = NSMakeRect(24, 52, 372, 44);
    hint.font = [NSFont systemFontOfSize:12];
    hint.textColor = NMUiMuted();
    [content addSubview:hint];
    NSButton *reset = [NSButton buttonWithTitle:UiText(@"恢复默认", @"Reset") target:self action:@selector(resetAppearanceScale:)];
    reset.frame = NSMakeRect(24, 14, 110, 30);
    [content addSubview:reset];
    NSButton *done = [NSButton buttonWithTitle:UiText(@"完成", @"Done") target:self action:@selector(closeAppearanceScaleSettings:)];
    done.frame = NSMakeRect(300, 14, 96, 30);
    done.keyEquivalent = @"\r";
    [content addSubview:done];
    self.appearanceScaleWindow = window;
    NMUiWindow(window);
    [window center];
  }
  self.appearanceScaleSlider.doubleValue = self.appearanceScale;
  [self updateAppearanceScaleLabels];
  [NSApp activateIgnoringOtherApps:YES];
  [self.appearanceScaleWindow makeKeyAndOrderFront:nil];
}


- (void)ensureCurrentDay {
  NSString *today = DateKeyForDate(NSDate.date);
  if ([today isEqualToString:self.currentDayKey]) return;
  self.currentDayKey = today;
  self.todayTotal = self.dailyTotals[today].longLongValue;
  if (!self.appearanceHidden) [self.view setNeedsDisplay:YES];
  if (self.calendarWindow.isVisible) [self.calendarView setNeedsDisplay:YES];
}

- (NSURL *)launchAgentURL {
  if (gIsolatedAcceptance) return nil;
  NSURL *libraryURL = [NSFileManager.defaultManager
      URLsForDirectory:NSLibraryDirectory
             inDomains:NSUserDomainMask].firstObject;
  NSURL *launchAgentsURL = [libraryURL URLByAppendingPathComponent:@"LaunchAgents"
                                                       isDirectory:YES];
  NSString *fileName = [kLaunchAgentLabel stringByAppendingString:@".plist"];
  return [launchAgentsURL URLByAppendingPathComponent:fileName];
}

- (BOOL)isLaunchAtLoginEnabled {
  if (gIsolatedAcceptance) return NO;
  if (@available(macOS 13.0, *)) {
    return [self loginStartupState] == NMLoginStartupEnabled;
  }
  id<NMMeritPreferences> defaults = MeritPreferences();
  if (![defaults boolForKey:kLaunchAtLoginEnabled]) return NO;
  return [NSFileManager.defaultManager fileExistsAtPath:self.launchAgentURL.path];
}

- (NMLoginStartupCoordinator *)modernLoginStartup {
  if (@available(macOS 13.0, *)) {
    if (!self.loginStartup) {
      self.loginStartup = [[NMLoginStartupCoordinator alloc] init];
      self.loginStartup.service = [[NMMainAppLoginService alloc] init];
      self.loginStartup.preferences = MeritPreferences();
      NSURL *legacyURL = self.launchAgentURL;
      self.loginStartup.retireLegacy = ^BOOL(NSError **error) {
        return NMRetireLegacyStartup(legacyURL, error);
      };
    }
    return self.loginStartup;
  }
  return nil;
}

- (NMLoginStartupState)loginStartupState {
  if (gIsolatedAcceptance) return NMLoginStartupDisabled;
  if (@available(macOS 13.0, *)) return self.modernLoginStartup.service.state;
  return self.isLaunchAtLoginEnabled ? NMLoginStartupEnabled : NMLoginStartupDisabled;
}

- (BOOL)canConfigureModernLoginStartup:(BOOL)showError {
  NSURL *running = NSBundle.mainBundle.bundleURL.URLByResolvingSymlinksInPath.URLByStandardizingPath;
  NSURL *persistent = NMPersistentApplicationURL(NSBundle.mainBundle,
      NSProcessInfo.processInfo.arguments);
  NSString *parent = running.path.stringByDeletingLastPathComponent;
  BOOL installed = [parent isEqualToString:@"/Applications"] ||
      [parent isEqualToString:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
  if (installed && [running.path isEqualToString:persistent.path] &&
      !NMIsTemporaryApplicationURL(running)) return YES;
  if (showError) {
    NSAlert *alert = [[NMUiAlert alloc] init];
    alert.messageText = UiText(@"请从应用程序中打开", @"Open the Installed App");
    alert.informativeText = UiText(@"请完成安装，再从“应用程序”打开牛马后设置登录启动。",
        @"Finish installation, then open NiuMa Merit from Applications to configure login startup.");
    [alert addButtonWithTitle:UiText(@"知道了", @"OK")];
    [alert runModal];
  }
  return NO;
}

- (void)showLoginStartupApproval {
  if (@available(macOS 13.0, *)) {
    NSAlert *alert = [[NMUiAlert alloc] init];
    alert.messageText = UiText(@"登录启动尚未获允许", @"Login Startup Needs Approval");
    alert.informativeText = UiText(@"请在系统设置的“登录项”中允许牛马。也可以在这里关闭登录启动。",
        @"Allow NiuMa Merit in System Settings > Login Items. You can also turn login startup off here.");
    [alert addButtonWithTitle:UiText(@"打开系统设置", @"Open System Settings")];
    [alert addButtonWithTitle:UiText(@"关闭自启动", @"Turn Off Login Startup")];
    [alert addButtonWithTitle:UiText(@"取消", @"Cancel")];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) [SMAppService openSystemSettingsLoginItems];
    else if (response == NSAlertSecondButtonReturn)
      [self setLaunchAtLoginEnabled:NO showError:YES];
  }
}

- (BOOL)setLaunchAtLoginEnabled:(BOOL)enabled showError:(BOOL)showError {
  if (gIsolatedAcceptance) return NO;
  if (@available(macOS 13.0, *)) {
    if (![self canConfigureModernLoginStartup:showError]) return NO;
    NSError *failure = nil;
    BOOL succeeded = [self.modernLoginStartup setEnabled:enabled error:&failure];
    self.loginStartupError = failure;
    if (!succeeded && showError) {
      NSAlert *alert = [[NMUiAlert alloc] init];
      alert.messageText = UiText(@"无法修改登录启动项", @"Unable to Change Login Startup");
      alert.informativeText = UiText(
          @"系统未能完成登录启动设置或旧启动项迁移，请稍后重试。原有功德、形象和日历不受影响。",
          @"The system could not finish configuring login startup or migrating the old item. Try again later. Your merit, appearances and calendar are unchanged.");
      [alert addButtonWithTitle:UiText(@"知道了", @"OK")];
      [alert runModal];
    } else if (succeeded && enabled && showError &&
        [self loginStartupState] == NMLoginStartupRequiresApproval) {
      [self showLoginStartupApproval];
    }
    return succeeded;
  }
  NSFileManager *fileManager = NSFileManager.defaultManager;
  NSURL *agentURL = self.launchAgentURL;
  NSError *error = nil;
  BOOL succeeded = YES;

  if (enabled) {
    [fileManager createDirectoryAtURL:agentURL.URLByDeletingLastPathComponent
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&error];
    if (!error) {
      NSURL *persistent = NMPersistentApplicationURL(NSBundle.mainBundle,
          NSProcessInfo.processInfo.arguments);
      if (!persistent) {
        if (showError) {
          NSAlert *alert = [[NMUiAlert alloc] init];
          alert.messageText = UiText(@"请先完成安装", @"Complete installation first");
          alert.informativeText = UiText(@"请将牛马安装到“应用程序”后再开启登录启动。",
              @"Install NiuMa Merit in Applications before enabling login startup.");
          [alert addButtonWithTitle:UiText(@"知道了", @"OK")];
          [alert runModal];
        }
        return NO;
      }
      NSString *bundlePath = persistent.path;
      NSDictionary *propertyList = @{
        @"Label": kLaunchAgentLabel,
        @"ProgramArguments": @[@"/usr/bin/open", @"-a", bundlePath,
                                @"--args", @"--autostart"],
        @"RunAtLoad": @YES,
        @"KeepAlive": @NO
      };
      NSData *data = [NSPropertyListSerialization
          dataWithPropertyList:propertyList
                        format:NSPropertyListXMLFormat_v1_0
                       options:0
                         error:&error];
      if (data && !error) {
        succeeded = [data writeToURL:agentURL
                             options:NSDataWritingAtomic
                               error:&error];
      } else {
        succeeded = NO;
      }
    } else {
      succeeded = NO;
    }
  } else if ([fileManager fileExistsAtPath:agentURL.path]) {
    succeeded = [fileManager removeItemAtURL:agentURL error:&error];
  }

  if (succeeded) {
    id<NMMeritPreferences> defaults = MeritPreferences();
    [defaults setBool:YES forKey:kLaunchAtLoginConfigured];
    [defaults setBool:enabled forKey:kLaunchAtLoginEnabled];
  } else if (showError) {
    NSAlert *alert = [[NMUiAlert alloc] init];
    alert.messageText = UiText(@"无法修改登录启动项", @"Unable to change login startup");
    alert.informativeText = error.localizedDescription ?:
        UiText(@"请稍后重试。", @"Please try again later.");
    [alert addButtonWithTitle:UiText(@"知道了", @"OK")];
    [alert runModal];
  }
  return succeeded;
}

- (void)configureLaunchAtLogin {
  if (gIsolatedAcceptance) return;
  // A diagnostic candidate must not rewrite the installed login item's path.
  if ([NSProcessInfo.processInfo.arguments containsObject:@"--listener-acceptance"]) return;
  if (@available(macOS 13.0, *)) {
    if (![self canConfigureModernLoginStartup:NO]) return;
    BOOL legacyDenied = [NSFileManager.defaultManager fileExistsAtPath:self.launchAgentURL.path] &&
        [SMAppService statusForLegacyURL:self.launchAgentURL] == SMAppServiceStatusRequiresApproval;
    NSError *failure = nil;
    [self.modernLoginStartup configureRespectingLegacyDenial:legacyDenied error:&failure];
    self.loginStartupError = failure;
    return;
  }
  id<NMMeritPreferences> defaults = MeritPreferences();
  if ([defaults objectForKey:kLaunchAtLoginConfigured] == nil) {
    [self setLaunchAtLoginEnabled:YES showError:NO];
  } else if ([defaults boolForKey:kLaunchAtLoginEnabled]) {
    // Refresh the bundle path after the user moves or updates the app.
    [self setLaunchAtLoginEnabled:YES showError:NO];
  }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  self.launchedAutomatically =
      [NSProcessInfo.processInfo.arguments containsObject:@"--autostart"];
  // SMAppService launches the main app without the legacy --autostart argument.
  NSAppleEventDescriptor *launchEvent = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
  if (launchEvent.eventClass == kCoreEventClass && launchEvent.eventID == kAEOpenApplication &&
      [launchEvent paramDescriptorForKeyword:keyAEPropData].enumCodeValue == keyAELaunchedAsLogInItem)
    self.launchedAutomatically = YES;
  self.diagnostics = [NSProcessInfo.processInfo.arguments containsObject:@"--diagnostics"];
  NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
  if (bundleIdentifier.length > 0 && !gIsolatedAcceptance) {
    pid_t currentProcess = NSProcessInfo.processInfo.processIdentifier;
    for (NSRunningApplication *running in
         [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier]) {
      if (running.processIdentifier != currentProcess) {
        if (!self.launchedAutomatically) {
          [running activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        }
        [NSApp terminate:nil];
        return;
      }
    }
  }
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [self loadState];
  [self loadOffworkState];
  {
    NSString *support = gIsolatedAcceptance ? gAcceptanceRootPath :
        NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (support.length > 0) {
      NSString *metricsDir = [support stringByAppendingPathComponent:@"NiuMaMerit"];
      self.metrics = [NMMetricsStore storeInDirectory:metricsDir];
      [self.metrics load];
      // CONTRACT_096 §5.1.4：prefs.ui_language 由系统语言推导（§10）。启动时在
      // 内存中镜像当前推导值；持久化沿用既有保存路径（首次启动的补授保存会带出），
      // 不为此增加启动期磁盘写入。
      [self.metrics prefs][@"ui_language"] = CurrentUiLanguageTag();
      [self loadEncouragerState];
      [self loadCurveState];
      [self loadMedalsState];
      [self backfillMedalsFromHistory];
    }
  }
  if (!gIsolatedAcceptance || gAcceptanceRootPath.length) {
    NSString *support = gIsolatedAcceptance ? gAcceptanceRootPath :
        NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (support.length > 0) {
      NSString *reminderPath = [[support stringByAppendingPathComponent:@"NiuMaMerit"]
          stringByAppendingPathComponent:@"Reminders"];
      _reminderStore = std::make_unique<niuma::reminder::ReminderStore>(
          std::filesystem::path(reminderPath.fileSystemRepresentation));
      _catalogStore = std::make_unique<niuma::reminder::CatalogUpdateStore>(
          std::filesystem::path(reminderPath.fileSystemRepresentation) / "Catalog");
      _reminderCatalog = _catalogStore->Load(
          niuma::reminder::OfficialCatalogSignatureVerifier(), nullptr,
          &_reminderCatalogCommitUncertain);
      _reminderActivity.RestoreSegmentConsumed(_reminderStore->SegmentConsumed());
    }
  }
  const std::int64_t reminderStartupUtc =
      static_cast<std::int64_t>(NSDate.date.timeIntervalSince1970);
  const std::uint64_t reminderStartupMonotonic = ReminderContinuousTimeMs();
  const char *reminderStartupDate = DateKeyForDate(NSDate.date).UTF8String;
  _reminderClockGuard.Start(reminderStartupUtc, reminderStartupMonotonic,
      _reminderStore && _reminderStore->ClockGuard(reminderStartupUtc,
          reminderStartupDate ? reminderStartupDate : ""));
  [self configureLaunchAtLogin];

  self.view = [[MeritView alloc] initWithFrame:NSMakeRect(0, 0, kWindowWidth * self.uiScale, kWindowHeight * self.uiScale)];
  self.view.controller = self;
  self.view.scene = self.selectedScene;
  NSString *restoredAppearanceId = [self.selectedAppearanceId copy];
  [self reloadAppearancePacks];
  BOOL previousAppearanceMissing = restoredAppearanceId.length &&
      !NMIsKnownBuiltinId(restoredAppearanceId) &&
      ![self appearancePackWithId:restoredAppearanceId];
  [self applyAppearanceId:self.selectedAppearanceId];
  self.window = [[NSWindow alloc] initWithContentRect:self.view.bounds
                                            styleMask:NSWindowStyleMaskBorderless
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  self.window.releasedWhenClosed = NO;
  self.window.contentView = self.view;
  self.window.backgroundColor = NSColor.clearColor;
  self.window.opaque = NO;
  self.window.hasShadow = NO;
  self.window.level = NSFloatingWindowLevel;
  // Preserve Space behavior; the display policy can hide without stopping input.
  self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
      NSWindowCollectionBehaviorFullScreenAuxiliary;
  self.window.movableByWindowBackground = YES;
  BOOL restoredFrame = NO;
  if (gIsolatedAcceptance) {
    self.window.restorable = NO;
  } else {
    [self.window setFrameAutosaveName:@"NiuMaMeritPosition"];
    restoredFrame = [self.window setFrameUsingName:@"NiuMaMeritPosition"];
  }
  if (restoredFrame) {
    NSRect frame = self.window.frame;
    // Saved expanded frames use a lower origin; normalize without launch-to-launch drift.
    frame.origin.y += MAX(0.0, NSHeight(frame) - kWindowHeight * self.uiScale);
    frame.size = NSMakeSize(kWindowWidth * self.uiScale, kWindowHeight * self.uiScale);
    [self.window setFrame:frame display:NO];
  }
  BOOL frameIsVisible = NO;
  for (NSScreen *screen in NSScreen.screens) {
    NSRect intersection = NSIntersectionRect(self.window.frame, screen.visibleFrame);
    if (NSWidth(intersection) >= 24 && NSHeight(intersection) >= 24) {
      frameIsVisible = YES;
      break;
    }
  }
  if (!restoredFrame || !frameIsVisible) {
    NSScreen *screen = NSScreen.mainScreen;
    [self.window setFrameOrigin:NSMakePoint(NSMaxX(screen.visibleFrame) - 280 * self.uiScale,
                                           NSMaxY(screen.visibleFrame) - 270 * self.uiScale)];
  }
  id<NMMeritPreferences> visibilityDefaults = MeritPreferences();
  _visibility.autoHideFullscreen = [visibilityDefaults objectForKey:@"AutoHideFullscreen"] == nil ||
      [visibilityDefaults boolForKey:@"AutoHideFullscreen"];
  self.visibilityStatusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
  if (self.visibilityStatusItem.button) {
    self.visibilityStatusItem.button.title = gIsolatedAcceptance ? @"测" : @"功";
    self.visibilityStatusItem.button.toolTip = UiText(@"牛马电子功德 · 显示或隐藏形象", @"NiuMa Merit · Show or hide appearance");
    self.visibilityStatusItem.button.target = self;
    self.visibilityStatusItem.button.action = @selector(showStatusMenu:);
    [self.visibilityStatusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    _visibility.recoveryAvailable = true;
  }
  NSNotificationCenter *workspaceCenter = NSWorkspace.sharedWorkspace.notificationCenter;
  [workspaceCenter addObserver:self selector:@selector(refreshAppearanceVisibility:)
      name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
  [workspaceCenter addObserver:self selector:@selector(refreshAppearanceVisibility:)
      name:NSWorkspaceDidActivateApplicationNotification object:nil];
  [workspaceCenter addObserver:self selector:@selector(offworkWillSleep:) name:NSWorkspaceWillSleepNotification object:nil];
  [workspaceCenter addObserver:self selector:@selector(offworkClockChanged:) name:NSWorkspaceDidWakeNotification object:nil];
  [workspaceCenter addObserver:self selector:@selector(reminderDidResume:) name:NSWorkspaceDidWakeNotification object:nil];
  [workspaceCenter addObserver:self selector:@selector(offworkClockChanged:) name:NSWorkspaceSessionDidBecomeActiveNotification object:nil];
  [workspaceCenter addObserver:self selector:@selector(offworkWillPowerOff:) name:NSWorkspaceWillPowerOffNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(reminderScreensDidChange:)
      name:NSApplicationDidChangeScreenParametersNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(reminderScreensDidChange:)
      name:NSWindowDidMoveNotification object:self.window];
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(reminderScreensDidChange:)
      name:NSWindowDidResizeNotification object:self.window];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(offworkClockChanged:)
      name:NSSystemClockDidChangeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reminderObservationInterrupted:)
      name:NSSystemClockDidChangeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(offworkClockChanged:)
      name:NSSystemTimeZoneDidChangeNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reminderObservationInterrupted:)
      name:NSSystemTimeZoneDidChangeNotification object:nil];
  [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(reminderWillPause:)
      name:@"com.apple.screenIsLocked" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
  [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(offworkClockChanged:)
      name:@"com.apple.screenIsUnlocked" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
  [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(reminderDidResume:)
      name:@"com.apple.screenIsUnlocked" object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
  [self startOffworkTimer];
  [self startEncouragerTimer];
  [self evaluateMedals];
  [self.window orderFrontRegardless];
  [self refreshAppearanceVisibility:nil];
  if (previousAppearanceMissing || self.appearanceLoadError) {
    NSAlert *notice = [[NMUiAlert alloc] init];
    notice.alertStyle = NSAlertStyleWarning;
    notice.messageText = UiText(@"部分本地形象未能加载", @"Some Local Packs Are Unavailable");
    notice.informativeText = self.appearanceLoadError.localizedDescription ?: UiText(
        @"上次使用的形象文件缺失或未通过校验，暂时显示木鱼。原文件、功德和日历不删除；可重新导入原包。",
        @"The previous appearance is missing or failed verification. Woodfish is shown for now. Original files, counts and calendar are kept; re-import the pack.");
    [notice runModal];
  }

  self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:5
                                                    target:self
                                                  selector:@selector(saveState)
                                                  userInfo:nil
                                                   repeats:YES];
  [NSRunLoop.mainRunLoop addTimer:self.saveTimer forMode:NSRunLoopCommonModes];
  [NSRunLoop.mainRunLoop addTimer:self.saveTimer forMode:NSModalPanelRunLoopMode];
  self.dayTimer = [NSTimer scheduledTimerWithTimeInterval:30
                                                   target:self
                                                 selector:@selector(ensureCurrentDay)
                                                 userInfo:nil
                                                  repeats:YES];
  [NSRunLoop.mainRunLoop addTimer:self.dayTimer forMode:NSRunLoopCommonModes];
  [NSRunLoop.mainRunLoop addTimer:self.dayTimer forMode:NSModalPanelRunLoopMode];
  self.reminderTimer = [NSTimer scheduledTimerWithTimeInterval:1
      target:self selector:@selector(evaluateReminderActivity:) userInfo:nil repeats:YES];
  [NSRunLoop.mainRunLoop addTimer:self.reminderTimer forMode:NSRunLoopCommonModes];
  [NSRunLoop.mainRunLoop addTimer:self.reminderTimer forMode:NSModalPanelRunLoopMode];
  if (!gIsolatedAcceptance || gAcceptancePhysicalInput) {
    // Monitor tap health even on a silent autostart or after a failed installation.
    self.permissionPollTimer = [NSTimer timerWithTimeInterval:kPermissionPollInterval * 2
        target:self selector:@selector(checkPermission:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.permissionPollTimer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:self.permissionPollTimer forMode:NSModalPanelRunLoopMode];
    [self installEventTap];
    [self performSelector:@selector(showPermissionIntroIfNeeded) withObject:nil afterDelay:.7];
  }
  if (gReminderPreviewAcceptance) {
    [self presentReminderForTrigger:niuma::reminder::ActivitySampler::Trigger::HighIntensity];
    // Keep the preview process bounded on CI; this path is available only when
    // the explicit isolated-acceptance flags and an empty private temp root pass.
    [NSApp performSelector:@selector(terminate:) withObject:nil
        afterDelay:niuma::reminder::kReminderDisplayMilliseconds / 1000.0 + 4.0];
  }
  self.memoryPressure=dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,0,
      DISPATCH_MEMORYPRESSURE_WARN|DISPATCH_MEMORYPRESSURE_CRITICAL,dispatch_get_main_queue());
  __weak MeritController *memoryOwner=self;
  dispatch_source_set_event_handler(self.memoryPressure,^{ [memoryOwner discardRebuildableResources]; });
  dispatch_resume(self.memoryPressure);
  self.readyForOpenedFiles = YES;
  if(gIsolatedAcceptance && gAcceptancePackPaths.count) {
    __weak MeritController *acceptanceOwner=self;
    dispatch_async(dispatch_get_main_queue(),^{
      [acceptanceOwner application:NSApp openFiles:gAcceptancePackPaths];
    });
  }
  NSArray<NSString *> *pending = [self.pendingOpenFiles copy];
  self.pendingOpenFiles = nil;
  if (pending.count) [self application:NSApp openFiles:pending];
}

- (void)application:(NSApplication *)application openFiles:(NSArray<NSString *> *)filenames {
  // Finder can deliver a document before launch has initialized the stores.
  if (!self.readyForOpenedFiles) {
    if (!self.pendingOpenFiles) self.pendingOpenFiles = [NSMutableArray array];
    [self.pendingOpenFiles addObjectsFromArray:filenames];
    return;
  }
  BOOL handledCatalog = NO, catalogsSucceeded = YES;
  NSMutableArray<NSString *> *archives = [NSMutableArray array];
  for (NSString *filename in filenames) {
    NSString *extension = filename.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"nmgtext"]) {
      handledCatalog = YES;
      if (![self importOfficialMessagesAtPath:filename]) catalogsSucceeded = NO;
      continue;
    }
    if ([extension isEqualToString:@"nmgpack"] ||
        [extension isEqualToString:@"nmgpacks"]) [archives addObject:filename];
  }
  if (archives.count == 0) {
    [application replyToOpenOrPrint:handledCatalog && catalogsSucceeded
        ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
    return;
  }
  filenames = archives;
  NSMutableSet<NSString *> *previousIds = [NSMutableSet set];
  for (NMAppearancePack *pack in self.installedAppearancePacks)
    [previousIds addObject:pack.identifier];
  NSMutableArray<NMAppearancePack *> *imported = [NSMutableArray array];
  NSMutableArray<NSString *> *failures = [NSMutableArray array];
  BOOL batch = filenames.count > 1;
  for (NSString *filename in filenames) {
    NSURL *source = [NSURL fileURLWithPath:filename];
    NSError *error = nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:filename]) {
      [failures addObject:[NSString stringWithFormat:
          UiText(@"%@：文件已移动或不存在。", @"%@: file moved or missing."), source.lastPathComponent]];
      continue;
    }
    if ([source.pathExtension.lowercaseString isEqualToString:@"nmgpacks"]) {
      batch = YES;
      NSArray<NMAppearancePack *> *packs =
          [NMAppearancePackStore installBatchArchiveAtURL:source error:&error];
      // Failed batches may already contain safely installed, verified members.
      NSArray *partial = error.userInfo[@"NMSuccessfulImports"];
      if (packs) [imported addObjectsFromArray:packs];
      else if ([partial isKindOfClass:NSArray.class]) [imported addObjectsFromArray:partial];
    } else {
      NMAppearancePack *pack = [NMAppearancePackStore installArchiveAtURL:source error:&error];
      if (pack) [imported addObject:pack];
    }
    if (error) [failures addObject:[NSString stringWithFormat:@"%@：%@",
        source.lastPathComponent, error.localizedDescription]];
  }

  const BOOL importsSucceeded = failures.count == 0;
  NSError *loadError = nil;
  self.installedAppearancePacks = [NMAppearancePackStore loadInstalledMetadata:&loadError];
  if (loadError) [failures addObject:loadError.localizedDescription];
  NSMutableSet<NSString *> *newIds = [NSMutableSet set];
  NSMutableSet<NSString *> *availableIds = [NSMutableSet set];
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (NMAppearancePack *pack in imported) {
    if (![self appearancePackWithId:pack.identifier]) {
      [failures addObject:[NSString stringWithFormat:
          UiText(@"%@：已保存但未能加载，未启用，原文件保留。",
                 @"%@: saved but unavailable; not enabled; original files kept."), pack.localizedName]];
      continue;
    }
    [availableIds addObject:pack.identifier];
    NSString *kind = nil;
    if (pack.alreadyInstalled) {
      kind = UiText(@"重复包，已保留原形象", @"Duplicate; existing pack kept");
    } else if ([previousIds containsObject:pack.identifier]) {
      kind = UiText(@"已更新", @"Updated");
    } else {
      [newIds addObject:pack.identifier];
      kind = UiText(@"本次新增", @"New in this import");
    }
    [lines addObject:[NSString stringWithFormat:@"%@ · %@", pack.localizedName, kind]];
  }
  self.newlyImportedIds = newIds;
  self.lastImportedIds = availableIds;
  BOOL singleEnabled = !batch && importsSucceeded && availableIds.count == 1;
  if (singleEnabled) {
    [self applyAppearanceId:availableIds.anyObject];
  } else if ([self appearancePackWithId:self.selectedAppearanceId]) {
    // Refresh an updated current pack, but never choose the last batch member.
    [self applyAppearanceId:self.selectedAppearanceId];
  }
  if (self.appearancePickerAlert) {
    self.pendingAppearanceId = self.selectedAppearanceId;
    self.appearancePickerAlert.accessoryView = [self appearanceGrid];
  }
  [application replyToOpenOrPrint:failures.count || !catalogsSucceeded
      ? NSApplicationDelegateReplyFailure : NSApplicationDelegateReplySuccess];
  NSAlert *alert = [[NMUiAlert alloc] init];
  alert.alertStyle = failures.count ? NSAlertStyleWarning : NSAlertStyleInformational;
  alert.messageText = singleEnabled
      ? UiText(@"导入完成，正在准备形象", @"Imported; Preparing Appearance")
      : failures.count
          ? (availableIds.count ? UiText(@"部分形象已导入", @"Some Packs Imported")
                                : UiText(@"未能导入形象", @"No Packs Imported"))
          : UiText(@"导入完成，当前形象未改变", @"Imported; Current Appearance Unchanged");
  NSString *summary = [NSString stringWithFormat:
      UiText(@"本次可用 %lu 个形象，新增 %lu 个。功德和日历不受影响。",
             @"%lu packs available from this import; %lu new. Counts and calendar are unchanged."),
      (unsigned long)availableIds.count, (unsigned long)newIds.count];
  if (!singleEnabled) summary = [summary stringByAppendingString:
      UiText(@"\n只有确认选择后才会切换形象。", @"\nYour appearance changes only after you confirm a choice.")];
  else summary=[summary stringByAppendingString:UiText(@"\n准备完成后会显示新形象；准备失败会保留原形象并提示。",@"\nThe new appearance will show when ready. If preparation fails, the previous one is kept and an error is shown.")];
  alert.informativeText = summary;
  NSMutableArray<NSString *> *details = [lines mutableCopy];
  if (failures.count) {
    [details addObject:UiText(@"未完成 / 损坏或校验失败：", @"Not completed / damaged or failed verification:")];
    [details addObjectsFromArray:failures];
    [details addObject:UiText(@"其他正常形象仍可使用；请重新选择原文件或从官网重新下载。",
                             @"Other valid packs remain usable. Select the original file or download it again.")];
  }
  if (details.count) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, 170)];
    scroll.hasVerticalScroller = YES;
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 380, 170)];
    text.editable = NO;
    text.font = [NSFont systemFontOfSize:13];
    text.string = [details componentsJoinedByString:@"\n"];
    text.textContainer.widthTracksTextView = YES;
    text.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = text;
    alert.accessoryView = scroll;
  }
  [alert addButtonWithTitle:UiText(@"完成", @"Done")];
  if (availableIds.count) [alert addButtonWithTitle:UiText(@"选择形象…", @"Choose Appearance…")];
  if ([alert runModal] == NSAlertSecondButtonReturn) [self showAppearancePicker:nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
  (void)notification;
  [self ensureCurrentDay];
  [self refreshOffworkAllowRollover:NO];
  [self checkPermission:nil];
}

- (void)discardRebuildableResources { [self.thumbnailGrid discardCache]; }

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  self.eventTapStopping = YES;
  ++self.resourceGeneration; self.pendingScenePack=nil;
  if(self.memoryPressure) dispatch_source_cancel(self.memoryPressure);self.memoryPressure=nil;
  [self stopAnimation];
  if (self.visibilityStatusItem) [NSStatusBar.systemStatusBar removeStatusItem:self.visibilityStatusItem];
  self.visibilityStatusItem = nil;
  [self stopPermissionPoll];
  [self removeEventTap];
  [self refreshOffworkAllowRollover:YES];
  [self flushOffwork:YES];
  [self.offworkTimer invalidate];
  self.offworkTimer = nil;
  [self.encouragerTimer invalidate];
  self.encouragerTimer = nil;
  [self saveState];
  [self flushCurve];
  if (_medalDirty) [self saveMedals];
  [self saveMetrics];
  [self.saveTimer invalidate]; self.saveTimer=nil;
  [self.dayTimer invalidate];
  [self.reminderTimer invalidate];
  self.reminderTimer = nil;
  [self.countStatusTimer invalidate];
  [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
}

- (void)startStrikeWithDuration:(NSTimeInterval)duration {
  if (self.eventTapStopping || _visibility.hidden() || self.displaySuspended || self.strikeActive) return;
  self.strikeActive = YES;
  self.strikeStartTime = CACurrentMediaTime();
  self.activeStrikeDuration = duration;
  [self.view requestAnimation:duration atTime:self.strikeStartTime];
  self.animationTimer = [NSTimer timerWithTimeInterval:duration target:self
      selector:@selector(animate:) userInfo:nil repeats:NO];
  [NSRunLoop.mainRunLoop addTimer:self.animationTimer forMode:NSRunLoopCommonModes];
  [NSRunLoop.mainRunLoop addTimer:self.animationTimer forMode:NSModalPanelRunLoopMode];
}

- (void)showPermissionIntroIfNeeded {
  if (gIsolatedAcceptance || [self hasLiveEventTap]) return;
  NMUiAlert *alert = NMPermissionIntroAlert(
      NSBundle.mainBundle.bundleURL.lastPathComponent.stringByDeletingPathExtension);
  const NSModalResponse response = [alert runModal];
  if (response == NSAlertFirstButtonReturn) [self requestListenPermission];
}

- (void)showFirstUseGuide:(id)sender {
  (void)sender;
  NSAlert *alert = [[NMUiAlert alloc] init];
  alert.messageText = UiText(@"先记住三件事", @"Three Things to Get Started");
  alert.informativeText = UiText(
      @"1. 按住小伙伴拖动，放到喜欢的位置。\n"
       @"2. 右键小伙伴，可以换形象、看日历和退出。\n"
       @"3. 在其他应用中计数需要允许“输入监控”；右键打开“关于”，可查看 Mac 权限帮助。\n\n"
       @"只记录操作次数，不读取输入内容。全屏隐身仅判断窗口是否覆盖屏幕，不保存应用或窗口信息；数据留在本机。",
      @"1. Drag your companion to move it.\n"
       @"2. Right-click it to change appearance, view the calendar, or quit.\n"
       @"3. Counting in other apps requires Input Monitoring permission. Open About for Mac permissions help.\n\n"
       @"Only operation counts are recorded; typed content is never read. Fullscreen hiding checks window coverage without saving app or window information. Data stays on this Mac.");
  [alert addButtonWithTitle:UiText(@"知道了", @"Got It")];
  [alert runModal];
}

- (BOOL)hasLiveEventTap {
  return self.eventTap && CFMachPortIsValid(self.eventTap) && CGEventTapIsEnabled(self.eventTap);
}

- (NSString *)countStatusTitle {
  if (![self hasLiveEventTap])
    return UiText(@"仅点击小伙伴计数", @"Pet-click Counting Only");
  if (self.listenerNeedsCheck)
    return UiText(@"待检查：监听与计数结果不一致", @"Check Needed: Counting Mismatch");
  if (!self.globalCountConfirmed)
    return UiText(@"待检查：监听已建立，尚未观察到计数", @"Check Pending: Listener Ready, No Count Observed");
  return UiText(@"全局监听已收到事件并计数", @"Global Events Received and Counted");
}

- (void)countPetClickIfNeeded {
  [self drainInput];
  if (![self hasLiveEventTap]) [self count];
}

- (void)prepareInputDelivery {
    self.inputMailbox=[[NMInputMailbox alloc] initWithTotal:self.total];
    self.inputNotification=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0,0,dispatch_get_main_queue());
    __weak MeritController *weakSelf=self;
    dispatch_source_set_event_handler(self.inputNotification, ^{ [weakSelf drainInput]; });
    dispatch_resume(self.inputNotification);
}
- (void)captureInputType:(CGEventType)type event:(CGEventRef)event {
  NMInputMailbox *mailbox=self.inputMailbox;
  if (!mailbox) return;
  if (type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) {
    [mailbox disabled:type];
  } else if (type==kCGEventKeyUp) {
    _reminderActivity.Observe(niuma::reminder::ActivitySampler::Event::KeyUp,ReminderContinuousTimeMs());
    return;
  } else {
    auto activityEvent=type==kCGEventKeyDown ? niuma::reminder::ActivitySampler::Event::KeyDown :
      type==kCGEventScrollWheel ? niuma::reminder::ActivitySampler::Event::ScrollPulse : niuma::reminder::ActivitySampler::Event::Click;
    _reminderActivity.Observe(activityEvent,ReminderContinuousTimeMs());
    double scrollTicks=0; std::uint32_t phase=0, momentum=0;
    if (type==kCGEventScrollWheel && event) {
      scrollTicks=niuma::macos::ScrollTickDistance(event);
      phase=(std::uint32_t)CGEventGetIntegerValueField(event,kCGScrollWheelEventScrollPhase);
      momentum=(std::uint32_t)CGEventGetIntegerValueField(event,kCGScrollWheelEventMomentumPhase);
    }
    [mailbox record:type wall:std::time(nullptr) uptime:NSProcessInfo.processInfo.systemUptime
        scrollTicks:scrollTicks phase:phase momentum:momentum];
  }
  dispatch_source_t notification=self.inputNotification;
  if(notification) dispatch_source_merge_data(notification,1);
}
- (void)drainInput {
  if(!self.inputMailbox) return;
  NSDictionary *snapshot=[self.inputMailbox take];
  NSDictionary *days=snapshot[@"days"]; long long added=0;
  for(NSString *key in days) {
    long long count=[days[key] longLongValue]; added+=count;
    long long old=[self.dailyTotals[key] longLongValue];
    self.dailyTotals[key]=@(count>LLONG_MAX-old ? LLONG_MAX : old+count);
  }
  [self mergeCurveDeltas:snapshot[@"curve"]];
  self.receivedEvents+=[snapshot[@"events"] unsignedIntegerValue];
  self.receivedKeys+=[snapshot[@"keys"] unsignedIntegerValue];
  self.receivedClicks+=[snapshot[@"clicks"] unsignedIntegerValue];
  self.receivedScrolls+=[snapshot[@"scrolls"] unsignedIntegerValue];
  self.selfCheckKeys+=[snapshot[@"checkKeys"] unsignedIntegerValue];
  self.selfCheckClicks+=[snapshot[@"checkClicks"] unsignedIntegerValue];
  self.selfCheckScrolls+=[snapshot[@"checkScrolls"] unsignedIntegerValue];
  NSUInteger checked=[snapshot[@"checkCounted"] unsignedIntegerValue];
  self.selfCheckExpected+=[snapshot[@"checkExpected"] unsignedIntegerValue];self.selfCheckCounted+=checked;
  if([snapshot[@"checkKeys"] unsignedIntegerValue]+[snapshot[@"checkClicks"] unsignedIntegerValue]+[snapshot[@"checkScrolls"] unsignedIntegerValue]) self.selfCheckLastEvent=[snapshot[@"checkLast"] doubleValue];
  if(added) {
    self.total=added>LLONG_MAX-self.total ? LLONG_MAX : self.total+added;
    self.currentDayKey=DateKeyForDate(NSDate.date);self.todayTotal=[self.dailyTotals[self.currentDayKey] longLongValue];
    self.dirty=YES;self.globalCountConfirmed=YES;
    self.smoothedInputInterval=[snapshot[@"interval"] doubleValue];self.lastInputTime=[snapshot[@"lastCount"] doubleValue];
    [self startStrikeWithDuration:std::clamp(self.smoothedInputInterval*1.05,kMinStrikeDuration,kMaxStrikeDuration)];
    if(!self.appearanceHidden) [self.view setNeedsDisplay:YES];
    if(self.calendarWindow.isVisible) [self.calendarView setNeedsDisplay:YES];
  }
  CGEventType disabled=(CGEventType)[snapshot[@"disabled"] unsignedIntValue];
  if(disabled) [self handleEventTapDisabled:disabled];
}

- (void)receiveGlobalEvent:(CGEventType)type event:(CGEventRef)event {
  const std::uint64_t reminderNowMs = ReminderContinuousTimeMs();
  if (type == kCGEventKeyDown)
    _reminderActivity.Observe(niuma::reminder::ActivitySampler::Event::KeyDown, reminderNowMs);
  else if (type == kCGEventScrollWheel)
    _reminderActivity.Observe(niuma::reminder::ActivitySampler::Event::ScrollPulse, reminderNowMs);
  else
    _reminderActivity.Observe(niuma::reminder::ActivitySampler::Event::Click, reminderNowMs);
  self.receivedEvents++;
  if (type == kCGEventKeyDown) self.receivedKeys++;
  else if (type == kCGEventScrollWheel) self.receivedScrolls++;
  else self.receivedClicks++;
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  BOOL observing = self.selfCheckActive && now >= self.selfCheckStarts && now < self.selfCheckEnds;
  if (observing) {
    if (type == kCGEventKeyDown) self.selfCheckKeys++;
    else if (type == kCGEventScrollWheel) self.selfCheckScrolls++;
    else self.selfCheckClicks++;
    self.selfCheckLastEvent = now - self.selfCheckStarts;
  }
  const long long before = self.total;
  self.selfCheckCountingEvent = observing;
  if (type == kCGEventScrollWheel) [self countScrollGesture:event];
  else [self count];
  self.selfCheckCountingEvent = NO;
  if (self.total > before) self.globalCountConfirmed = YES;
}

- (void)receiveReminderKeyUp {
  const std::uint64_t nowMs = ReminderContinuousTimeMs();
  _reminderActivity.Observe(niuma::reminder::ActivitySampler::Event::KeyUp, nowMs);
}

- (void)evaluateReminderActivity:(NSTimer *)timer {
  (void)timer;
  [self refreshAppearanceVisibility:nil];
  const std::uint64_t nowMs = ReminderContinuousTimeMs();
  const std::int64_t nowUtc = static_cast<std::int64_t>(NSDate.date.timeIntervalSince1970);
  const auto clockTransition = _reminderClockGuard.Observe(nowUtc, nowMs);
  if (clockTransition == niuma::reminder::WallClockGuard::Transition::Guarded) {
    if (_reminderStore) {
      NSString *dateText = DateKeyForDate(NSDate.date);
      if (_reminderStore->SetClockGuard(true, nowUtc, dateText.UTF8String) !=
          niuma::reminder::StoreResult::Success) _reminderStorageFault = true;
    }
    _reminderActivity.ResetForListenerRestart();
  } else if (clockTransition == niuma::reminder::WallClockGuard::Transition::Recovered) {
    const auto result = _reminderStore
        ? _reminderStore->SetClockGuard(false, nowUtc,
            DateKeyForDate(NSDate.date).UTF8String)
        : niuma::reminder::StoreResult::Success;
    if (result != niuma::reminder::StoreResult::Success) {
      _reminderStorageFault = true;
      _reminderClockGuard.RestoreGuard();
    } else {
      _reminderStorageFault = false;
    }
  }
  const BOOL listenerHealthy = [self hasLiveEventTap] && !_reminderClockGuard.guarded();
  const bool wasConsumed = _reminderActivity.segment_consumed();
  const auto trigger = _reminderActivity.Evaluate(nowMs, listenerHealthy);
  const bool isConsumed = _reminderActivity.segment_consumed();
  if (wasConsumed && !isConsumed) {
    const auto result = _reminderStore
        ? _reminderStore->SetSegmentConsumed(false, nowUtc)
        : niuma::reminder::StoreResult::IoError;
    if (result != niuma::reminder::StoreResult::Success) {
      _reminderStorageFault = true;
      _reminderActivity.RestoreSegmentConsumed(true);
    } else {
      _reminderStorageFault = false;
    }
  }
  if (trigger != niuma::reminder::ActivitySampler::Trigger::None)
    [self presentReminderForTrigger:trigger];
}

- (void)presentReminderForTrigger:(niuma::reminder::ActivitySampler::Trigger)trigger {
  if (_visibility.hidden() || !_reminderStore || self.reminderPanel ||
      (gIsolatedAcceptance && !gReminderPreviewAcceptance)) return;
  const std::int64_t nowUtc = static_cast<std::int64_t>(NSDate.date.timeIntervalSince1970);
  if (_reminderStore->SetSegmentConsumed(true, nowUtc) !=
      niuma::reminder::StoreResult::Success) {
    _reminderStorageFault = true;
    return;
  }

  NSDate *now = NSDate.date;
  NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
  calendar.timeZone = NSTimeZone.localTimeZone;
  NSDateComponents *components = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth |
      NSCalendarUnitDay | NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:now];
  niuma::reminder::SelectionContext context;
  context.locale = NMReminderLocale();
  NSString *country = NSLocale.currentLocale.countryCode.uppercaseString ?: @"";
  static NSSet<NSString *> *supportedRegions;
  static dispatch_once_t regionOnce;
  dispatch_once(&regionOnce, ^{ supportedRegions = [NSSet setWithArray:@[@"US", @"GB", @"CA", @"AU", @"NZ", @"IE"]]; });
  context.region = [supportedRegions containsObject:country] ? country.UTF8String : "*";
  context.trigger = trigger == niuma::reminder::ActivitySampler::Trigger::HighIntensity ? 2U : 1U;
  context.overtime = self.offworkEnabled && !self.offworkSuspended && self.offworkHasSnapshot
      ? (self.offworkIsOvertime ? niuma::reminder::Overtime::Yes : niuma::reminder::Overtime::No)
      : niuma::reminder::Overtime::Unknown;
  context.year = static_cast<int>(components.year);
  context.month = static_cast<int>(components.month);
  context.day = static_cast<int>(components.day);
  context.minute_of_day = static_cast<int>(components.hour * 60 + components.minute);
  NSString *dateText = DateKeyForDate(now);
  const char *dateUtf8 = dateText.UTF8String;
  const std::string localDate = dateUtf8 ? dateUtf8 : "";
  std::unordered_set<std::string> recentIds;
  bool warmUsedToday = false;
  if (!_reminderStore->ReadSelectionHistory(localDate.c_str(), nowUtc, &recentIds, &warmUsedToday)) {
    if (!_reminderClockGuard.guarded() &&
        !_reminderStore->ClockGuard(nowUtc, localDate.c_str()))
      _reminderStorageFault = true;
    return;
  }
  const niuma::reminder::CatalogView catalogView = _reminderCatalog
      ? _reminderCatalog->view() : niuma::reminder::kBuiltinCatalogView;
  const auto candidates = niuma::reminder::EligibleItems(context,
      [&recentIds](const char *id) { return recentIds.find(id) != recentIds.end(); },
      catalogView);
  const niuma::reminder::CatalogItem *item = niuma::reminder::SelectItem(candidates,
      warmUsedToday, [](std::size_t upper) {
        return static_cast<std::size_t>(arc4random_uniform(static_cast<uint32_t>(upper)));
      });
  if (item == nullptr) return;

  NSString *message = [NSString stringWithUTF8String:item->text];
  if (message.length == 0) return;
  NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
  if (!screen) return;
  // F1: the humor bubble scales with the rest of the desktop widget. The factor
  // is the user appearance multiplier (1.0 at the default 100%), so the default
  // bubble is unchanged while 60%..180% keeps the bubble in proportion.
  const CGFloat scale = self.appearanceScale;
  const CGFloat width = 260 * scale;
  NSFont *font = [NSFont systemFontOfSize:15 * scale weight:NSFontWeightMedium];
  NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
  paragraph.minimumLineHeight = 22 * scale; paragraph.maximumLineHeight = 22 * scale;
  NSDictionary *attributes = @{NSFontAttributeName: font,
      NSForegroundColorAttributeName:NMUiInk(), NSParagraphStyleAttributeName:paragraph};
  NSRect textBounds = [message boundingRectWithSize:NSMakeSize(width - 60 * scale, CGFLOAT_MAX)
      options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
      attributes:attributes];
  const CGFloat height = std::max(64.0 * scale, std::ceil(NSHeight(textBounds)) + 40.0 * scale);
  NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
      backing:NSBackingStoreBuffered defer:NO];
  if (!panel) return;
  panel.releasedWhenClosed = NO;
  panel.level = NSFloatingWindowLevel;
  panel.hidesOnDeactivate = NO;
  panel.becomesKeyOnlyIfNeeded = YES;
  panel.hasShadow = YES;
  panel.backgroundColor = NSColor.clearColor;
  panel.opaque = NO;
  panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient;
  NMUiBubbleView *content = [[NMUiBubbleView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
  panel.contentView = content;
  NSTextField *label = [NSTextField wrappingLabelWithString:message];
  label.attributedStringValue = [[NSAttributedString alloc] initWithString:message attributes:attributes];
  label.frame = NSMakeRect(20 * scale, 20 * scale, width - 60 * scale, height - 40 * scale);
  label.font = font;
  label.maximumNumberOfLines = 0;
  label.lineBreakMode = NSLineBreakByWordWrapping;
  [content addSubview:label];
  NSButton *close = [NSButton buttonWithTitle:@"×" target:self action:@selector(dismissReminder:)];
  close.frame = NSMakeRect(width - 36 * scale, height - 36 * scale, 24 * scale, 24 * scale);
  close.bordered = NO;
  close.font = [NSFont systemFontOfSize:16 * scale weight:NSFontWeightRegular];
  if (@available(macOS 10.14, *)) close.contentTintColor = NMUiMuted();
  close.accessibilityLabel = UiText(@"关闭提醒", @"Close reminder");
  [content addSubview:close];
  self.reminderPanel = panel;
  [self positionReminderPanel:panel];
  self.reminderDismissTimer = [NSTimer scheduledTimerWithTimeInterval:
      niuma::reminder::kReminderDisplayMilliseconds / 1000.0
      target:self selector:@selector(dismissReminder:) userInfo:nil repeats:NO];
  if (!self.reminderDismissTimer) {
    [panel orderOut:nil];
    self.reminderPanel = nil;
    return;
  }
  [NSRunLoop.mainRunLoop addTimer:self.reminderDismissTimer forMode:NSRunLoopCommonModes];
  const auto reserved = _reminderStore->TryReserve(item->id, localDate.c_str(),
      std::strcmp(item->tone, "warm") == 0, nowUtc);
  if (reserved != niuma::reminder::StoreResult::Success) {
    if (reserved == niuma::reminder::StoreResult::IoError ||
        reserved == niuma::reminder::StoreResult::InvalidState)
      _reminderStorageFault = true;
    [self.reminderDismissTimer invalidate];
    self.reminderDismissTimer = nil;
    [panel orderOut:nil];
    self.reminderPanel = nil;
    return;
  }
  _reminderStorageFault = false;
  self.reminderDismissTimer.fireDate = [NSDate dateWithTimeIntervalSinceNow:
      niuma::reminder::kReminderDisplayMilliseconds / 1000.0];
  [panel orderFrontRegardless];
}

- (void)positionReminderPanel:(NSPanel *)panel {
  if (!panel || !self.window) return;
  NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
  if (!screen) return;
  const CGFloat width = NSWidth(panel.frame);
  const CGFloat height = NSHeight(panel.frame);
  NSRect visible = screen.visibleFrame;
  NSRect mainFrame = self.window.frame;
  const auto placement = niuma::reminder::PlaceBubble(
      {NSMinX(mainFrame), NSMinY(mainFrame), NSWidth(mainFrame), NSHeight(mainFrame)},
      {NSMinX(visible), NSMinY(visible), NSWidth(visible), NSHeight(visible)},
      width, height, 10, niuma::reminder::VerticalAxis::Up);
  [panel setFrameOrigin:NSMakePoint(placement.x, placement.y)];
  if ([panel.contentView isKindOfClass:NMUiBubbleView.class]) {
    NMUiBubbleView *bubble = (NMUiBubbleView *)panel.contentView;
    bubble.companionPoint = NSMakePoint(NSMidX(mainFrame) - placement.x, NSMidY(mainFrame) - placement.y);
    bubble.needsDisplay = YES;
  }
}

- (void)reminderScreensDidChange:(NSNotification *)notification {
  (void)notification;
  [self positionReminderPanel:self.reminderPanel];
}

- (void)dismissReminder:(id)sender {
  (void)sender;
  [self.reminderDismissTimer invalidate];
  self.reminderDismissTimer = nil;
  [self.reminderPanel orderOut:nil];
  self.reminderPanel = nil;
}

- (void)showCountStatus:(id)sender {
  (void)sender;
  if (!self.countStatusWindow) {
    self.countStatusWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 580, 490)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.countStatusWindow.title = UiText(@"计数状态与自检", @"Counting Status & Check");
    self.countStatusWindow.releasedWhenClosed = NO;
    self.countStatusWindow.delegate = self;
    self.countStatusWindow.minSize = NSMakeSize(540, 440);
    NSView *content = self.countStatusWindow.contentView;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 62, 544, 410)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    self.countStatusText = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
    self.countStatusText.editable = NO;
    self.countStatusText.font = [NSFont systemFontOfSize:14];
    self.countStatusText.textContainerInset = NSMakeSize(6, 8);
    self.countStatusText.textContainer.widthTracksTextView = YES;
    self.countStatusText.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = self.countStatusText;
    [content addSubview:scroll];
    self.selfCheckButton = [NSButton buttonWithTitle:UiText(@"开始 10 秒自检", @"Start 10-second Check")
        target:self action:@selector(startSelfCheck:)];
    self.selfCheckButton.frame = NSMakeRect(18, 18, 174, 32);
    [content addSubview:self.selfCheckButton];
    NSButton *retry = [NSButton buttonWithTitle:UiText(@"检查权限 / 重试监听", @"Permissions / Retry Listener")
        target:self action:@selector(retryListener:)];
    retry.frame = NSMakeRect(202, 18, 226, 32);
    [content addSubview:retry];
    NSButton *close = [NSButton buttonWithTitle:UiText(@"关闭", @"Close")
        target:self action:@selector(closeCountStatus:)];
    close.frame = NSMakeRect(442, 18, 118, 32);
    close.autoresizingMask = NSViewMinXMargin;
    [content addSubview:close];
    NMUiWindow(self.countStatusWindow);
    [self.countStatusWindow center];
  }
  [self.countStatusWindow makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  if (!self.countStatusTimer) {
    self.countStatusTimer = [NSTimer timerWithTimeInterval:1 target:self
        selector:@selector(refreshCountStatus:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.countStatusTimer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:self.countStatusTimer forMode:NSModalPanelRunLoopMode];
  }
  [self refreshCountStatus:nil];
}

- (void)startSelfCheck:(id)sender {
  (void)sender;
  if (self.selfCheckActive) return;
  self.selfCheckKeys = self.selfCheckClicks = self.selfCheckScrolls = 0;
  self.selfCheckExpected = self.selfCheckCounted = 0;
  self.selfCheckLastEvent = 0;
  self.selfCheckInterrupted = NO;
  self.selfCheckResult = nil;
  // Exclude the button click and allow a short switch-to-another-app interval.
  self.selfCheckStarts = NSProcessInfo.processInfo.systemUptime + 2;
  self.selfCheckEnds = self.selfCheckStarts + 10;
  self.selfCheckActive = YES;
  [self refreshCountStatus:nil];
  [self.inputMailbox configureCheckFrom:self.selfCheckStarts until:self.selfCheckEnds enabled:self.selfCheckActive];
}

- (void)retryListener:(id)sender {
  (void)sender;
  if (self.selfCheckActive) {
    self.selfCheckActive = NO;
    self.selfCheckResult = UiText(@"已停止本次自检，重试监听后可重新开始。", @"Check stopped. Start again after retrying the listener.");
  }
  [self removeEventTap];
  self.listenerNeedsCheck = NO;
  [self requestListenPermission];
  [self refreshCountStatus:nil];
}

- (void)closeCountStatus:(id)sender {
  (void)sender;
  [self.countStatusWindow close];
}

- (void)windowWillClose:(NSNotification *)notification {
  // Closing the settings window discards its controls, never commits their values.
  if (notification.object == self.offworkSettingsWindow) return;
  if (notification.object == self.encouragerSettingsWindow) return;
  if (notification.object == self.appearanceScaleWindow) {
    // The slider already persisted each change; flush so the choice survives restart.
    [MeritPreferences() setObject:@(self.appearanceScale) forKey:kAppearanceScale];
    if (!gIsolatedAcceptance) [NSUserDefaults.standardUserDefaults synchronize];
    return;
  }
  if (notification.object != self.countStatusWindow) return;
  [self.countStatusTimer invalidate];
  self.countStatusTimer = nil;
  if (self.selfCheckActive) {
    self.selfCheckActive = NO;
    self.selfCheckResult = UiText(@"自检已取消，未作故障判断。", @"Check cancelled; no failure inferred.");
  }
}

- (void)refreshCountStatus:(NSTimer *)timer {
  (void)timer;
  if (!self.countStatusWindow) return;
  const NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (self.selfCheckActive && now >= self.selfCheckEnds) {
    self.selfCheckActive = NO;
    const NSUInteger events = self.selfCheckKeys + self.selfCheckClicks + self.selfCheckScrolls;
    if (!events) {
      self.globalCountConfirmed = NO;
      self.selfCheckResult = UiText(
          @"未观察到输入，不能判断失败。若你确实在其他应用操作过，请检查权限后重试；否则可直接重新自检。",
          @"No input observed; this is not a failure verdict. If you did use another app, check permissions and retry; otherwise repeat the check.");
    } else if (self.selfCheckInterrupted) {
      self.listenerNeedsCheck = YES;
      self.selfCheckResult = UiText(@"本次监听曾中断，请重试；不把部分记录当作通过。",
                                   @"The listener was interrupted. Repeat the check; partial observations do not count as a pass.");
    } else if (self.selfCheckExpected != self.selfCheckCounted) {
      self.listenerNeedsCheck = YES;
      self.selfCheckResult = UiText(@"收到事件，但计数未完全更新。请重试监听；总数已达上限时也不会继续增加。",
                                   @"Events arrived but counts did not fully update. Retry the listener; counts also stop at the numeric limit.");
    } else if (!self.selfCheckExpected) {
      self.selfCheckResult = UiText(@"只观察到不足一个滚动刻度的微小滚动；再多滚一点再试，不判失败。",
                                   @"Only sub-tick scrolling was observed. Scroll a bit more and retry; no failure inferred.");
    } else {
      self.listenerNeedsCheck = NO;
      self.selfCheckResult = UiText(
          @"本次观察到的输入已计数。未发生的输入类型未判断；请自行确认刚才已切换到其他应用。",
          @"Observed inputs were counted. Unused input types are not assessed; please confirm you switched to another app.");
    }
  }
  self.selfCheckButton.enabled = !self.selfCheckActive;
  NSString *progress = self.selfCheckResult ?: UiText(@"尚未开始自检。", @"No check started.");
  if (self.selfCheckActive) {
    progress = now < self.selfCheckStarts
        ? UiText(@"准备中：请切换到其他应用。2 秒后开始记录。", @"Get ready: switch to another app. Recording starts after 2 seconds.")
        : [NSString stringWithFormat:UiText(@"记录中，还剩 %.0f 秒。", @"Recording: %.0f seconds left."),
              ceil(MAX(0.0, self.selfCheckEnds - now))];
  }
  self.countStatusText.string = [NSString stringWithFormat:
      UiText(@"%@\n\n点击“开始”后切到其他应用，做几次按键、鼠标点击或滚动，10 秒后回来查看。计数自检不按应用区分，请自行确认已切换。\n\n%@\n\n本次收到：按键 %lu 次 / 鼠标按键 %lu 次 / 滚动事件 %lu 次\n按现有规则应增加 %lu，实际增加 %lu。滚动按距离折算：累计每满一个刻度加 1，惯性计入同一手势。\n最后事件：开始后 %.1f 秒（无事件时为 0）。\n\n监听句柄或权限开关本身不是成功证据。输入监控未授权、授权身份变化或安全输入都可能影响监听；不绕过系统限制。\n\n自检仅在内存中保留事件次数与相对时间；不记录具体键值、输入内容、坐标、应用或窗口信息。不联网。",
             @"%@\n\nStart, switch to another app and type, click or scroll. Return after 10 seconds. The app does not inspect which app you used; please confirm the switch yourself.\n\n%@\n\nReceived: %lu key events / %lu mouse clicks / %lu scroll events\nExpected count increase: %lu; actual: %lu. Scrolling counts by distance: one merit per accumulated tick; momentum stays in the same gesture.\nLast event: %.1f seconds after start (0 if none).\n\nA handle or permission switch alone is not proof. Missing or changed Input Monitoring permission and secure input may affect listening. No system restrictions are bypassed.\n\nOnly event counts and relative times are kept in memory, never key values, contents, coordinates, apps or windows. No networking."),
      self.countStatusTitle, progress, (unsigned long)self.selfCheckKeys,
      (unsigned long)self.selfCheckClicks, (unsigned long)self.selfCheckScrolls,
      (unsigned long)self.selfCheckExpected, (unsigned long)self.selfCheckCounted,
      self.selfCheckLastEvent];
}

- (void)requestListenPermission {
  if (gIsolatedAcceptance) return;
  BOOL granted = CGRequestListenEventAccess();
  if (granted) {
    [self installEventTap];
    return;
  }
  NSURL *url = [NSURL URLWithString:
      @"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"];
  [NSWorkspace.sharedWorkspace openURL:url];
  if (!self.inputMonitoringAuthorized) {
    if (!self.permissionPollTimer) {
      self.permissionPollTimer =
        [NSTimer scheduledTimerWithTimeInterval:kPermissionPollInterval
                                         target:self
                                       selector:@selector(checkPermission:)
                                       userInfo:nil
                                        repeats:YES];
    }
  }
}

- (void)checkPermission:(NSTimer *)timer {
  (void)timer;
  if ((gIsolatedAcceptance && !gAcceptancePhysicalInput) || self.eventTapStopping || self.eventTapOperationInProgress) return;
  self.eventTapOperationInProgress = YES;
  @try {
    if (self.eventTapRecoveryStopped) {
      [self removeEventTap];
      return;
    }
    if (self.eventTap && !self.eventTapDisabledPending &&
        CFMachPortIsValid(self.eventTap) && CGEventTapIsEnabled(self.eventTap)) {
      self.inputMonitoringAuthorized = YES;
      return;
    }
    // A disabled or invalid tap is retired, never synchronously re-armed.
    [self removeEventTap];
    if (self.eventTapRecoveryAttempts >= 3) {
      self.eventTapRecoveryStopped = YES;
      self.listenerNeedsCheck = YES;
      return;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < self.eventTapNextAttempt) return;
    if (!CGPreflightListenEventAccess()) {
      if (self.diagnostics && self.eventTapNextAttempt == 0) {
        fprintf(stderr, "tap_permission_preflight=denied tap_create_skipped=1\n");
      }
      // Waiting for permission does not create taps or consume a recovery attempt.
      self.eventTapNextAttempt = now + 2.0;
      return;
    }
    ++self.eventTapRecoveryAttempts;
    self.eventTapNextAttempt = now + (2.0 * (1U << (self.eventTapRecoveryAttempts - 1)));
    [self createEventTapOnce];
    if (!self.inputMonitoringAuthorized && self.eventTapRecoveryAttempts >= 3) {
      self.eventTapRecoveryStopped = YES;
      self.listenerNeedsCheck = YES;
    }
  } @finally {
    self.eventTapOperationInProgress = NO;
  }
}

- (void)stopPermissionPoll {
  if (!self.permissionPollTimer) return;
  [self.permissionPollTimer invalidate];
  self.permissionPollTimer = nil;
}

- (void)installEventTap {
  if ((gIsolatedAcceptance && !gAcceptancePhysicalInput) || self.eventTapStopping ||
      self.eventTapOperationInProgress || self.eventTap) return;
  // Only startup or an explicit retry resets this per-session recovery budget.
  self.eventTapRecoveryAttempts = 0;
  self.eventTapNextAttempt = 0;
  self.eventTapRecoveryStopped = NO;
  self.eventTapDisabledPending = NO;
  self.listenerNeedsCheck = NO;
  _reminderActivity.ResetForListenerRestart();
  [self checkPermission:nil];
}

- (void)createEventTapOnce {
  if ((gIsolatedAcceptance && !gAcceptancePhysicalInput) || self.eventTapStopping ||
      self.eventTapRecoveryStopped || !self.eventTapOperationInProgress || self.eventTap) return;
  self.globalCountConfirmed = NO;
  CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
                     CGEventMaskBit(kCGEventLeftMouseDown) |
                     CGEventMaskBit(kCGEventRightMouseDown) |
                     CGEventMaskBit(kCGEventOtherMouseDown) |
                     CGEventMaskBit(kCGEventScrollWheel);
  const CGEventTapLocation locations[] = {kCGHIDEventTap, kCGSessionEventTap};
  for (CGEventTapLocation location : locations) {
    if (self.eventTapStopping || self.eventTapRecoveryStopped) break;
    self.eventTap = CGEventTapCreate(location, kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly, mask, EventTapCallback, (__bridge void *)self);
    if (!self.eventTap) continue;
    self.eventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.eventTap, 0);
    if (!self.eventSource) {
      [self removeEventTap];
      continue;
    }
    [self prepareInputDelivery];
    self.inputThread=[[NMEventTapThread alloc] initWithSource:self.eventSource];
    // New taps are normally enabled. Do not fight a disabled result from the OS.
    if (self.eventTapStopping || self.eventTapRecoveryStopped || self.eventTapDisabledPending ||
        !CFMachPortIsValid(self.eventTap) || !CGEventTapIsEnabled(self.eventTap)) {
      [self removeEventTap];
      continue;
    }
    self.inputMonitoringAuthorized = YES;
    break;
  }
  if (self.diagnostics) {
    fprintf(stderr, "tap_attempt=%lu tap_attached=%d recovery_stopped=%d\n",
        (unsigned long)self.eventTapRecoveryAttempts, self.inputMonitoringAuthorized,
        self.eventTapRecoveryStopped);
    fflush(stderr);
  }
  [self.view setNeedsDisplay:YES];
}

- (void)removeEventTap {
  self.globalCountConfirmed = NO;
  if (self.selfCheckActive) self.selfCheckInterrupted = YES;
  // Clear ownership before invalidation, which may run invalidation callbacks.
  CFMachPortRef tap = self.eventTap;
  CFRunLoopSourceRef source = self.eventSource;
  self.eventTap = nullptr;
  self.eventSource = nullptr;
  self.inputMonitoringAuthorized = NO;
  self.eventTapDisabledPending = NO;
  // CFRelease alone does not tear down the WindowServer registration.
  if (tap) CFMachPortInvalidate(tap);
  [self.inputThread stop]; self.inputThread=nil;
  [self drainInput];
  if (self.inputNotification) dispatch_source_cancel(self.inputNotification);
  self.inputNotification=nil; self.inputMailbox=nil;
  if(source) CFRelease(source);
  if (tap) CFRelease(tap);
}

- (void)handleEventTapDisabled:(CGEventType)type {
  if ((gIsolatedAcceptance && !gAcceptancePhysicalInput) || self.eventTapStopping || !self.eventTap) return;
  self.globalCountConfirmed = NO;
  self.inputMonitoringAuthorized = NO;
  if (self.selfCheckActive) self.selfCheckInterrupted = YES;
  self.eventTapDisabledPending = YES;
  self.eventTapNextAttempt = MAX(self.eventTapNextAttempt,
      NSProcessInfo.processInfo.systemUptime + 2.0);
  if (type == kCGEventTapDisabledByUserInput) {
    self.eventTapRecoveryStopped = YES;
    self.listenerNeedsCheck = YES;
  }
  // No synchronous WindowServer calls or resource destruction inside the callback.
}

- (void)count {
  [self ensureCurrentDay];
  if (self.selfCheckCountingEvent) self.selfCheckExpected++;
  if (self.total == LLONG_MAX) return;
  self.total++;
  if (self.selfCheckCountingEvent) self.selfCheckCounted++;
  if (self.todayTotal < LLONG_MAX) self.todayTotal++;
  self.dailyTotals[self.currentDayKey] = @(self.todayTotal);
  self.dirty = YES;
  [self recordCurveIncrementAtWall:std::time(nullptr)];
  NSTimeInterval now = CACurrentMediaTime();
  if (self.lastInputTime > 0) {
    NSTimeInterval gap = now - self.lastInputTime;
    if (gap > kPauseForResetGap) {
      self.smoothedInputInterval = kDefaultStrikeDuration;
    } else {
      self.smoothedInputInterval =
          self.smoothedInputInterval * (1.0 - kEmaWeight) + gap * kEmaWeight;
    }
  } else {
    self.smoothedInputInterval = kDefaultStrikeDuration;
  }
  self.lastInputTime = now;
  NSTimeInterval desiredDuration = std::clamp(
      self.smoothedInputInterval * 1.05, kMinStrikeDuration, kMaxStrikeDuration);
  [self startStrikeWithDuration:desiredDuration];
  if (!_visibility.hidden()) [self.view setNeedsDisplay:YES];
  if (self.calendarWindow.isVisible) [self.calendarView setNeedsDisplay:YES];
}

- (void)countScrollGesture:(CGEventRef)event {
  // Fallback path: identical distance/gesture rules to the live input mailbox.
  const double now = NSProcessInfo.processInfo.systemUptime;
  const double distance = niuma::macos::ScrollTickDistance(event);
  const std::uint32_t phase = event
      ? (std::uint32_t)CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase) : 0;
  const std::uint32_t momentum = event
      ? (std::uint32_t)CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase) : 0;
  const int ticks = _scrollCounter.Consume(distance, phase, momentum, now);
  for (int i = 0; i < ticks; ++i) [self count];
}

- (void)animate:(NSTimer *)timer {
  (void)timer; self.strikeActive=NO;self.view.pendingAnimationDuration=0;
  [self.animationTimer invalidate]; self.animationTimer=nil;
  [self.view.renderer stop];
}
- (void)stopAnimation {
  [self.animationTimer invalidate]; self.animationTimer=nil;
  self.strikeActive=NO;self.view.pendingAnimationDuration=0; [self.view.renderer stop];
}

- (void)refreshAppearanceVisibility:(id)sender {
  (void)sender;
  BOOL fullscreen=NO;
  if(_visibility.autoHideFullscreen) {
    NSScreen *screen=self.window.screen ?: NSScreen.mainScreen;
    CGDirectDisplayID display=[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGRect target=CGDisplayBounds(display);
    CFArrayRef windowInfo=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID);
    std::vector<niuma::macos::FullscreenRect> visible;
    for(NSDictionary *info in (__bridge NSArray *)windowInfo) {
      if([info[(__bridge NSString *)kCGWindowLayer] intValue]!=0) continue;
      CGRect bounds{};if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds],&bounds)) continue;
      visible.push_back({bounds.origin.x,bounds.origin.y,bounds.size.width,bounds.size.height,
                         [info[(__bridge NSString *)kCGWindowOwnerPID] intValue]});
    }
    if(windowInfo) CFRelease(windowInfo);
    // NSScreen uses bottom-left coordinates; window-server bounds use top-left.
    // Convert usable-frame margins into the display's coordinate space.
    NSRect frame=screen.frame, usable=screen.visibleFrame;
    const double sx=frame.size.width>0 ? target.size.width/frame.size.width : 1;
    const double sy=frame.size.height>0 ? target.size.height/frame.size.height : 1;
    const double left=(NSMinX(usable)-NSMinX(frame))*sx;
    const double top=(NSMaxY(frame)-NSMaxY(usable))*sy;
    const double right=(NSMaxX(frame)-NSMaxX(usable))*sx;
    const double bottom=(NSMinY(usable)-NSMinY(frame))*sy;
    fullscreen=niuma::macos::FullscreenOnDisplay(
        {target.origin.x,target.origin.y,target.size.width,target.size.height,0},
        {target.origin.x+left,target.origin.y+top,target.size.width-left-right,target.size.height-top-bottom,0},
        visible,getpid());
  }
  if(!gIsolatedAcceptance || gAcceptancePhysicalInput) _visibility.fullscreen=fullscreen;
  if (!_visibility.fullscreen) _visibility.showDuringFullscreen = false;
  [self applyAppearanceVisibility];
}

- (void)applyAppearanceVisibility {
  BOOL hidden = _visibility.hidden() || self.displaySuspended;
  if (!self.window || hidden == self.appearanceHidden) return;
  self.appearanceHidden = hidden;
  [self stopAnimation]; self.strikeActive = NO;
  if (hidden) {
    [self.reminderDismissTimer invalidate]; self.reminderDismissTimer = nil;
    [self.reminderPanel orderOut:nil]; self.reminderPanel = nil;
    [self.window orderOut:nil];
  } else {
    [self refreshOffworkAllowRollover:YES];
    [self.view setNeedsDisplay:YES];
    [self.window orderFront:nil];  // Never take the typing focus.
  }
}

- (void)toggleAppearanceVisibility:(id)sender {
  (void)sender;
  if (!_visibility.recoveryAvailable) return;  // Keep a recovery path before hiding.
  BOOL hidden = !_visibility.hidden();
  _visibility.manualHidden = hidden;
  _visibility.showDuringFullscreen = !hidden && _visibility.fullscreen;
  [self refreshAppearanceVisibility:nil];
}

- (void)toggleAutoHideFullscreen:(id)sender {
  (void)sender;
  _visibility.autoHideFullscreen = !_visibility.autoHideFullscreen;
  _visibility.showDuringFullscreen = false;
  [MeritPreferences() setBool:_visibility.autoHideFullscreen forKey:@"AutoHideFullscreen"];
  [self refreshAppearanceVisibility:nil];
}

- (void)showStatusMenu:(id)sender {
  (void)sender;
  // A fresh menu always reflects manual, automatic and counting state.
  NSMenu *menu = [self contextMenu];
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0)
      inView:self.visibilityStatusItem.button];
}

- (NSMenu *)contextMenu {
  NSMenu *menu = [[NSMenu alloc] init];
  NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:UiText(@"关于牛马电子功德", @"About NiuMa Merit")
                                                action:@selector(showAbout:)
                                         keyEquivalent:@""];
  about.target = self;
  NSMenuItem *launchAtLogin = [[NSMenuItem alloc]
      initWithTitle:UiText(@"登录后自动启动", @"Start at Login")
             action:@selector(toggleLaunchAtLogin:)
      keyEquivalent:@""];
  launchAtLogin.target = self;
  launchAtLogin.enabled = !gIsolatedAcceptance;
  if ([self loginStartupState] == NMLoginStartupRequiresApproval) {
    launchAtLogin.title = UiText(@"登录后自动启动（待允许）…", @"Start at Login (Needs Approval)…");
  }
  if (self.loginStartupError) launchAtLogin.toolTip = UiText(
      @"上次设置未能完成，点击可重试。", @"The last change did not complete. Click to try again.");
  launchAtLogin.state = self.isLaunchAtLoginEnabled
      ? NSControlStateValueOn
      : NSControlStateValueOff;
  NSMenuItem *appearance = [[NSMenuItem alloc] initWithTitle:UiText(@"更换形象", @"Change Appearance")
                                                     action:@selector(showAppearancePicker:)
                                              keyEquivalent:@""];
  appearance.target = self;
  NSMenuItem *appearanceSize = [[NSMenuItem alloc]
      initWithTitle:UiText(@"形象大小…", @"Appearance Size…")
             action:@selector(showAppearanceScaleSettings:)
      keyEquivalent:@""];
  appearanceSize.target = self;
  NSMenuItem *calendar = [[NSMenuItem alloc]
      initWithTitle:UiText(@"功德日历…", @"Merit Calendar…")
             action:@selector(showMeritCalendar:)
      keyEquivalent:@""];
  calendar.target = self;
  NSMenuItem *curveItem = [[NSMenuItem alloc]
      initWithTitle:UiText(@"牛马曲线…", @"Merit Curve…")
             action:@selector(showMeritCurve:)
      keyEquivalent:@""];
  curveItem.target = self;
  NSMenuItem *offwork = [[NSMenuItem alloc]
      initWithTitle:UiText(@"下班倒计时…", @"Off-work Countdown…")
             action:@selector(showOffworkSettings:) keyEquivalent:@""];
  offwork.target = self;
  offwork.state = self.offworkEnabled ? NSControlStateValueOn : NSControlStateValueOff;
  NSMenuItem *encourager = [[NSMenuItem alloc]
      initWithTitle:UiText(@"上班鼓励器…", @"Work Encourager…")
             action:@selector(showEncouragerSettings:) keyEquivalent:@""];
  encourager.target = self;
  encourager.state = self.encouragerActive ? NSControlStateValueOn : NSControlStateValueOff;
  NSMenuItem *medals = [[NSMenuItem alloc]
      initWithTitle:UiText(@"勋章与成就…", @"Medals & Achievements…")
             action:@selector(showMedals:) keyEquivalent:@""];
  medals.target = self;
  NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:UiText(@"退出", @"Quit")
                                                action:@selector(terminate:)
                                         keyEquivalent:@""];
  quit.target = NSApp;

  // The compact pet window is only 120 points wide. Keep the native menu
  // independent from that canvas size and leave room for checkmarks/padding.
  // Every command is a normal native row; separator rows would add uneven gaps.
  NSMenuItem *visibility = [[NSMenuItem alloc] initWithTitle:_visibility.hidden() ?
      UiText(@"显示形象（继续计数）", @"Show Appearance (Counting Continues)") :
      UiText(@"隐藏形象（继续计数）", @"Hide Appearance (Counting Continues)")
      action:@selector(toggleAppearanceVisibility:) keyEquivalent:@""];
  visibility.target = self;
  visibility.enabled = _visibility.recoveryAvailable;
  NSMenuItem *autoHide = [[NSMenuItem alloc] initWithTitle:UiText(@"全屏或最大化时自动隐身", @"Auto-hide when Fullscreen or Maximized")
      action:@selector(toggleAutoHideFullscreen:) keyEquivalent:@""];
  autoHide.target = self;
  autoHide.state = _visibility.autoHideFullscreen ? NSControlStateValueOn : NSControlStateValueOff;
  NSArray<NSMenuItem *> *entries = @[visibility, autoHide, appearance, appearanceSize, calendar, curveItem, offwork, encourager, medals, launchAtLogin, about, quit];
  for (NSMenuItem *item in entries) [menu addItem:item];
  NSFont *menuFont = [NSFont systemFontOfSize:14];
  menu.font = menuFont;
  if (@available(macOS 11.0, *)) {
    NSArray *symbols = @[@"eye.slash", @"arrow.up.left.and.arrow.down.right", @"person.crop.square", @"textformat.size", @"calendar", @"chart.bar", @"clock", @"yensign.circle", @"rosette", @"power", @"info.circle", @"rectangle.portrait.and.arrow.right"];
    for (NSUInteger index = 0; index < entries.count; ++index) {
      NSImage *image = [NSImage imageWithSystemSymbolName:symbols[index] accessibilityDescription:nil];
      image.size = NSMakeSize(16, 16); ((NSMenuItem *)entries[index]).image = image;
    }
  }
  CGFloat widestTitle = 0;
  for (NSMenuItem *item in menu.itemArray) {
    if (item.isSeparatorItem) continue;
    widestTitle = MAX(widestTitle, [item.title sizeWithAttributes:@{
      NSFontAttributeName: menuFont
    }].width);
  }
  menu.minimumWidth = MAX(240.0, widestTitle + 64.0);
  return menu;
}

- (void)showContextMenu:(NSEvent *)event {
  [NSMenu popUpContextMenu:[self contextMenu] withEvent:event forView:self.view];
}

- (BOOL)importOfficialMessagesAtPath:(NSString *)filename {
  if (!_catalogStore) {
    NSAlert *alert = [[NMUiAlert alloc] init];
    alert.messageText = UiText(@"无法导入文案包", @"Could Not Import Messages");
    alert.informativeText = UiText(@"本地文案库暂不可用，请退出应用后重试。",
        @"The local message catalog is unavailable. Quit the app and try again.");
    [alert addButtonWithTitle:UiText(@"好", @"OK")];
    [alert runModal];
    return NO;
  }
  auto result = _catalogStore->InstallFile(
      std::filesystem::path(filename.fileSystemRepresentation),
      niuma::reminder::OfficialCatalogSignatureVerifier());
  if (result.status == niuma::reminder::CatalogInstallStatus::Installed ||
      result.status == niuma::reminder::CatalogInstallStatus::AlreadyInstalled) {
    _reminderCatalog = result.catalog;
    std::size_t chinese = 0, english = 0;
    for (const auto& item : _reminderCatalog->items) {
      if (std::strcmp(item.language, "zh-CN") == 0) ++chinese;
      else if (std::strcmp(item.language, "en") == 0) ++english;
    }
    NSString *message = [NSString stringWithFormat:
        UiText(@"文案库版本 %u 已就绪（中文 %lu 条，英文 %lu 条）。提醒历史保持不变。",
               @"Message catalog version %u is ready (%lu Chinese, %lu English). Reminder history is unchanged."),
        _reminderCatalog->content_version, static_cast<unsigned long>(chinese),
        static_cast<unsigned long>(english)];
    NSAlert *alert = [[NMUiAlert alloc] init];
    alert.messageText = UiText(@"文案包已导入", @"Messages Imported");
    alert.informativeText = message;
    [alert addButtonWithTitle:UiText(@"好", @"OK")];
    [alert runModal];
    return YES;
  }
  NSString *message = UiText(@"文件未安装，当前文案库和提醒历史保持不变。请确认文件来自官方并且版本较新。",
                             @"The file was not installed. Your current catalog and reminder history are unchanged. Check that it is an official, newer catalog.");
  if (result.status == niuma::reminder::CatalogInstallStatus::CommitUncertain)
    message = UiText(@"文案库文件已完成本地替换，但系统未确认目录写入已持久保存。当前进程仍使用原文案库；重启后会按本地签名验证结果加载。请勿把本次提示视为已完成导入。提醒历史保持不变。",
                     @"The catalog files were replaced locally, but the system could not confirm durable directory storage. This process keeps using the previous catalog; after restart, the app will load whichever local catalog passes signature verification. Treat the import as unconfirmed. Reminder history is unchanged.");
  else if (result.status == niuma::reminder::CatalogInstallStatus::UntrustedSignature)
    message = UiText(@"签名无效或发布密钥不受信任，当前文案库保持不变。",
                     @"The signature is invalid or its publisher key is not trusted. Your current catalog is unchanged.");
  else if (result.status == niuma::reminder::CatalogInstallStatus::Downgrade)
    message = UiText(@"此文案库版本较旧，不能覆盖已安装的新版本。",
                     @"This catalog is older than the highest installed version and cannot replace it.");
  else if (result.status == niuma::reminder::CatalogInstallStatus::SameVersionDifferentContent)
    message = UiText(@"相同版本号对应了不同内容，文件未安装。",
                     @"This version number is already associated with different content. The file was not installed.");
  NSAlert *alert = [[NMUiAlert alloc] init];
  alert.messageText = UiText(@"无法导入文案包", @"Could Not Import Messages");
  alert.informativeText = message;
  [alert addButtonWithTitle:UiText(@"好", @"OK")];
  [alert runModal];
  return NO;
}

- (void)toggleLaunchAtLogin:(id)sender {
  (void)sender;
  if ([self loginStartupState] == NMLoginStartupRequiresApproval) {
    [self showLoginStartupApproval];
    return;
  }
  [self setLaunchAtLoginEnabled:!self.isLaunchAtLoginEnabled showError:YES];
}

- (void)showMeritCalendar:(id)sender {
  (void)sender;
  [self ensureCurrentDay];
  if (!self.calendarWindow) {
    NSRect frame = NSMakeRect(0, 0, 720, 724);
    self.calendarView = [[MeritCalendarView alloc] initWithFrame:frame];
    self.calendarView.controller = self;
    [self.calendarView showCurrentMonth];
    NSButton *previous = [[NSButton alloc] initWithFrame:NSMakeRect(24, 20, 30, 28)];
    previous.title = @"<"; previous.tag = -1; previous.target = self;
    previous.action = @selector(shiftCalendarMonth:);
    NSButton *next = [[NSButton alloc] initWithFrame:NSMakeRect(275, 20, 30, 28)];
    next.title = @">"; next.tag = 1; next.target = self;
    next.action = @selector(shiftCalendarMonth:);
    previous.accessibilityLabel = UiText(@"上个月", @"Previous month");
    next.accessibilityLabel = UiText(@"下个月", @"Next month");
    self.calendarView.previousButton = previous;
    self.calendarView.nextButton = next;
    NSButton *today=[NSButton buttonWithTitle:UiText(@"回到今天",@"Today") target:self.calendarView action:@selector(goToday:)];
    today.frame=NSMakeRect(325,20,100,28); [self.calendarView addSubview:today];
    [self.calendarView addSubview:previous];
    [self.calendarView addSubview:next];
    self.calendarWindow = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
          backing:NSBackingStoreBuffered defer:NO];
    self.calendarWindow.title = UiText(@"功德日历", @"Merit Calendar");
    self.calendarWindow.contentView = self.calendarView;
    self.calendarWindow.releasedWhenClosed = NO;
    if (gIsolatedAcceptance) self.calendarWindow.restorable = NO;
    NMUiWindow(self.calendarWindow);
    self.calendarWindow.backgroundColor=NSColor.whiteColor;
    [self.calendarWindow center];
  }
  [self.calendarView reloadMonthRange];
  [self.calendarView refreshNavigation];
  if (self.calendarWindow.isVisible) [self.calendarView setNeedsDisplay:YES];
  [NSApp activateIgnoringOtherApps:YES];
  [self.calendarWindow makeKeyAndOrderFront:nil];
}

- (void)shiftCalendarMonth:(NSButton *)sender {
  [self.calendarView shiftMonth:sender.tag];
}

// ---- F4 牛马曲线窗口 ----
- (void)showMeritCurve:(id)sender {
  (void)sender;
  [self ensureCurrentDay];
  if (!self.curveWindow) {
    NSRect frame = NSMakeRect(0, 0, 760, 470);
    NSView *container = [[NSView alloc] initWithFrame:frame];
    self.curveView = [[NMCurveView alloc] initWithFrame:NSMakeRect(0, 0, 760, 430)];
    self.curveView.controller = self;
    self.curveView.mode = 0;
    self.curveView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:self.curveView];
    NSSegmentedControl *segments = [NSSegmentedControl
        segmentedControlWithLabels:@[ UiText(@"日", @"Day"), UiText(@"周", @"Week"),
                                      UiText(@"月", @"Month") ]
                     trackingMode:NSSegmentSwitchTrackingSelectOne
                           target:self
                           action:@selector(curveModeChanged:)];
    segments.frame = NSMakeRect(24, 436, 260, 28);
    segments.selectedSegment = 0;
    segments.accessibilityLabel = UiText(@"曲线视图", @"Curve view");
    self.curveModeControl = segments;
    [container addSubview:segments];
    NSButton *exportButton = [NSButton buttonWithTitle:UiText(@"导出分享图…", @"Export Share Image…")
        target:self action:@selector(exportCurveShareCard:)];
    exportButton.frame = NSMakeRect(552, 436, 184, 30);
    exportButton.autoresizingMask = NSViewMinXMargin;
    [container addSubview:exportButton];
    self.curveWindow = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.curveWindow.title = UiText(@"牛马曲线", @"Merit Curve");
    self.curveWindow.contentView = container;
    self.curveWindow.releasedWhenClosed = NO;
    self.curveWindow.minSize = NSMakeSize(560, 360);
    if (gIsolatedAcceptance) self.curveWindow.restorable = NO;
    NMUiWindow(self.curveWindow);
    [self.curveWindow center];
  }
  [self.curveView refreshToToday];
  [NSApp activateIgnoringOtherApps:YES];
  [self.curveWindow makeKeyAndOrderFront:nil];
}

- (void)curveModeChanged:(id)sender {
  (void)sender;
  self.curveView.mode = self.curveModeControl.selectedSegment;
  [self.curveView refreshToToday];
}

- (void)exportCurveShareCard:(id)sender {
  (void)sender;
  [self ensureCurrentDay];
  NSDateComponents *comp = [RecordCalendar() components:
      NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:NSDate.date];
  const int year = (int)comp.year, month = (int)comp.month, day = (int)comp.day;
  NSString *todayKey = DateKeyForDate(NSDate.date);
  NSNumberFormatter *fmt = [NSNumberFormatter new];
  fmt.numberStyle = NSNumberFormatterDecimalStyle;
  NSMutableArray<NSNumber *> *points = [NSMutableArray array];
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  unsigned long long total = 0;
  NSString *subtitle = nil;
  NSString *rangeLabel = nil;
  NSString *viewName = nil;
  if (self.curveModeControl.selectedSegment == 0) {
    NSDictionary *snapshot = [self curveDayForDisplay:todayKey];
    NSArray *buckets = snapshot[@"buckets"];
    niuma::curve::Coverage coverage;
    const bool haveCoverage = snapshot && niuma::curve::Coverage::FromHex(
        std::string([snapshot[@"coverage"] UTF8String] ?: ""), &coverage);
    for (int i = 0; i < 96; ++i) {
      unsigned long long v = (buckets && (NSUInteger)i < buckets.count)
          ? [buckets[(NSUInteger)i] unsignedLongLongValue] : 0;
      if (haveCoverage && !coverage.Get(i)) v = 0;
      [points addObject:@(v)];
    }
    for (int hour = 0; hour <= 24; hour += 6)
      [labels addObject:[NSString stringWithFormat:@"%02d", hour]];
    // 让 labels 与 points 等长以便渲染器按索引对齐：用空串占位。
    NSMutableArray<NSString *> *full = [NSMutableArray array];
    for (int i = 0; i < 96; ++i) [full addObject:@""];
    for (int hour = 0; hour <= 24; hour += 6) full[(NSUInteger)(hour * 4)] = [NSString stringWithFormat:@"%02d", hour];
    labels = full;
    total = [self.dailyTotals[todayKey] unsignedLongLongValue];
    subtitle = [NSString stringWithFormat:UiText(@"%@ · 今日 96 桶", @"%@ · Today, 96 buckets"), todayKey];
    rangeLabel = todayKey;
    viewName = @"day";
  } else if (self.curveModeControl.selectedSegment == 1) {
    std::vector<std::string> keys = niuma::curve::WeekDayKeys(year, month, day);
    NSArray *weekdays = NMWeekdayLabels();
    for (int i = 0; i < 7; ++i) {
      NSString *k = [NSString stringWithUTF8String:keys[(std::size_t)i].c_str()];
      unsigned long long v = [self.dailyTotals[k] unsignedLongLongValue];
      [points addObject:@(v)];
      [labels addObject:weekdays[i]];
      total = (v > ULLONG_MAX - total) ? ULLONG_MAX : total + v;
    }
    subtitle = UiText(@"本周每日功德（周一–周日）", @"Daily merit this week (Mon–Sun)");
    rangeLabel = [NSString stringWithUTF8String:keys.front().c_str()];
    viewName = @"week";
  } else {
    std::vector<std::string> keys = niuma::curve::MonthDayKeys(year, month);
    for (std::size_t i = 0; i < keys.size(); ++i) {
      NSString *k = [NSString stringWithUTF8String:keys[i].c_str()];
      unsigned long long v = [self.dailyTotals[k] unsignedLongLongValue];
      [points addObject:@(v)];
      [labels addObject:[NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)]];
      total = (v > ULLONG_MAX - total) ? ULLONG_MAX : total + v;
    }
    subtitle = [NSString stringWithFormat:UiText(@"%ld 年 %ld 月每日功德", @"Daily merit %ld / %ld"),
        (long)year, (long)month];
    rangeLabel = [NSString stringWithFormat:@"%04d-%02d", year, month];
    viewName = @"month";
  }

  NMShareCardModel *model = [NMShareCardModel new];
  model.kind = NMShareCardKindCurve;
  model.locale = CurrentUiLanguageTag();
  model.appVersion = kNiuMa096AppVersion;
  model.generatedOn = todayKey;
  model.title = UiText(@"牛马电子功德", @"NiuMa Merit");
  model.subtitle = subtitle;
  model.meritPeriod = viewName;
  model.meritValue = total;
  model.curveView = viewName;
  model.curveRangeLabel = rangeLabel;
  model.curveYUnit = UiText(@"功德", @"merit");
  model.curvePoints = points;
  model.curveLabels = labels;
  model.footerProduct = UiText(@"牛马电子功德", @"NiuMa Merit");
  model.footerWatermark = @"niuma-merit 0.9.6";
  if (self.encouragerActive) {
    model.moneyDisplay = self.encouragerDisplayAmount;
    model.moneyCurrency = self.encouragerCurrency;
    model.moneyExponent = niuma::encourager::ExponentForCode(
        std::string(self.encouragerCurrency.UTF8String ?: "CNY"));
    model.moneyAmountMinor = 0;
  }
  NSData *png = NMRenderShareCardPNG(model, 1000, 1250);
  if (!png || !NMSaveShareCardPNG(png, self.curveWindow, @"niuma-merit-curve.png")) {
    if (!png) {
      NSAlert *alert = [[NMUiAlert alloc] init];
      alert.messageText = UiText(@"导出失败", @"Export Failed");
      alert.informativeText = UiText(@"未能生成分享图，请稍后重试。",
          @"Could not generate the share image. Please try again.");
      [alert addButtonWithTitle:UiText(@"好", @"OK")];
      [alert runModal];
    }
  }
  (void)fmt;
}

- (void)selectAppearance:(NSButton *)sender {
  if (sender.tag < 0 || sender.tag >= (NSInteger)self.appearanceItems.count) return;
  self.pendingAppearanceId = self.appearanceItems[(NSUInteger)sender.tag][@"id"];
  for (NSButton *button in self.appearanceButtons) {
    button.state = button.tag == sender.tag ? NSControlStateValueOn : NSControlStateValueOff;
  }
}

- (void)reloadAppearancePacks {
  ++self.resourceGeneration; self.pendingScenePack=nil;
  NSError *error = nil;
  self.installedAppearancePacks = [NMAppearancePackStore loadInstalledMetadata:&error];
  self.appearanceLoadError = error;
  if (error && self.window) {
    NSAlert *alert = [[NMUiAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = UiText(@"本地形象加载失败", @"Unable to Load Local Packs");
    alert.informativeText = error.localizedDescription;
    [alert runModal];
  }
}

- (NMAppearancePack *)appearancePackWithId:(NSString *)identifier {
  for (NMAppearancePack *pack in self.installedAppearancePacks) {
    if ([pack.identifier isEqualToString:identifier]) return pack;
  }
  return nil;
}

- (void)applyAppearanceId:(NSString *)identifier {
  ++self.resourceGeneration;
  self.pendingScenePack=[self appearancePackWithId:identifier];
  if (self.pendingScenePack) { [self pumpSceneLoad]; return; }
  [self stopAnimation];
  if (!NMIsKnownBuiltinId(identifier)) identifier = kBuiltinWoodfishId;
  self.selectedScene=NMSceneForBuiltinId(identifier);
  self.view.scene=self.selectedScene;
  self.view.appearancePack=nil; self.selectedAppearanceId=identifier;
  [MeritPreferences() setInteger:self.selectedScene forKey:kSelectedScene];
  [MeritPreferences() setObject:self.selectedAppearanceId forKey:kSelectedAppearance];
  [self.view syncPresentation];
}
- (void)pumpSceneLoad {
  if (self.resourceLoadBusy || !self.pendingScenePack || self.eventTapStopping) return;
  NMAppearancePack *metadata=self.pendingScenePack; self.pendingScenePack=nil;
  NSUInteger generation=self.resourceGeneration; self.resourceLoadBusy=YES;
  __weak MeritController *weakSelf=self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{ @autoreleasepool {
    NSError *failure=nil;
    NMAppearancePack *resources=[NMAppearancePackStore loadResourcesForPack:metadata error:&failure];
    dispatch_async(dispatch_get_main_queue(), ^{
      MeritController *controller=weakSelf; if (!controller) return;
      controller.resourceLoadBusy=NO;
      if (generation==controller.resourceGeneration && !controller.eventTapStopping) {
        if (resources) {
          [controller stopAnimation]; controller.view.appearancePack=resources;
          controller.selectedAppearanceId=resources.identifier; controller.appearanceLoadError=nil;
          [MeritPreferences() setObject:resources.identifier forKey:kSelectedAppearance];
          [controller.view syncPresentation];
          [controller startStrikeWithDuration:.8];
        } else {
          controller.appearanceLoadError=failure;
          if (!gIsolatedAcceptance) {
            NSAlert *alert=[NMUiAlert new]; alert.messageText=UiText(@"形象未能切换",@"Appearance Not Changed");
            alert.informativeText=failure.localizedDescription ?: UiText(@"原形象与数据已保留。",@"The previous appearance and data were kept.");
            [alert runModal];
          }
        }
      }
      [controller pumpSceneLoad];
    });
  }});
}

- (NSView *)appearanceGrid {
  NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
  [items addObject:@{@"id": @"builtin.woodfish",
                     @"title": UiText(@"默认木鱼", @"Woodfish"),
                     @"scene": @(MeritSceneWoodfish)}];
  [items addObject:@{@"id": kBuiltinEncouragerId,
                     @"title": UiText(@"上班鼓励器", @"Work Encourager"),
                     @"scene": @(MeritSceneEncourager)}];
  for (NMAppearancePack *pack in self.installedAppearancePacks) {
    [items addObject:@{@"id": pack.identifier, @"title": [pack localizedName], @"pack": pack}];
  }
  self.appearanceItems = items;
  NSInteger rows = (items.count + 1) / 2;
  CGFloat gridHeight = rows * 162 - 8;
  NMThumbnailGrid *grid = [[NMThumbnailGrid alloc] initWithFrame:NSMakeRect(0, 0, 324, gridHeight)];
  NSMutableArray *buttons = [NSMutableArray array];
  for (NSInteger i = 0; i < (NSInteger)items.count; ++i) {
    NSDictionary *item = items[(NSUInteger)i];
    NSImage *thumbnail = nil;
    NMAppearancePack *pack = item[@"pack"];
    if (pack) {
      thumbnail = nil; // Prepared on demand by the visible-card worker.
    } else {
      MeritView *preview = [[MeritView alloc] initWithFrame:NSMakeRect(0, 0, 120, 125)];
      preview.previewOnly = YES;
      preview.scene = (MeritScene)[item[@"scene"] integerValue];
      [preview syncPresentation];
      NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:240 pixelsHigh:250
          bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
          bitmapFormat:0 bytesPerRow:960 bitsPerPixel:32];
      NSGraphicsContext *context=[NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
      [NSGraphicsContext saveGraphicsState]; NSGraphicsContext.currentContext=context;
      CGContextScaleCTM(context.CGContext,2,2); [preview.layer renderInContext:context.CGContext];
      [NSGraphicsContext restoreGraphicsState];
      thumbnail = [[NSImage alloc] initWithSize:preview.bounds.size];
      [thumbnail addRepresentation:rep];
    }
    NSInteger row = i / 2;
    NSButton *button = [[NMUiCardButton alloc] initWithFrame:NSMakeRect((i % 2) * 168,
        gridHeight - (row + 1) * 154 - row * 8, 156, 154)];
    NSMutableArray<NSString *> *badges = [NSMutableArray array];
    if ([item[@"id"] isEqualToString:self.selectedAppearanceId])
      [badges addObject:UiText(@"当前", @"Current")];
    if ([self.newlyImportedIds containsObject:item[@"id"]])
      [badges addObject:UiText(@"本次新增", @"New")];
    else if ([self.lastImportedIds containsObject:item[@"id"]])
      [badges addObject:UiText(@"本次导入", @"Imported")];
    button.title = badges.count
        ? [NSString stringWithFormat:@"%@\n%@", item[@"title"], [badges componentsJoinedByString:@" · "]]
        : item[@"title"];
    button.toolTip = button.title;
    button.accessibilityLabel = button.title;
    button.image = thumbnail;
    if (!pack && thumbnail) { NSMutableDictionary *withThumbnail=[item mutableCopy]; withThumbnail[@"thumbnail"]=thumbnail; items[(NSUInteger)i]=withThumbnail; }
    button.imagePosition = NSImageAbove;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.bezelStyle = NSBezelStyleRegularSquare;
    [button setButtonType:NSButtonTypePushOnPushOff];
    button.tag = i;
    button.target = self;
    button.action = @selector(selectAppearance:);
    button.state = [item[@"id"] isEqualToString:self.pendingAppearanceId]
        ? NSControlStateValueOn : NSControlStateValueOff;
    [grid addSubview:button];
    [buttons addObject:button];
  }
  self.appearanceButtons = buttons;
  grid.items=items; grid.buttons=buttons; self.thumbnailGrid=grid;
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 324, MIN(478, gridHeight))];
  scroll.documentView = grid;
  scroll.hasVerticalScroller = gridHeight > NSHeight(scroll.bounds);
  scroll.drawsBackground = NO;
  for (NSButton *button in buttons) {
    NSString *identifier = items[(NSUInteger)button.tag][@"id"];
    if ([self.lastImportedIds containsObject:identifier]) {
      [grid scrollRectToVisible:button.frame];
      break;
    }
  }
  return scroll;
}

- (void)showAppearancePicker:(id)sender {
  (void)sender;
  [self reloadAppearancePacks];
  if (self.appearancePickerAlert) {
    self.pendingAppearanceId = self.selectedAppearanceId;
    self.appearancePickerAlert.accessoryView = [self appearanceGrid];
    [self.appearancePickerAlert layout];
    [self.appearancePickerAlert.window makeKeyAndOrderFront:nil];
    return;
  }
  self.pendingAppearanceId = self.selectedAppearanceId;
  while (YES) {
    NSAlert *alert = [[NMUiCenteredAccessoryAlert alloc] init];
    alert.messageText = UiText(@"更换形象", @"Change Appearance");
    alert.informativeText = @"";
    alert.accessoryView = [self appearanceGrid];
    [alert addButtonWithTitle:UiText(@"确认", @"Confirm")];
    [alert addButtonWithTitle:UiText(@"取消", @"Cancel")];
    [alert addButtonWithTitle:UiText(@"删除所选本地形象", @"Remove Selected Pack")];
    [alert addButtonWithTitle:UiText(@"去官网查看更多形象", @"See More Appearances Online")];
    self.appearancePickerAlert = alert;
    NSModalResponse response = [alert runModal];
    self.appearancePickerAlert = nil;
    self.appearanceButtons=nil; self.appearanceItems=nil;
    if (response == NSAlertFirstButtonReturn) {
      [self applyAppearanceId:self.pendingAppearanceId];
      if([self.pendingAppearanceId isEqual:@"builtin.woodfish"]) [self startStrikeWithDuration:.8];
      return;
    }
    if (response == NSAlertSecondButtonReturn) return;
    if (response == NSAlertThirdButtonReturn + 1) {
      [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://gongde.zqscreen.cn/#characters"]];
      continue;
    }
    NMAppearancePack *pack = [self appearancePackWithId:self.pendingAppearanceId];
    if (!pack) {
      NSBeep();
      continue;
    }
    NSError *error = nil;
    if (![NMAppearancePackStore removePack:pack error:&error]) {
      NSAlert *failure = [[NMUiAlert alloc] init];
      failure.messageText = UiText(@"无法删除形象包", @"Unable to Remove Appearance Pack");
      failure.informativeText = error.localizedDescription ?: @"";
      [failure runModal];
      continue;
    }
    if ([self.selectedAppearanceId isEqualToString:pack.identifier]) {
      [self applyAppearanceId:@"builtin.woodfish"];
    }
    [self reloadAppearancePacks];
    self.pendingAppearanceId = self.selectedAppearanceId;
  }
}

- (void)showAbout:(id)sender {
  (void)sender;
  NSAlert *alert = [[NMUiAlert alloc] init];
  alert.messageText = UiText(@"牛马电子功德", @"NiuMa Merit");
  NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?";
  NSString *aboutText = [NSString stringWithFormat:UiText(
      @"版本 %@\n\n"
       @"只统计按键、鼠标按键和滚轮手势发生的次数，不读取输入内容或鼠标位置。全屏隐身仅判断窗口是否覆盖屏幕，不保存应用或窗口信息。\n"
       @"本软件不包含网络请求、遥测或自动更新。\n\n"
       @"在其他应用中计数，需要允许本应用使用“输入监控”。\n"
       @"如仍未正常计数，可联系开发者或扫码进粉丝群寻求帮助。\n"
       @"Mac 权限与计数帮助\n\n"
       @"官方网站：\n"
       @"https://gongde.zqscreen.cn/\n\n"
       @"扫码进粉丝群，免费领取权益包。\n"
       @"和我一起学习 AI，创建并上架你的专属形象包。\n"
       @"抖音号：1872941388",
      @"Version %@\n\n"
       @"Counts keyboard presses, mouse button presses, and scroll gestures. It does not read "
       @"typed content or mouse positions. Fullscreen hiding checks window coverage without saving app or window information.\n"
       @"The app contains no network requests, telemetry, or automatic updates.\n\n"
       @"Counting in other apps requires Input Monitoring permission.\n"
       @"If input is still not being counted, contact the developer or scan the Douyin code to join the fan group for help.\n"
       @"Mac permissions and counting help\n\n"
       @"Official website:\n"
       @"https://gongde.zqscreen.cn/\n\n"
       @"Scan with Douyin to join the fan group and claim free benefit packs.\n"
       @"Learn AI with me, and create and publish your own appearance packs.\n"
       @"Douyin ID: 1872941388"), version];
  NSString *douyinPath = [NSBundle.mainBundle pathForResource:@"developer-douyin" ofType:@"png"];
  NSImage *douyinImage = douyinPath ? [[NSImage alloc] initWithContentsOfFile:douyinPath] : nil;
  NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
  NSRect visibleFrame = screen ? screen.visibleFrame : NSMakeRect(0, 0, 800, 600);
  CGFloat scrollerWidth = [NSScroller scrollerWidthForControlSize:NSControlSizeRegular
                                                  scrollerStyle:NSScrollerStyleLegacy];
  CGFloat contentWidth = MAX(240.0, MIN(340.0, NSWidth(visibleFrame) - 64.0 - scrollerWidth));
  NSFont *bodyFont = [NSFont systemFontOfSize:NSFont.systemFontSize];
  NSMutableAttributedString *bodyText = [[NSMutableAttributedString alloc] initWithString:aboutText
      attributes:@{NSFontAttributeName: bodyFont, NSForegroundColorAttributeName: NSColor.labelColor}];
  NSRange helpRange = [aboutText rangeOfString:UiText(@"Mac 权限与计数帮助",
      @"Mac permissions and counting help")];
  if (helpRange.location != NSNotFound) {
    [bodyText addAttributes:@{
        NSLinkAttributeName: @"https://gongde.zqscreen.cn/help-macos.html",
        NSForegroundColorAttributeName: NSColor.linkColor,
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)} range:helpRange];
  }
  NSRange promoRange = [aboutText rangeOfString:UiText(
      @"扫码进粉丝群，免费领取权益包。",
      @"Scan with Douyin to join the fan group and claim free benefit packs.")];
  if (promoRange.location != NSNotFound) {
    NSMutableParagraphStyle *promoStyle = [[NSMutableParagraphStyle alloc] init];
    promoStyle.alignment = NSTextAlignmentCenter;
    [bodyText addAttribute:NSParagraphStyleAttributeName value:promoStyle
        range:NSMakeRange(promoRange.location, aboutText.length - promoRange.location)];
  }
  CGFloat textHeight = ceil([bodyText boundingRectWithSize:NSMakeSize(contentWidth, CGFLOAT_MAX)
      options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading].size.height) + 4.0;
  CGFloat contentHeight = textHeight + 16.0 + (douyinImage ? 276.0 : 0.0);
  NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, contentWidth, contentHeight)];
  NSTextField *body = [[NSTextField alloc] initWithFrame:
      NSMakeRect(0, contentHeight - 8.0 - textHeight, contentWidth, textHeight)];
  body.editable = NO;
  body.selectable = YES;
  body.allowsEditingTextAttributes = YES;
  body.bordered = NO;
  body.drawsBackground = NO;
  body.usesSingleLineMode = NO;
  body.cell.wraps = YES;
  body.cell.scrollable = NO;
  body.lineBreakMode = NSLineBreakByWordWrapping;
  body.attributedStringValue = bodyText;
  [content addSubview:body];
  if (douyinImage) {
    NSImageView *code = [[NSImageView alloc] initWithFrame:
        NSMakeRect((contentWidth - 240.0) / 2.0, 8, 240, 260)];
    code.image = douyinImage;
    code.imageScaling = NSImageScaleProportionallyUpOrDown;
    code.imageAlignment = NSImageAlignCenter;
    code.toolTip = UiText(@"使用抖音扫一扫，进粉丝群领取权益包或寻求帮助",
                         @"Scan with Douyin to join the fan group for benefit packs or help");
    code.accessibilityLabel = UiText(@"开发者抖音码，抖音号 1872941388",
                                     @"Developer Douyin code, ID 1872941388");
    [content addSubview:code];
  }
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:
      NSMakeRect(0, 0, contentWidth + scrollerWidth, MIN(contentHeight, 120.0))];
  scroll.borderType = NSNoBorder;
  scroll.drawsBackground = NO;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.autohidesScrollers = NO;
  scroll.scrollerStyle = NSScrollerStyleLegacy;
  scroll.documentView = content;
  scroll.accessibilityLabel = UiText(@"关于牛马电子功德", @"About NiuMa Merit");
  alert.informativeText = @"";
  alert.accessoryView = scroll;
  [alert addButtonWithTitle:UiText(@"知道了", @"OK")];
  // Keep the native alert buttons outside the scroll area, reserving their actual layout height.
  [alert layout];
  CGFloat chromeHeight = NSHeight(alert.window.frame) - NSHeight(scroll.frame);
  CGFloat availableHeight = MAX(1.0, NSHeight(visibleFrame) - 40.0 - chromeHeight);
  [scroll setFrameSize:NSMakeSize(NSWidth(scroll.frame), MIN(contentHeight, availableHeight))];
  [alert layout];
  [content scrollPoint:NSMakePoint(0, MAX(0.0, contentHeight - scroll.contentSize.height))];
  [alert runModal];
}

@end

static CGEventRef EventTapCallback(CGEventTapProxy proxy,
                                   CGEventType type,
                                   CGEventRef event,
                                   void *context) {
  (void)proxy;
  if (gIsolatedAcceptance && !gAcceptancePhysicalInput) return event;
  MeritController *controller = (__bridge MeritController *)context;
  @autoreleasepool { [controller captureInputType:type event:event]; }
  return event;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (!InitializeAcceptanceContext(argc, argv)) {
      fprintf(stderr, "isolated_acceptance_configuration_invalid\n");
      return 2;
    }
    if (!AcquireSingleInstanceLock()) {
      fprintf(stderr, "niuma_merit_already_running_or_lock_unavailable\n");
      return 0;
    }
    NSApplication *app = NSApplication.sharedApplication;
    MeritController *controller = [[MeritController alloc] init];
    app.delegate = controller;
    [app run];
  }
  return 0;
}
