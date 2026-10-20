import 'package:flutter/foundation.dart';

import 'package:duanju_app/data/local_profiles.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/ui/core/app_l10n.dart';

/// 用户编辑器的保存 / 删除状态。
class ProfileEditorController extends ChangeNotifier {
  ProfileEditorController({required this.store, this.profile});

  final LocalStore store;
  final LocalProfile? profile;
  bool _busy = false;
  String? _error;
  bool _disposed = false;

  bool get busy => _busy;
  String? get error => _error;

  Future<bool> save({
    required String name,
    required List<String> sources,
    required bool download,
    required String pin,
    required String confirmPin,
    required bool clearPin,
  }) => _run(() async {
    if (pin != confirmPin) throw StateError(AppL10n.current.pinMismatch);
    await store.saveProfile(
      id: profile?.id,
      name: name,
      sources: sources,
      download: download,
      pin: clearPin
          ? ''
          : pin.isEmpty
          ? null
          : pin,
    );
  });

  Future<bool> delete() => _run(() async {
    final current = profile;
    if (current == null) return;
    await store.deleteProfile(current.id);
  });

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
