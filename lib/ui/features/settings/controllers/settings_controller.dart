import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'package:hoshi/app_build.dart';
import 'package:hoshi/data/background_downloads.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/ui/core/app_l10n.dart';

/// 设置页的备份、恢复与自动导出状态。
class SettingsController extends ChangeNotifier {
  SettingsController(this.store);

  final LocalStore store;
  bool _busy = false;
  String? _message;
  bool _disposed = false;

  bool get busy => _busy;
  String? get message => _message;

  Future<bool> exportBackup() => _run(() async {
    final content = await store.exportBackup();
    final saved = await FilePicker.saveFile(
      fileName:
          '$appSlug-backup-${DateTime.now().toIso8601String().substring(0, 10)}.json',
      bytes: Uint8List.fromList(utf8.encode(content)),
      mimeType: 'application/json',
    );
    if (saved != null) _message = AppL10n.current.backupSaved;
  });

  Future<bool> restoreBackup(String content) =>
      _run(() => store.importBackup(content));

  Future<bool> setAutoExport(bool value) => _run(() async {
    if (value) await BackgroundDownloads.ensureStarted();
    await store.setAutoExport(value);
  });

  void report(Object error) {
    _message = error.toString();
    _notify();
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (_busy || _disposed) return false;
    _busy = true;
    _message = null;
    _notify();
    var succeeded = true;
    try {
      await action();
    } catch (error) {
      succeeded = false;
      _message = error.toString();
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
