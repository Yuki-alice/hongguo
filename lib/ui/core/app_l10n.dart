import 'package:flutter/widgets.dart';

import 'package:hoshi/l10n/generated/app_localizations.dart';

/// 数据层/控制器使用的同步本地化入口。
///
/// 页面在 `MaterialApp.builder` 中写入当前实例；单元测试没有 Widget 环境时
/// 回退到中文，保证控制器仍可直接测试。
abstract final class AppL10n {
  static AppLocalizations? _current;

  static set current(AppLocalizations value) => _current = value;

  static AppLocalizations get current =>
      _current ?? lookupAppLocalizations(const Locale('zh'));
}
