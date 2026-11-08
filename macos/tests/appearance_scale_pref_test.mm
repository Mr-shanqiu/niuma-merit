// F1 偏好迁侧车自测（CONTRACT_096 §13.2）：
// - 侧车 prefs.appearance_scale 存在时优先；
// - 侧车无值（新文件 / 坏块降级）时读旧 NSUserDefaults 键作一次性迁移回退；
// - 两侧都没有时用默认 1.0；任何来源都钳制到 §3 的 0.6..1.8。
// 编译运行：
//   clang++ -std=c++17 -fobjc-arc -framework Foundation \
//     -I ../src/macos appearance_scale_pref_test.mm \
//     -o /tmp/appearance_scale_pref_test && /tmp/appearance_scale_pref_test
#import <Foundation/Foundation.h>
#include "metrics_store.h"

#include <cstdio>

static int g_fail = 0;
#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);         \
      ++g_fail;                                                           \
    }                                                                     \
  } while (0)

static BOOL Close(double a, double b) { return a > b - 1e-9 && a < b + 1e-9; }

// 每个用例一个独立临时目录（0700），结束统一清理。
static NSMutableArray<NSString *> *gTempDirs;
static NSString *TempDir(void) {
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
      [NSString stringWithFormat:@"nm096-pref-test-%@", NSUUID.UUID.UUIDString]];
  NSError *error = nil;
  BOOL ok = [NSFileManager.defaultManager createDirectoryAtPath:dir
      withIntermediateDirectories:YES attributes:@{ NSFilePosixPermissions : @0700 }
      error:&error];
  if (!ok || error) return nil;
  if (!gTempDirs) gTempDirs = [NSMutableArray array];
  [gTempDirs addObject:dir];
  return dir;
}

static BOOL WriteSidecar(NSString *dir, id jsonObject) {
  NSString *path = [dir stringByAppendingPathComponent:@"metrics-096.json"];
  NSError *error = nil;
  NSData *data = jsonObject
      ? [NSJSONSerialization dataWithJSONObject:jsonObject options:0 error:&error]
      : [@"not json" dataUsingEncoding:NSUTF8StringEncoding];
  if (!data || error) return NO;
  return [data writeToFile:path atomically:YES];
}

static NSMutableDictionary *RootWithPrefs(NSDictionary *prefs) {
  NSMutableDictionary *root = [NM096DefaultRoot() mutableCopy];
  root[@"prefs"] = [prefs mutableCopy];
  return root;
}

static double Resolve(NMMetricsStore *store, id legacyValue) {
  return NM096ResolveAppearanceScale(store.hasStoredAppearanceScale,
      [store prefs][@"appearance_scale"], legacyValue);
}

int main() {
  @autoreleasepool {
    // 1. 侧车已有合法值：侧车优先，旧值不再参与。
    {
      NSString *dir = TempDir();
      CHECK(WriteSidecar(dir, RootWithPrefs(
          @{@"ui_language" : @"ja", @"appearance_scale" : @1.35})));
      NMMetricsStore *store = [NMMetricsStore storeInDirectory:dir];
      [store load];
      CHECK(store.hasStoredAppearanceScale);
      CHECK(Close([[store prefs][@"appearance_scale"] doubleValue], 1.35));
      CHECK(Close(Resolve(store, @0.7), 1.35));
      CHECK(Close(Resolve(store, nil), 1.35));
    }

    // 2. 侧车不存在：无存储值，回退旧键；旧键缺失时用 1.0。
    {
      NSString *dir = TempDir();
      NMMetricsStore *store = [NMMetricsStore storeInDirectory:dir];
      [store load];
      CHECK(!store.hasStoredAppearanceScale);
      CHECK(Close([[store prefs][@"appearance_scale"] doubleValue], 1.0));
      CHECK(Close(Resolve(store, @0.7), 0.7));
      CHECK(Close(Resolve(store, @1.35), 1.35));
      CHECK(Close(Resolve(store, nil), 1.0));
    }

    // 3. 钳制与非数值：旧值越界钳到 0.6..1.8，非数值回 1.0。
    CHECK(Close(NM096ResolveAppearanceScale(NO, nil, @2.5), 1.8));
    CHECK(Close(NM096ResolveAppearanceScale(NO, nil, @0.1), 0.6));
    CHECK(Close(NM096ResolveAppearanceScale(NO, nil, nil), 1.0));
    CHECK(Close(NM096ResolveAppearanceScale(NO, nil, @""), 1.0));
    CHECK(Close(NM096ResolveAppearanceScale(NO, nil, @0.9), 0.9));
    // 侧车值已在块校验时钳制过；此函数对任意来源都统一钳制。
    CHECK(Close(NM096ResolveAppearanceScale(YES, @1.8, @0.5), 1.8));
    CHECK(Close(NM096ResolveAppearanceScale(YES, @0.6, @1.5), 0.6));

    // 4. 侧车 prefs 缺 appearance_scale：整块坏，不算「有值」，回退旧键。
    {
      NSString *dir = TempDir();
      CHECK(WriteSidecar(dir, RootWithPrefs(@{@"ui_language" : @"zh-Hans"})));
      NMMetricsStore *store = [NMMetricsStore storeInDirectory:dir];
      [store load];
      CHECK(!store.hasStoredAppearanceScale);
      CHECK(Close([[store prefs][@"appearance_scale"] doubleValue], 1.0));
      CHECK(Close(Resolve(store, @1.2), 1.2));
    }

    // 5. 侧车 prefs 的 appearance_scale 越界：整块坏，回退旧键。
    {
      NSString *dir = TempDir();
      CHECK(WriteSidecar(dir, RootWithPrefs(
          @{@"ui_language" : @"zh-Hans", @"appearance_scale" : @2.0})));
      NMMetricsStore *store = [NMMetricsStore storeInDirectory:dir];
      [store load];
      CHECK(!store.hasStoredAppearanceScale);
      CHECK(Close(Resolve(store, @1.2), 1.2));
      CHECK(Close(Resolve(store, nil), 1.0));
    }

    // 6. 侧车 ui_language 非法：prefs 整块坏，回退旧键。
    {
      NSString *dir = TempDir();
      CHECK(WriteSidecar(dir, RootWithPrefs(
          @{@"ui_language" : @"fr", @"appearance_scale" : @1.3})));
      NMMetricsStore *store = [NMMetricsStore storeInDirectory:dir];
      [store load];
      CHECK(!store.hasStoredAppearanceScale);
      CHECK(Close(Resolve(store, @1.2), 1.2));
    }

    // 7. 正式文件损坏、previous 完整：恢复 previous，其 prefs 仍是「有值」。
    {
      NSString *dir = TempDir();
      CHECK(WriteSidecar(dir, nil));
      NSError *error = nil;
      NSData *previousData = [NSJSONSerialization dataWithJSONObject:
          RootWithPrefs(@{@"ui_language" : @"en", @"appearance_scale" : @1.5})
          options:0 error:&error];
      CHECK(previousData && !error);
      CHECK([previousData writeToFile:
          [dir stringByAppendingPathComponent:@"metrics-096.previous.json"]
          atomically:YES]);
      NMMetricsStore *store = [NMMetricsStore storeInDirectory:dir];
      [store load];
      CHECK(store.recoveredFromPrevious);
      CHECK(store.hasStoredAppearanceScale);
      CHECK(Close(Resolve(store, @0.7), 1.5));
    }

    // 8. 正式文件损坏且无 previous：重建默认，不算「有值」。
    {
      NSString *dir = TempDir();
      CHECK(WriteSidecar(dir, nil));
      NMMetricsStore *store = [NMMetricsStore storeInDirectory:dir];
      [store load];
      CHECK(store.rebuiltCorrupt);
      CHECK(!store.hasStoredAppearanceScale);
      CHECK(Close(Resolve(store, @1.2), 1.2));
    }

    // 9. 迁移写入一次后，重启读出即为「有值」，不再回退旧键。
    {
      NSString *dir = TempDir();
      NMMetricsStore *store = [NMMetricsStore storeInDirectory:dir];
      [store load];
      CHECK(!store.hasStoredAppearanceScale);
      double migrated = Resolve(store, @1.35);  // 一次性迁移回退
      CHECK(Close(migrated, 1.35));
      [store prefs][@"appearance_scale"] = @(migrated);
      [store save];

      NMMetricsStore *reloaded = [NMMetricsStore storeInDirectory:dir];
      [reloaded load];
      CHECK(reloaded.hasStoredAppearanceScale);
      CHECK(Close(Resolve(reloaded, @0.6), 1.35));  // 旧键被忽略
      CHECK(Close(Resolve(reloaded, nil), 1.35));
    }

    for (NSString *dir in gTempDirs) {
      [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    }
    if (g_fail) {
      std::printf("appearance_scale_pref_test FAILED (%d)\n", g_fail);
      return 1;
    }
    std::printf("appearance_scale_pref_test PASSED\n");
    return 0;
  }
}
