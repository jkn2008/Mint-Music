import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_providers.dart';
import '../domain/models/desktop_lyric_settings.dart';
import '../platform/desktop_lyric_overlay.dart';
import 'desktop_lyric_controller.dart';
import 'lyric_controller.dart';
import 'playback_controller.dart';

/// 桌面歌词的运行状态。
class DesktopLyricStatus {
  const DesktopLyricStatus({
    this.supported = false,
    this.permissionGranted = false,
    this.overlayShowing = false,
  });

  /// 当前平台是否支持系统级悬浮窗(Android)。
  final bool supported;

  /// 是否已获得「在其他应用上层显示」权限。
  final bool permissionGranted;

  /// 系统悬浮窗当前是否已显示。
  final bool overlayShowing;

  /// 歌词正由系统悬浮窗渲染。为 false 时回退到应用内悬浮层。
  bool get usingNativeOverlay => supported && permissionGranted && overlayShowing;

  DesktopLyricStatus copyWith({
    bool? supported,
    bool? permissionGranted,
    bool? overlayShowing,
  }) {
    return DesktopLyricStatus(
      supported: supported ?? this.supported,
      permissionGranted: permissionGranted ?? this.permissionGranted,
      overlayShowing: overlayShowing ?? this.overlayShowing,
    );
  }
}

/// 把「设置 + 播放状态 + 歌词」同步到系统悬浮窗。
///
/// 三件事:
/// 1. 权限:未授权时引导授权,从授权页返回(resumed)后自动重试;
/// 2. 歌词:桌面歌词开启时主动为当前歌曲拉取歌词(歌词页未打开时也要拉);
/// 3. 渲染:歌词行变化时整批下发,当前行变化时只下发行号。
class DesktopLyricSyncController extends StateNotifier<DesktopLyricStatus>
    with WidgetsBindingObserver {
  DesktopLyricSyncController(this._ref) : super(const DesktopLyricStatus()) {
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  final Ref _ref;
  final DesktopLyricOverlay _overlay = DesktopLyricOverlay.instance;

  String? _pushedSongId;
  int _lastPushedIndex = -1;

  /// 用户点了开启但还没拿到悬浮窗权限:授权成功后自动开启。
  bool _pendingEnable = false;

  /// 定期向原生侧下发进度锚点(校准漂移/处理跳转)。
  Timer? _anchorTimer;

  /// 上一次观测到的播放进度。
  ///
  /// 后台时 Dart 的进度回调可能被节流而停滞;此时若继续下发同一个进度,
  /// 会把原生侧正在自行推进的时钟反复拉回去,导致歌词卡住不更新。
  int _lastObservedPositionMs = -1;

  Future<void> _bootstrap() async {
    _overlay.setPositionListener(_onPositionChanged);
    if (!_overlay.supported) {
      state = const DesktopLyricStatus(supported: false);
      return;
    }
    await refreshPermission();
  }

  @override
  void dispose() {
    _stopAnchorTimer();
    _overlay.setPositionListener(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统授权页返回后重新检查权限。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshPermission());
    }
  }

  Future<void> refreshPermission() async {
    if (!_overlay.supported) return;
    final granted = await _overlay.checkPermission();
    if (!mounted) return;
    this.state = this.state.copyWith(
      supported: true,
      permissionGranted: granted,
    );
    if (!granted) {
      await _overlay.hide();
      _stopAnchorTimer();
      if (mounted) this.state = this.state.copyWith(overlayShowing: false);
      return;
    }
    // 授权成功后补上之前被拦下的「开启」操作。
    if (_pendingEnable) {
      _pendingEnable = false;
      _setEnable(true);
    }
    await syncVisibility();
  }

  /// 打开系统悬浮窗授权页。
  Future<void> requestPermission() => _overlay.openPermissionSettings();

  /// 开启桌面歌词:**先取权限,拿到之后才真正开启**。
  ///
  /// 未授权时不写 `enable = true`,而是跳到系统授权页;用户授权后回到应用
  /// ([didChangeAppLifecycleState] -> [refreshPermission])再自动开启。
  Future<void> enableDesktopLyric() async {
    // 非 Android(应用内回退方案)不需要权限。
    if (!_overlay.supported) {
      _setEnable(true);
      return;
    }
    if (await _overlay.checkPermission()) {
      await refreshPermission();
      _setEnable(true);
      return;
    }
    _pendingEnable = true;
    await _overlay.openPermissionSettings();
  }

  Future<void> disableDesktopLyric() async {
    _pendingEnable = false;
    _setEnable(false);
  }

  void _setEnable(bool value) {
    updateDesktopLyricSettings(
      _ref.read,
      (s) => s.copyWith(enable: value),
    );
  }

  // ------------------------------------------------------------------ 同步

  /// 设置变化:开关变化影响显示与否,其余样式项直接下发给原生。
  void onSettingsChanged(
    DesktopLyricSettings? previous,
    DesktopLyricSettings next,
  ) {
    if (previous?.enable != next.enable) {
      unawaited(syncVisibility());
      return;
    }
    if (!state.usingNativeOverlay) return;
    unawaited(_overlay.updateConfig(next));
  }

  /// 切歌:重置已下发的歌词,并为新歌主动拉取歌词。
  void onSongChanged() {
    _pushedSongId = null;
    _lastPushedIndex = -1;
    _lastObservedPositionMs = -1;
    ensureLyricsLoaded();
    unawaited(syncVisibility());
  }

  /// 歌词加载完成:整批下发。
  void onLyricChanged() {
    ensureLyricsLoaded();
    unawaited(pushLyric(force: true));
  }

  Future<void> pushActiveIndex(int index) async {
    if (!state.usingNativeOverlay) return;
    if (index == _lastPushedIndex) return;
    _lastPushedIndex = index;
    await _overlay.updateActiveIndex(index);
  }

  /// 桌面歌词开启时,即使歌词页没打开也要为当前歌曲拉取歌词。
  ///
  /// [lyricControllerProvider] 内部已经监听切歌,但它只在被监听时才存在;
  /// 这里保证「开启桌面歌词」这一路径一定会触发一次加载。
  void ensureLyricsLoaded() {
    if (!_ref.read(desktopLyricSettingsProvider).enable) return;
    final song = _ref.read(playbackControllerProvider).currentSong;
    if (song == null) return;
    final lyric = _ref.read(lyricControllerProvider);
    final loaded = lyric.currentSongId == song.id && lyric.lines.isNotEmpty;
    if (loaded || lyric.isLoading) return;
    unawaited(_ref.read(lyricControllerProvider.notifier).loadLyrics(song));
  }

  Future<void> syncVisibility() async {
    final settings = _ref.read(desktopLyricSettingsProvider);
    final song = _ref.read(playbackControllerProvider).currentSong;

    if (!settings.enable || song == null) {
      await _overlay.hide();
      if (mounted) state = state.copyWith(overlayShowing: false);
      _pushedSongId = null;
      return;
    }

    ensureLyricsLoaded();

    if (!_overlay.supported || !state.permissionGranted) {
      _stopAnchorTimer();
      if (mounted) state = state.copyWith(overlayShowing: false);
      return;
    }

    final shown = await _overlay.show();
    if (!mounted) return;
    state = state.copyWith(overlayShowing: shown);
    if (!shown) {
      _stopAnchorTimer();
      return;
    }

    await _overlay.updateConfig(settings);
    await pushLyric(force: true);
    // 交给原生侧自行推进,并定期校准。
    await pushPlayState(force: true);
    _startAnchorTimer();
  }

  /// 下发一次进度锚点。
  ///
  /// 非强制调用时,若观测到的进度与上次相同就跳过:这说明 Dart 侧进度已停止
  /// 更新(应用退到后台被节流),此时应让原生侧的时钟继续自行推进。
  Future<void> pushPlayState({bool force = false}) async {
    if (!state.usingNativeOverlay) return;
    final playback = _ref.read(playbackControllerProvider);
    final positionMs = playback.position.inMilliseconds;
    if (!force && positionMs == _lastObservedPositionMs) return;
    _lastObservedPositionMs = positionMs;
    await _overlay.setPlayState(
      positionMs: positionMs,
      isPlaying: playback.isPlaying,
    );
  }

  void _startAnchorTimer() {
    _anchorTimer?.cancel();
    _anchorTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(pushPlayState());
    });
  }

  void _stopAnchorTimer() {
    _anchorTimer?.cancel();
    _anchorTimer = null;
  }

  Future<void> pushLyric({bool force = false}) async {
    if (!state.usingNativeOverlay) return;
    final song = _ref.read(playbackControllerProvider).currentSong;
    if (song == null) return;
    if (!force && _pushedSongId == song.id) return;

    final lyric = _ref.read(lyricControllerProvider);
    if (lyric.lines.isEmpty) return;

    _pushedSongId = song.id;
    _lastPushedIndex = _ref.read(desktopLyricActiveIndexProvider);
    await _overlay.updateLyric(
      lines: lyric.lines,
      activeIndex: _lastPushedIndex,
      showTranslation: _ref.read(lyricShowTranslationProvider),
      showRoman: _ref.read(lyricShowRomanProvider),
    );
    // 歌词换了之后必须重新锚定,否则原生会用上一首歌的进度去推算行号。
    _lastObservedPositionMs = -1;
    await pushPlayState(force: true);
  }

  void _onPositionChanged(double x, double y) {
    updateDesktopLyricSettings(
      _ref.read,
      (s) => s.copyWith(positionX: x, positionY: y),
    );
  }
}

final desktopLyricSyncProvider =
    StateNotifierProvider<DesktopLyricSyncController, DesktopLyricStatus>((ref) {
      final controller = DesktopLyricSyncController(ref);

      ref.listen(desktopLyricSettingsProvider, (previous, next) {
        controller.onSettingsChanged(previous, next);
      });
      ref.listen(playbackControllerProvider.select((s) => s.currentSong), (
        _,
        __,
      ) {
        controller.onSongChanged();
      });
      ref.listen(desktopLyricLinesProvider, (_, __) {
        controller.onLyricChanged();
      });
      ref.listen(desktopLyricActiveIndexProvider, (_, next) {
        controller.pushActiveIndex(next);
      });
      // 播放/暂停切换时立刻刷新锚点,暂停后原生侧停止推进。
      ref.listen(playbackControllerProvider.select((s) => s.isPlaying), (_, __) {
        unawaited(controller.pushPlayState(force: true));
      });

      ref.onDispose(controller.dispose);
      return controller;
    });
