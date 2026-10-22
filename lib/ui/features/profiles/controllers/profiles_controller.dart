import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'package:hoshi/ui/core/app_l10n.dart';

import 'package:hoshi/app_build.dart';
import 'package:hoshi/data/local_profiles.dart';
import 'package:hoshi/data/local_store.dart';

/// 用户管理页的数据操作状态。
///
/// 文件选择与确认对话框仍由页面负责，这里只承接仓库调用、
/// 忙碌标记与错误提示。
class ProfilesController extends ChangeNotifier {
  ProfilesController(this.store);

  final LocalStore store;
  bool _busy = false;
  String? _error;
  bool _disposed = false;

  bool get busy => _busy;
  String? get error => _error;

  Future<bool> reload() => _run(store.reload);

  Future<String?> pickBackup() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (file == null) return null;
    final size = await file.length();
    if (size == null || size > 8 * 1024 * 1024) {
      throw FormatException(AppL10n.current.backupTooLarge);
    }
    final content = utf8.decode(await file.readAsBytes());
    store.validateBackup(content);
    return content;
  }

  void report(Object error) {
    _error = error.toString();
    _notify();
  }

  Future<bool> exportRecovery() => _run(() async {
    await FilePicker.saveFile(
      fileName: '$appSlug-recovery.json',
      bytes: Uint8List.fromList(utf8.encode(store.exportRecoveryData())),
      mimeType: 'application/json',
    );
  });

  Future<bool> recoverBackup(String content, {required String pin}) =>
      _run(() => store.recoverBackup(content, pin: pin));

  Future<bool> switchProfile(LocalProfile profile, {String pin = ''}) =>
      _run(() => store.switchProfile(profile.id, pin: pin));

  Future<bool> setForceLogin(bool value) =>
      _run(() => store.setForceLogin(value));

  Future<bool> _run(Future<void> Function() action) async {
    if (_busy || _disposed) return false;
    _busy = true;
    _error = null;
    _notify();
    var succeeded = true;
    try {
      await action();
    } catch (error) {
      succeeded = false;
      _error = error.toString();
    } finally {
      _busy = false;
      _notify();
    }
    return succeeded;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
