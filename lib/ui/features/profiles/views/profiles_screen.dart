import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/app_build.dart';
import 'package:hoshi/data/local_profiles.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:hoshi/ui/features/profiles/controllers/profile_editor_controller.dart';
import 'package:hoshi/ui/features/profiles/controllers/profiles_controller.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({super.key, required this.store, this.locked = false});
  final LocalStore store;
  final bool locked;
  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  late final ProfilesController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ProfilesController(widget.store);
    ensureTelevisionFocus(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _recover({bool export = false, bool reload = false}) async {
    final l10n = AppLocalizations.of(context);
    if (export) {
      await _controller.exportRecovery();
      return;
    }
    if (reload) {
      await _controller.reload();
      return;
    }
    try {
      final content = await _controller.pickBackup();
      if (content == null || !mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.restoreProfilesTitle),
          content: Text(l10n.restoreProfilesBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.continueRestore),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      final pin = await showDialog<String>(
        context: context,
        builder: (_) => _PasswordDialog(name: l10n.adminBackupPassword),
      );
      if (pin == null || !mounted) return;
      await _controller.recoverBackup(content, pin: pin);
    } catch (error) {
      _controller.report(error);
    }
  }

  Future<void> _switch(LocalProfile profile) async {
    String pin = '';
    if (profile.protected) {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => _PasswordDialog(name: profile.name),
      );
      if (value == null || !mounted) return;
      pin = value;
    }
    final switched = await _controller.switchProfile(profile, pin: pin);
    if (switched && mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  Future<void> _edit([LocalProfile? profile]) async {
    // 编辑器用 `Navigator.pop` 关闭，因此用 `push` 等待其返回；
    // 保存结果通过 LocalStore 通知刷新列表。
    await context.push(
      AppRoutes.profileEditor,
      extra: ProfileEditorExtra(profile),
    );
  }

  Future<void> _setForceLogin(bool value) => _controller.setForceLogin(value);

  String _permissionsLabel(LocalProfile profile, AppLocalizations l10n) {
    if (profile.admin) return l10n.permissionsAdmin;
    final sources = profile.sources
        .where(SourceSite.isAvailable)
        .map((id) => SourceSite.byId(id).name)
        .join(' / ');
    return '${sources.isEmpty ? l10n.noSources : sources} · '
        '${profile.download ? l10n.downloadAllowed : l10n.onlineOnly}';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.store, _controller]),
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.locked ? l10n.unlockApp(appName) : l10n.userManagement,
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Md3Spacing.contentMaxWidth),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (widget.store.configurationError != null) ...[
                  Text(
                    l10n.recoverLocalConfig,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(widget.store.configurationError!),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _controller.busy ? null : () => _recover(),
                    icon: const Icon(Icons.restore_rounded),
                    label: Text(l10n.restoreFromBackup),
                  ),
                  OutlinedButton(
                    onPressed: _controller.busy
                        ? null
                        : () => _recover(export: true),
                    child: Text(l10n.exportOriginalConfig),
                  ),
                  TextButton(
                    onPressed: _controller.busy
                        ? null
                        : () => _recover(reload: true),
                    child: Text(l10n.reloadConfig),
                  ),
                ] else ...[
                  Text(
                    widget.locked
                        ? l10n.chooseUserAndPin
                        : l10n.currentUser(widget.store.profile.name),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(l10n.profilesIsolationHint),
                  if (!widget.store.locked && widget.store.profile.admin) ...[
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.requireLoginOnStartup),
                      subtitle: Text(
                        widget.store.forceLogin
                            ? l10n.requireLoginOnSubtitle
                            : l10n.requireLoginOffSubtitle,
                      ),
                      value: widget.store.forceLogin,
                      onChanged: _controller.busy ? null : _setForceLogin,
                    ),
                  ],
                ],
                if (_controller.busy)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  ),
                if (_controller.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _controller.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                for (final profile
                    in widget.store.configurationError == null
                        ? widget.store.profiles
                        : <LocalProfile>[])
                  Card(
                    child: ListTile(
                      leading: Icon(
                        profile.admin
                            ? Icons.admin_panel_settings_outlined
                            : Icons.person_outline,
                      ),
                      title: Text(profile.name),
                      subtitle: Text(_permissionsLabel(profile, l10n)),
                      onTap: _controller.busy ? null : () => _switch(profile),
                      trailing:
                          !widget.store.locked && widget.store.profile.admin
                          ? IconButton(
                              tooltip: l10n.editUser,
                              onPressed: _controller.busy
                                  ? null
                                  : () => _edit(profile),
                              icon: const Icon(Icons.edit_outlined),
                            )
                          : Icon(
                              profile.protected
                                  ? Icons.lock_outline
                                  : Icons.chevron_right,
                            ),
                    ),
                  ),
                if (!widget.store.locked && widget.store.profile.admin) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _controller.busy ? null : () => _edit(),
                    icon: const Icon(Icons.person_add_outlined),
                    label: Text(l10n.addUser),
                  ),
                ],
                if (!widget.store.locked && widget.store.profile.protected)
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                      widget.store.lock();
                    },
                    icon: const Icon(Icons.lock_outline),
                    label: Text(l10n.lockCurrentUser),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.name});
  final String name;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _pin = TextEditingController();
  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.loginTitle(widget.name)),
      content: TextField(
        controller: _pin,
        autofocus: true,
        obscureText: true,
        decoration: InputDecoration(labelText: l10n.password),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _pin.text),
          child: Text(l10n.login),
        ),
      ],
    );
  }
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, required this.store, this.profile});
  final LocalStore store;
  final LocalProfile? profile;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late final _name = TextEditingController(text: widget.profile?.name ?? '');
  final _pin = TextEditingController(), _confirm = TextEditingController();
  late final _sources =
      (widget.profile?.sources ?? SourceSite.values.map((s) => s.id).toList())
          .toSet();
  late bool _download = widget.profile?.download ?? true;
  bool _clearPin = false;
  late final ProfileEditorController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ProfileEditorController(
      store: widget.store,
      profile: widget.profile,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    _confirm.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final saved = await _controller.save(
      name: _name.text,
      sources: _sources.toList(),
      download: _download,
      pin: _pin.text,
      confirmPin: _confirm.text,
      clearPin: _clearPin,
    );
    if (saved && mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteUserTitle),
        content: Text(l10n.deleteUserBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final deleted = await _controller.delete();
    if (deleted && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.profile == null ? l10n.addUser : l10n.editUser),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Md3Spacing.contentMaxWidth),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                TextField(
                  controller: _name,
                  maxLength: 40,
                  decoration: InputDecoration(labelText: l10n.username),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pin,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: l10n.setPassword,
                    helperText: l10n.keepPasswordHint,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirm,
                  obscureText: true,
                  decoration: InputDecoration(labelText: l10n.confirmPassword),
                ),
                if (widget.profile?.protected == true &&
                    widget.profile?.admin != true)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.clearUserPin),
                    value: _clearPin,
                    onChanged: (v) => setState(() => _clearPin = v!),
                  ),
                const SizedBox(height: 20),
                if (widget.profile?.admin != true) ...[
                  Text(
                    l10n.allowedSources,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final source in SourceSite.values)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(source.name),
                      value: _sources.contains(source.id),
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            _sources.add(source.id);
                          } else {
                            _sources.remove(source.id);
                          }
                        });
                      },
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.allowDownloads),
                    subtitle: Text(
                      _download
                          ? l10n.downloadAllowedSubtitle
                          : l10n.onlineOnlySubtitle,
                    ),
                    value: _download,
                    onChanged: (v) => setState(() => _download = v),
                  ),
                ] else
                  Text(l10n.adminHint),
                if (_controller.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      _controller.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _controller.busy ? null : _save,
                  child: Text(_controller.busy ? l10n.saving : l10n.save),
                ),
                if (widget.profile != null && !widget.profile!.admin)
                  TextButton(
                    onPressed: _controller.busy ? null : _delete,
                    child: Text(l10n.deleteUser),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
