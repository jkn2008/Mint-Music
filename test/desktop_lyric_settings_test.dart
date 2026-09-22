import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/desktop_lyric_settings.dart';

void main() {
  group('DesktopLyricSettings', () {
    test('默认值与 lx-music 的 desktopLyric 默认值对齐', () {
      const s = DesktopLyricSettings.defaults;
      expect(s.enable, false);
      expect(s.isLock, false);
      expect(s.isSingleLine, false);
      expect(s.showToggleAnima, true);
      expect(s.widthPercent, 100);
      expect(s.maxLineNum, 5);
      expect(s.playedColor, 0xFF07C556);
      expect(s.unplayColor, 0xFFFFFFFF);
    });

    test('encode/decode 往返保持全部字段', () {
      final s = DesktopLyricSettings.defaults.copyWith(
        enable: true,
        isLock: true,
        isSingleLine: true,
        showToggleAnima: false,
        widthPercent: 70,
        maxLineNum: 3,
        fontSize: 24,
        opacityPercent: 60,
        textAlignX: DesktopLyricTextAlignX.center,
        textAlignY: DesktopLyricTextAlignY.bottom,
        positionX: 12.5,
        positionY: 87.5,
        playedColor: 0xFFEC4899,
        unplayColor: 0xFFBDBDBD,
        shadowColor: 0x66000000,
      );
      expect(DesktopLyricSettings.decode(s.encode()), s);
    });

    test('非法或空数据回退到默认配置', () {
      expect(
        DesktopLyricSettings.decode('not json'),
        DesktopLyricSettings.defaults,
      );
      expect(DesktopLyricSettings.decode(''), DesktopLyricSettings.defaults);
      expect(DesktopLyricSettings.decode(null), DesktopLyricSettings.defaults);
    });

    test('越界数值被夹紧到合法区间', () {
      final s = DesktopLyricSettings.fromJson({
        'widthPercent': 500,
        'maxLineNum': 0,
        'fontSize': 999,
        'opacityPercent': -20,
        'positionX': 150,
        'positionY': -30,
      });
      expect(s.widthPercent, 100);
      expect(s.maxLineNum, 1);
      expect(s.fontSize, 40);
      expect(s.opacityPercent, 10);
      expect(s.positionX, 100);
      expect(s.positionY, 0);
    });

    test('未知枚举值回退到默认对齐方式', () {
      final s = DesktopLyricSettings.fromJson({'textAlignX': 'nonsense'});
      expect(s.textAlignX, DesktopLyricTextAlignX.left);
      expect(s.textAlignY, DesktopLyricTextAlignY.top);
    });

    test('单行模式下显示行数恒为 1', () {
      final s = DesktopLyricSettings.defaults.copyWith(
        isSingleLine: true,
        maxLineNum: 5,
      );
      expect(s.visibleLineNum, 1);
      expect(s.copyWith(isSingleLine: false).visibleLineNum, 5);
    });
  });
}
