import 'dart:convert';

import 'package:flutter/material.dart';

/// 桌面歌词窗口内文字的水平对齐方式。
///
/// 对应 lx-music 的 `desktopLyric.textPosition.x`。
enum DesktopLyricTextAlignX { left, center, right }

/// 桌面歌词窗口内文字的垂直对齐方式。
///
/// 对应 lx-music 的 `desktopLyric.textPosition.y`。
enum DesktopLyricTextAlignY { top, center, bottom }

/// 桌面歌词(悬浮歌词窗)的完整配置。
///
/// 字段与取值区间参考 lx-music 的 `desktopLyric.*` 设置项:
/// - `enable` / `isLock` / `isSingleLine` / `showToggleAnima`:开关
/// - `widthPercent`:窗口宽度占屏幕宽度的百分比
/// - `maxLineNum`:窗口最多显示的行数
/// - `fontSize`:歌词字号(px)
/// - `opacityPercent`:整体不透明度
/// - `positionX` / `positionY`:窗口位置,以「可移动空间」的百分比存储,
///   这样屏幕尺寸/方向变化后位置依旧保持相对一致。
/// - `playedColor` / `unplayColor` / `shadowColor`:已播放、未播放、描边阴影颜色
class DesktopLyricSettings {
  const DesktopLyricSettings({
    required this.enable,
    required this.isLock,
    required this.isSingleLine,
    required this.showToggleAnima,
    required this.widthPercent,
    required this.maxLineNum,
    required this.fontSize,
    required this.opacityPercent,
    required this.textAlignX,
    required this.textAlignY,
    required this.positionX,
    required this.positionY,
    required this.playedColor,
    required this.unplayColor,
    required this.shadowColor,
  });

  /// lx-music `defaultSetting.ts` 中的默认值(播放色沿用经典绿)。
  static const DesktopLyricSettings defaults = DesktopLyricSettings(
    enable: false,
    isLock: false,
    isSingleLine: false,
    showToggleAnima: true,
    widthPercent: 100,
    maxLineNum: 5,
    fontSize: 18,
    opacityPercent: 100,
    textAlignX: DesktopLyricTextAlignX.left,
    textAlignY: DesktopLyricTextAlignY.top,
    positionX: 3,
    positionY: 8,
    playedColor: 0xFF07C556,
    unplayColor: 0xFFFFFFFF,
    shadowColor: 0x99000000,
  );

  /// 是否启用桌面歌词。
  final bool enable;

  /// 锁定后歌词窗不再响应触摸(点击穿透到下层页面),且隐藏背景与拖动把手。
  final bool isLock;

  /// 单行模式:只显示当前行,超长时横向滚动。
  final bool isSingleLine;

  /// 歌词切换时是否播放淡入淡出动画。
  final bool showToggleAnima;

  /// 窗口宽度占屏幕宽度的百分比,10 ~ 100。
  final int widthPercent;

  /// 窗口最多显示的行数,1 ~ 8。
  final int maxLineNum;

  /// 歌词字号(px),12 ~ 40。
  final double fontSize;

  /// 整体不透明度百分比,10 ~ 100。
  final int opacityPercent;

  final DesktopLyricTextAlignX textAlignX;
  final DesktopLyricTextAlignY textAlignY;

  /// 窗口左上角在可移动空间中的横向百分比位置,0 ~ 100。
  final double positionX;

  /// 窗口左上角在可移动空间中的纵向百分比位置,0 ~ 100。
  final double positionY;

  /// 已播放(当前行)歌词颜色,ARGB。
  final int playedColor;

  /// 未播放歌词颜色,ARGB。
  final int unplayColor;

  /// 歌词描边/阴影颜色,ARGB。
  final int shadowColor;

  /// 实际生效的不透明度,0.1 ~ 1.0。
  double get opacity => (opacityPercent / 100).clamp(0.05, 1.0);

  TextAlign get textAlign {
    switch (textAlignX) {
      case DesktopLyricTextAlignX.left:
        return TextAlign.left;
      case DesktopLyricTextAlignX.center:
        return TextAlign.center;
      case DesktopLyricTextAlignX.right:
        return TextAlign.right;
    }
  }

  MainAxisAlignment get verticalAlignment {
    switch (textAlignY) {
      case DesktopLyricTextAlignY.top:
        return MainAxisAlignment.start;
      case DesktopLyricTextAlignY.center:
        return MainAxisAlignment.center;
      case DesktopLyricTextAlignY.bottom:
        return MainAxisAlignment.end;
    }
  }

  /// 窗口实际显示的行数(单行模式恒为 1)。
  int get visibleLineNum => isSingleLine ? 1 : maxLineNum;

  DesktopLyricSettings copyWith({
    bool? enable,
    bool? isLock,
    bool? isSingleLine,
    bool? showToggleAnima,
    int? widthPercent,
    int? maxLineNum,
    double? fontSize,
    int? opacityPercent,
    DesktopLyricTextAlignX? textAlignX,
    DesktopLyricTextAlignY? textAlignY,
    double? positionX,
    double? positionY,
    int? playedColor,
    int? unplayColor,
    int? shadowColor,
  }) {
    return DesktopLyricSettings(
      enable: enable ?? this.enable,
      isLock: isLock ?? this.isLock,
      isSingleLine: isSingleLine ?? this.isSingleLine,
      showToggleAnima: showToggleAnima ?? this.showToggleAnima,
      widthPercent: widthPercent ?? this.widthPercent,
      maxLineNum: maxLineNum ?? this.maxLineNum,
      fontSize: fontSize ?? this.fontSize,
      opacityPercent: opacityPercent ?? this.opacityPercent,
      textAlignX: textAlignX ?? this.textAlignX,
      textAlignY: textAlignY ?? this.textAlignY,
      positionX: positionX ?? this.positionX,
      positionY: positionY ?? this.positionY,
      playedColor: playedColor ?? this.playedColor,
      unplayColor: unplayColor ?? this.unplayColor,
      shadowColor: shadowColor ?? this.shadowColor,
    );
  }

  Map<String, dynamic> toJson() => {
    'enable': enable,
    'isLock': isLock,
    'isSingleLine': isSingleLine,
    'showToggleAnima': showToggleAnima,
    'widthPercent': widthPercent,
    'maxLineNum': maxLineNum,
    'fontSize': fontSize,
    'opacityPercent': opacityPercent,
    'textAlignX': textAlignX.name,
    'textAlignY': textAlignY.name,
    'positionX': positionX,
    'positionY': positionY,
    'playedColor': playedColor,
    'unplayColor': unplayColor,
    'shadowColor': shadowColor,
  };

  static DesktopLyricSettings fromJson(Map<String, dynamic> json) {
    T readEnum<T extends Enum>(Iterable<T> values, String? name, T fallback) {
      if (name != null) {
        for (final v in values) {
          if (v.name == name) return v;
        }
      }
      return fallback;
    }

    num? readNum(dynamic v) => v is num ? v : null;

    return DesktopLyricSettings(
      enable: json['enable'] as bool? ?? defaults.enable,
      isLock: json['isLock'] as bool? ?? defaults.isLock,
      isSingleLine: json['isSingleLine'] as bool? ?? defaults.isSingleLine,
      showToggleAnima:
          json['showToggleAnima'] as bool? ?? defaults.showToggleAnima,
      widthPercent:
          (readNum(json['widthPercent'])?.toInt() ?? defaults.widthPercent)
              .clamp(10, 100),
      maxLineNum: (readNum(json['maxLineNum'])?.toInt() ?? defaults.maxLineNum)
          .clamp(1, 8),
      fontSize: (readNum(json['fontSize'])?.toDouble() ?? defaults.fontSize)
          .clamp(12.0, 40.0),
      opacityPercent:
          (readNum(json['opacityPercent'])?.toInt() ?? defaults.opacityPercent)
              .clamp(10, 100),
      textAlignX: readEnum(
        DesktopLyricTextAlignX.values,
        json['textAlignX'] as String?,
        defaults.textAlignX,
      ),
      textAlignY: readEnum(
        DesktopLyricTextAlignY.values,
        json['textAlignY'] as String?,
        defaults.textAlignY,
      ),
      positionX: (readNum(json['positionX'])?.toDouble() ?? defaults.positionX)
          .clamp(0.0, 100.0),
      positionY: (readNum(json['positionY'])?.toDouble() ?? defaults.positionY)
          .clamp(0.0, 100.0),
      playedColor: readNum(json['playedColor'])?.toInt() ?? defaults.playedColor,
      unplayColor: readNum(json['unplayColor'])?.toInt() ?? defaults.unplayColor,
      shadowColor: readNum(json['shadowColor'])?.toInt() ?? defaults.shadowColor,
    );
  }

  /// 从持久化的 JSON 字符串还原,失败时回退到默认配置。
  static DesktopLyricSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return fromJson(decoded);
      return fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return defaults;
    }
  }

  String encode() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) {
    return other is DesktopLyricSettings &&
        other.enable == enable &&
        other.isLock == isLock &&
        other.isSingleLine == isSingleLine &&
        other.showToggleAnima == showToggleAnima &&
        other.widthPercent == widthPercent &&
        other.maxLineNum == maxLineNum &&
        other.fontSize == fontSize &&
        other.opacityPercent == opacityPercent &&
        other.textAlignX == textAlignX &&
        other.textAlignY == textAlignY &&
        other.positionX == positionX &&
        other.positionY == positionY &&
        other.playedColor == playedColor &&
        other.unplayColor == unplayColor &&
        other.shadowColor == shadowColor;
  }

  @override
  int get hashCode => Object.hash(
    enable,
    isLock,
    isSingleLine,
    showToggleAnima,
    widthPercent,
    maxLineNum,
    fontSize,
    opacityPercent,
    textAlignX,
    textAlignY,
    positionX,
    positionY,
    playedColor,
    unplayColor,
    shadowColor,
  );
}
