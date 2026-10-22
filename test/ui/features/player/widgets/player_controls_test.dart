import 'package:hoshi/ui/features/player/widgets/player_controls.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/player/widgets/player_interactions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import '../../../../support/player_fixtures.dart';

Widget _app({
  required Widget home,
  ThemeData? theme,
  TransitionBuilder? builder,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: theme,
  builder: builder,
  home: home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('播放控件把按钮事件交给页面回调', (tester) async {
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    var toggles = 0, fullscreen = 0, next = 0, speed = 0, episodes = 0;
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      onTogglePlayback: () => toggles++,
      onFullscreen: () => fullscreen++,
      onEpisode: (_) => '',
    );
    addTearDown(interactions.dispose);

    await tester.pumpWidget(
      _app(
        home: Scaffold(
          body: PlayerControls(
            player: player,
            interactions: interactions,
            enabled: true,
            fullscreen: false,
            showOnPlaybackReady: true,
            onFullscreen: () => fullscreen++,
            onBack: () {},
            onPrevious: () {},
            onNext: () => next++,
            title: '合成播放控件',
            onTogglePlayback: () => toggles++,
            onEpisodes: () async => episodes++,
            onSpeed: () async => speed++,
            onQuality: () async {},
            speed: 1,
            qualityLabel: '自动',
            onFocusSurface: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('开始播放'));
    await tester.pump();
    expect(toggles, 1);

    await tester.tap(find.byTooltip('旋转与全屏'));
    await tester.pump();
    expect(fullscreen, 1);

    await tester.tap(find.byTooltip('下一集'));
    await tester.pump();
    expect(next, 1);

    await tester.tap(find.byTooltip('倍速'));
    await tester.pumpAndSettle();
    expect(speed, 1);
  });
}
