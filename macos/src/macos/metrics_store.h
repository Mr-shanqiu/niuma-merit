#pragma once

// 0.9.6 本地侧车 metrics-096.json（CONTRACT_096 §1 / §4.2 / §5）。
//
// 该文件与 0.9.5 的 NSUserDefaults 物理隔离：0.9.5 既不读也不删它，因此升级
// 可回退、回退不丢新数据。所有 0.9.6 新增本地数据统一放在命名空间
// "niuma.gongde.v096" 下，schema_version = 1。
//
// 本类只负责：定位、原子读写、备份/恢复、按顶层块独立降级。各块的字段语义由
// 上层（F2/F3/F4）通过 -encourager / -medals / -curve 访问并二次校验。
//
// 仅被 .mm 源文件包含（依赖 Foundation）。

#import <Foundation/Foundation.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const kNiuMa096Namespace = @"niuma.gongde.v096";
static const NSInteger kNiuMa096SchemaVersion = 1;
// 契约 §4.2 示例 app_version 为 0.9.6；构建 VERSION 的更名由发布窗口统一处理。
static NSString *const kNiuMa096AppVersion = @"0.9.6";
static NSString *const kNiuMa096ThresholdsVersion = @"builtin-2026-11-08";

static NSDictionary *NM096DefaultEncourager(void) {
  return @{
    @"enabled" : @NO,
    @"daily_wage_minor" : @0,
    @"currency" : @"CNY",
    @"currency_override" : @NO,
    @"start_minute" : @540,
    @"end_minute" : @1080,
  };
}

static NSDictionary *NM096DefaultMedals(void) {
  return @{
    @"thresholds_version" : kNiuMa096ThresholdsVersion,
    @"earned" : [NSMutableDictionary dictionary],
  };
}

static NSDictionary *NM096DefaultCurve(void) {
  return @{
    @"bucket_minutes" : @15,
    @"buckets_per_day" : @96,
    @"retention_days" : @60,
    @"days" : [NSMutableDictionary dictionary],
  };
}

static NSDictionary *NM096DefaultPrefs(void) {
  return @{@"ui_language" : @"zh-Hans", @"appearance_scale" : @1.0};
}

static NSDictionary *NM096DefaultRoot(void) {
  return [[NSMutableDictionary alloc] initWithDictionary:@{
    @"schema_version" : @(kNiuMa096SchemaVersion),
    @"namespace" : kNiuMa096Namespace,
    @"app_version" : kNiuMa096AppVersion,
    @"updated_at_utc" : @((long long)std::time(nullptr)),
    @"migration" : [NSMutableDictionary dictionary],
    @"prefs" : [NM096DefaultPrefs() mutableCopy],
    @"encourager" : [NM096DefaultEncourager() mutableCopy],
    @"medals" : [NM096DefaultMedals() mutableCopy],
    @"curve" : [NM096DefaultCurve() mutableCopy],
  }];
}

// ---- 块级校验辅助 ----
static BOOL NM096Dict(id value) { return [value isKindOfClass:NSDictionary.class]; }
static BOOL NM096Bool(id value) { return [value isKindOfClass:NSNumber.class]; }
static BOOL NM096IntRange(id value, long long lo, long long hi) {
  return [value isKindOfClass:NSNumber.class] &&
         [value longLongValue] >= lo && [value longLongValue] <= hi;
}

static BOOL NM096ValidEncourager(NSDictionary *b) {
  if (!NM096Dict(b)) return NO;
  if (!NM096Bool(b[@"enabled"]) || !NM096Bool(b[@"currency_override"])) return NO;
  if (![b[@"daily_wage_minor"] isKindOfClass:NSNumber.class] ||
      [b[@"daily_wage_minor"] longLongValue] < 0)
    return NO;
  if (![b[@"currency"] isKindOfClass:NSString.class]) return NO;
  if (!NM096IntRange(b[@"start_minute"], 0, 1440)) return NO;
  if (!NM096IntRange(b[@"end_minute"], 0, 1440)) return NO;
  if ([b[@"start_minute"] longLongValue] >= [b[@"end_minute"] longLongValue]) return NO;
  return YES;
}

static BOOL NM096ValidMedals(NSDictionary *b) {
  if (!NM096Dict(b)) return NO;
  if (![b[@"thresholds_version"] isKindOfClass:NSString.class]) return NO;
  if (!NM096Dict(b[@"earned"])) return NO;
  return YES;
}

static BOOL NM096ValidCurve(NSDictionary *b) {
  if (!NM096Dict(b)) return NO;
  if (!NM096IntRange(b[@"bucket_minutes"], 1, 1440)) return NO;
  if (!NM096IntRange(b[@"buckets_per_day"], 1, 4096)) return NO;
  if (!NM096IntRange(b[@"retention_days"], 1, 3650)) return NO;
  if (!NM096Dict(b[@"days"])) return NO;
  return YES;
}

static BOOL NM096ValidPrefs(NSDictionary *b) {
  if (!NM096Dict(b)) return NO;
  NSString *language = b[@"ui_language"];
  if (![language isKindOfClass:NSString.class]) return NO;
  NSSet *allowed = [NSSet setWithArray:@[ @"zh-Hans", @"zh-Hant", @"ja", @"en" ]];
  if (![allowed containsObject:language]) return NO;
  if (![b[@"appearance_scale"] isKindOfClass:NSNumber.class]) return NO;
  double scale = [b[@"appearance_scale"] doubleValue];
  if (!(scale >= 0.6 && scale <= 1.8)) return NO;
  return YES;
}

@interface NMMetricsStore : NSObject

@property(nonatomic, copy) NSString *directory;
@property(nonatomic, strong) NSMutableDictionary *root;
@property(nonatomic) BOOL loaded;
// 最近一次读取是否走了恢复/重建路径（诊断）。
@property(nonatomic) BOOL recoveredFromPrevious;
@property(nonatomic) BOOL rebuiltCorrupt;

+ (instancetype)storeInDirectory:(NSString *)directory;

- (void)load;   // 幂等：构造默认、探测旧数据、读取/恢复侧车、按块降级
- (void)save;   // 原子写：tmp -> fsync -> 备份 previous -> rename
- (NSString *)filePath;

// 返回可变的块引用；块已按默认值校验过，可直接修改后调用 -save。
- (NSMutableDictionary *)encourager;
- (NSMutableDictionary *)medals;
- (NSMutableDictionary *)curve;
- (NSMutableDictionary *)prefs;
- (NSMutableDictionary *)migration;

@end

@implementation NMMetricsStore

+ (instancetype)storeInDirectory:(NSString *)directory {
  NMMetricsStore *store = [[NMMetricsStore alloc] init];
  store.directory = directory;
  store.root = [NM096DefaultRoot() mutableCopy];
  return store;
}

- (NSString *)filePath {
  return [self.directory stringByAppendingPathComponent:@"metrics-096.json"];
}
- (NSString *)previousPath {
  return [self.directory stringByAppendingPathComponent:@"metrics-096.previous.json"];
}

- (BOOL)ensureDirectory {
  NSError *error = nil;
  if (![NSFileManager.defaultManager createDirectoryAtPath:self.directory
                              withIntermediateDirectories:YES
                                               attributes:@{
                                                 NSFilePosixPermissions : @0700
                                               }
                                                    error:&error]) {
    return NO;
  }
  return YES;
}

// 读取并 JSON 解析；成功返回字典，失败返回 nil。
- (NSMutableDictionary *)parseFileAtPath:(NSString *)path {
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (!data.length) return nil;
  NSError *error = nil;
  id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (![object isKindOfClass:NSDictionary.class]) return nil;
  NSMutableDictionary *dict = [object mutableCopy];
  if ([dict[@"schema_version"] integerValue] != kNiuMa096SchemaVersion) return nil;
  if (![dict[@"namespace"] isEqual:kNiuMa096Namespace]) {
    // 命名空间不匹配视为不可信文件（不同命名空间互不覆盖）。
    return nil;
  }
  return dict;
}

- (void)load {
  if (self.loaded) return;
  self.loaded = YES;
  [self ensureDirectory];
  NSString *path = [self filePath];
  NSMutableDictionary *loaded = [self parseFileAtPath:path];
  BOOL created = NO;
  if (!loaded) {
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
      // 正式文件损坏：尝试 previous，再退化为重建并把坏文件改名归档。
      NSMutableDictionary *previous = [self parseFileAtPath:[self previousPath]];
      if (previous) {
        loaded = previous;
        self.recoveredFromPrevious = YES;
      } else {
        NSString *corrupt =
            [self.directory stringByAppendingPathComponent:[NSString stringWithFormat:
                @"metrics-096.corrupt-%lld.json", (long long)std::time(nullptr)]];
        [NSFileManager.defaultManager moveItemAtPath:path toPath:corrupt error:nil];
        self.rebuiltCorrupt = YES;
      }
    }
    if (!loaded) {
      loaded = [NM096DefaultRoot() mutableCopy];
      created = YES;
    }
  }

  // 顶层必需字段补齐。
  if (![loaded[@"app_version"] isKindOfClass:NSString.class])
    loaded[@"app_version"] = kNiuMa096AppVersion;
  if (!NM096Dict(loaded[@"migration"]))
    loaded[@"migration"] = [NSMutableDictionary dictionary];

  // JSON 解码得到不可变字典；统一转为可变，避免后续原地修改崩溃。
  for (NSString *key in @[ @"migration", @"prefs", @"encourager", @"medals", @"curve" ]) {
    if ([loaded[key] isKindOfClass:NSDictionary.class] &&
        ![loaded[key] isKindOfClass:NSMutableDictionary.class])
      loaded[key] = [loaded[key] mutableCopy];
  }

  // 首次创建：记录迁移收据（CONTRACT_096 §5.1）。幂等，仅一次。
  NSMutableDictionary *migration = loaded[@"migration"];
  if (created && ![migration[@"from_095"] boolValue]) {
    migration[@"from_095"] = @YES;
    migration[@"migrated_at_utc"] = @((long long)std::time(nullptr));
    migration[@"legacy_source"] = @"nsuserdefaults";
  }

  // 按块独立降级：坏块只影响对应功能。
  if (!NM096ValidPrefs(loaded[@"prefs"])) loaded[@"prefs"] = [NM096DefaultPrefs() mutableCopy];
  if (!NM096ValidEncourager(loaded[@"encourager"]))
    loaded[@"encourager"] = [NM096DefaultEncourager() mutableCopy];
  if (!NM096ValidMedals(loaded[@"medals"]))
    loaded[@"medals"] = [NM096DefaultMedals() mutableCopy];
  if (!NM096ValidCurve(loaded[@"curve"]))
    loaded[@"curve"] = [NM096DefaultCurve() mutableCopy];
  self.root = loaded;
  // 清理残留 .tmp（崩溃恢复）。
  [NSFileManager.defaultManager removeItemAtPath:[[self filePath] stringByAppendingString:@".tmp"]
                                            error:nil];
}

- (void)save {
  if (!self.root) return;
  [self ensureDirectory];
  self.root[@"updated_at_utc"] = @((long long)std::time(nullptr));
  self.root[@"app_version"] = kNiuMa096AppVersion;
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:self.root options:0 error:&error];
  if (!data) return;
  NSString *path = [self filePath];
  NSString *tmp = [path stringByAppendingString:@".tmp"];
  // 原子写：open(tmp) -> write -> fsync -> close。
  const char *tmpPath = tmp.fileSystemRepresentation;
  int fd = open(tmpPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (fd < 0) return;
  const char *bytes = static_cast<const char *>(data.bytes);
  NSUInteger remaining = data.length;
  NSUInteger offset = 0;
  BOOL wroteOK = YES;
  while (offset < remaining) {
    ssize_t written = write(fd, bytes + offset, remaining - offset);
    if (written <= 0) {
      if (errno == EINTR) continue;
      wroteOK = NO;
      break;
    }
    offset += static_cast<NSUInteger>(written);
  }
  if (wroteOK) fsync(fd);
  close(fd);
  if (!wroteOK) {
    unlink(tmpPath);
    return;
  }
  // 备份上一版本后原子 rename。
  if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
    [NSFileManager.defaultManager removeItemAtPath:[self previousPath] error:nil];
    [NSFileManager.defaultManager copyItemAtPath:path toPath:[self previousPath] error:nil];
  }
  rename(tmpPath, path.fileSystemRepresentation);
}

- (NSMutableDictionary *)block:(NSString *)key default:(NSDictionary *)fallback {
  id value = self.root[key];
  if ([value isKindOfClass:NSMutableDictionary.class]) return value;
  if ([value isKindOfClass:NSDictionary.class]) {
    // JSON 解码得到的是不可变字典；原地转为可变，保留已加载的数据。
    NSMutableDictionary *mutableValue = [value mutableCopy];
    self.root[key] = mutableValue;
    return mutableValue;
  }
  NSMutableDictionary *replacement = [fallback mutableCopy];
  self.root[key] = replacement;
  return replacement;
}
- (NSMutableDictionary *)encourager { return [self block:@"encourager" default:NM096DefaultEncourager()]; }
- (NSMutableDictionary *)medals { return [self block:@"medals" default:NM096DefaultMedals()]; }
- (NSMutableDictionary *)curve { return [self block:@"curve" default:NM096DefaultCurve()]; }
- (NSMutableDictionary *)prefs { return [self block:@"prefs" default:NM096DefaultPrefs()]; }
- (NSMutableDictionary *)migration { return [self block:@"migration" default:@{}]; }

@end
