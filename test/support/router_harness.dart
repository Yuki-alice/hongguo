import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/ui/core/app_theme.dart';
import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/ui/providers/app_providers.dart';
import 'package:duanju_app/ui/routing/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 用**生产路由表**启动界面，供需要真实导航的测试使用。
///
/// 迁移到 go_router 后，页面内的 `context.push/go/replace` 要求祖先里存在
/// `GoRouter`；像以前那样 `pumpWidget(MaterialApp(home: X))` 会抛出
/// 「No GoRouter found in context」。这里复用 `routerProvider` 的同一份
/// 路由表，因此测试验证的是真实导航行为（含 `extra` 传参、深链兜底、
/// 返回栈语义），而不是一个替代实现。
///
/// [location] 为空时停在首页；否则先落到该路径。
/// [extra] 随 [location] 一起传入，用于无法从 URL 重建的对象。
Future<GoRouter> pumpRouterApp(
  WidgetTester tester, {
  required AppRepository repository,
  required LocalStore store,
  String? location,
  Object? extra,
  ThemeData? theme,
}) async {
  final container = ProviderContainer(
    overrides: [
      repositoryProvider.overrideWithValue(repository),
      storeProvider.overrideWith(() => StoreHolder(store)),
    ],
  );
  addTearDown(container.dispose);
  final router = container.read(routerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: theme ?? AppTheme.light,
        debugShowCheckedModeBanner: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (location != null && location != AppRoutes.home) {
    router.go(location, extra: extra);
    await tester.pumpAndSettle();
  }
  return router;
}
