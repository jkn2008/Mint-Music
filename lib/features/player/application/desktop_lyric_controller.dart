import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_providers.dart';
import '../domain/models/desktop_lyric_settings.dart';
import '../domain/models/lyric_line.dart';
import 'lyric_controller.dart';
import 'playback_controller.dart';

/// 当前播放进度对应的歌词行下标。
///
/// 播放进度每 200ms 才会推一次,这里把它收敛成一个 `int`:
/// 只有「当前行真的变了」时才通知监听者重建,避免悬浮歌词窗每 200ms 重绘。
final desktopLyricActiveIndexProvider = Provider<int>((ref) {
  // 未开启时不订阅歌词,避免为桌面歌词提前拉取歌词。
  final enabled = ref.watch(
    desktopLyricSettingsProvider.select((s) => s.enable),
  );
  if (!enabled) return -1;
  final lines = ref.watch(lyricControllerProvider.select((s) => s.lines));
  if (lines.isEmpty) return -1;
  final positionMs = ref.watch(
    playbackControllerProvider.select((s) => s.position.inMilliseconds),
  );
  final index = lines.lastIndexWhere((line) => line.startTimeMs <= positionMs);
  // 进度早于第一行的起始时间时,仍然展示第一行。
  return index < 0 ? 0 : index;
});

/// 桌面歌词使用的歌词行。
///
/// 同样只在开启时才订阅 [lyricControllerProvider]:歌词控制器一旦被监听
/// 就会在切歌时主动拉取歌词,未开启桌面歌词时不应产生这些请求。
final desktopLyricLinesProvider = Provider<List<LyricLine>>((ref) {
  final enabled = ref.watch(
    desktopLyricSettingsProvider.select((s) => s.enable),
  );
  if (!enabled) return const [];
  return ref.watch(lyricControllerProvider.select((s) => s.lines));
});

/// 读取 provider 的函数类型。
///
/// Riverpod 的 `Ref`(非 UI 场景)与 `WidgetRef`(UI 场景)没有公共父类型,
/// 但两者的 `read` 签名一致,因此用这个函数类型做桥接,调用处传 `ref.read`。
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// 更新桌面歌词配置:先更新内存态,再异步落盘。
void updateDesktopLyricSettings(
  ProviderReader read,
  DesktopLyricSettings Function(DesktopLyricSettings current) update,
) {
  final current = read(desktopLyricSettingsProvider);
  final next = update(current);
  if (next == current) return;
  read(desktopLyricSettingsProvider.notifier).state = next;
  unawaited(_saveDesktopLyricSettings(read, next));
}

Future<void> _saveDesktopLyricSettings(
  ProviderReader read,
  DesktopLyricSettings settings,
) async {
  try {
    final svc = await read(settingsServiceProvider.future);
    await svc.setDesktopLyricSettings(settings.encode());
  } catch (_) {
    // 持久化失败不影响本次会话内的显示。
  }
}
