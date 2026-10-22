import 'package:hoshi/data/lan/lan_controller.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/lan/views/lan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('同步页展示设备、自动同步与手动同步入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final controller = LanController(FixtureRepository(), store, kind: 'phone');
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LanSyncScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('追剧同步'), findsOneWidget);
    expect(find.text('设备互联'), findsOneWidget);
    expect(find.text('自动同步'), findsOneWidget);
    expect(find.text('手动同步'), findsOneWidget);
    expect(find.text('本机用户 · ${store.profile.name}'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });
}
