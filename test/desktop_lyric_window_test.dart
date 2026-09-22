import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/features/player/domain/models/desktop_lyric_settings.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';
import 'package:mintmusic/features/player/presentation/desktop_lyric_window.dart';

Widget _host(Widget child) {
  return MaterialApp(
    home: L10n(
      locale: AppLocale.zhCn,
      child: Scaffold(
        body: SizedBox.expand(
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                width: 360,
                height: 220,
                child: child,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

List<LyricLine> _sampleLines() => [
  LyricLine(
    startTimeMs: 0,
    endTimeMs: 1000,
    words: const [LyricWord(word: '第一行歌词', startTimeMs: 0, endTimeMs: 500)],
    translatedLyric: 'the first line',
  ),
  LyricLine(
    startTimeMs: 1000,
    endTimeMs: 2000,
    words: const [
      LyricWord(word: '第二行歌词', startTimeMs: 1000, endTimeMs: 1500),
    ],
  ),
  LyricLine(
    startTimeMs: 2000,
    endTimeMs: 3000,
    words: const [
      LyricWord(word: '第三行歌词', startTimeMs: 2000, endTimeMs: 2500),
    ],
  ),
];

void main() {
  testWidgets('多行模式渲染当前行、译文和后续行', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults.copyWith(maxLineNum: 3),
          lines: _sampleLines(),
          activeIndex: 0,
          songId: 'song-1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一行歌词'), findsOneWidget);
    expect(find.text('the first line'), findsOneWidget);
    expect(find.text('第二行歌词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('显示行数限制渲染的行数', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults.copyWith(
            maxLineNum: 1,
            showToggleAnima: false,
          ),
          lines: _sampleLines(),
          activeIndex: 0,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('第一行歌词'), findsOneWidget);
    expect(find.text('第二行歌词'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单行模式只渲染当前行', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults.copyWith(
            isSingleLine: true,
            showToggleAnima: false,
          ),
          lines: _sampleLines(),
          activeIndex: 1,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('第二行歌词'), findsOneWidget);
    expect(find.text('第一行歌词'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('面板不再自带拖动把手', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults.copyWith(
            isLock: true,
            showToggleAnima: false,
          ),
          lines: _sampleLines(),
          activeIndex: 0,
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    expect(find.text('第一行歌词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动把手渲染拖拽图标', (tester) async {
    await tester.pumpWidget(_host(const DesktopLyricHandle()));
    await tester.pump();

    expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('歌词区不吞掉下层页面的点击，把手区可用于拖动', (tester) async {
    var tappedBehind = false;
    await tester.pumpWidget(
      MaterialApp(
        home: L10n(
          locale: AppLocale.zhCn,
          child: Scaffold(
            body: SizedBox.expand(
              child: Stack(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => tappedBehind = true,
                    child: const SizedBox.expand(
                      child: ColoredBox(color: Colors.blue),
                    ),
                  ),
                  // 与 DesktopLyricWindow 相同的命中测试结构:
                  // 背景+歌词整体 IgnorePointer,只有顶部把手可交互。
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 360,
                    height: 220,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const SizedBox(
                                    height: DesktopLyricHandle.height,
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: DesktopLyricPanel.padding,
                                        vertical: 4,
                                      ),
                                      child: DesktopLyricPanel(
                                        settings: DesktopLyricSettings.defaults
                                            .copyWith(showToggleAnima: false),
                                        lines: _sampleLines(),
                                        activeIndex: 0,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: DesktopLyricHandle.height,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {},
                            child: const DesktopLyricHandle(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 歌词区:点击应穿透到下层。
    await tester.tapAt(const Offset(180, 120));
    await tester.pump();
    expect(tappedBehind, isTrue);

    // 把手区:点击被把手消费,不会穿透。
    tappedBehind = false;
    await tester.tapAt(const Offset(180, 8));
    await tester.pump();
    expect(tappedBehind, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有歌词时显示占位文案', (tester) async {
    await tester.pumpWidget(
      _host(
        DesktopLyricPanel(
          settings: DesktopLyricSettings.defaults,
          lines: const [],
          activeIndex: -1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无歌词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
