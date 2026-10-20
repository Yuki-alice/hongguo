import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:duanju_app/data/lan/lan_controller.dart';
import 'package:duanju_app/ui/features/lan/controllers/lan_sync_controller.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/ui/core/remote_widgets.dart';
import 'package:duanju_app/ui/routing/app_router.dart';
import 'package:duanju_app/ui/core/widgets.dart';

IconData lanDeviceIcon(String kind) => switch (kind) {
  'tv' => Icons.tv_rounded,
  'computer' => Icons.computer_rounded,
  _ => Icons.smartphone_rounded,
};

Future<T?> _lanPanel<T>(
  BuildContext context,
  Widget child, {
  double maxHeight = 740,
  bool dismissible = true,
}) {
  final size = MediaQuery.sizeOf(context);
  final height = min(size.height * .88, maxHeight);
  if (size.width >= 800) {
    return showDialog<T>(
      context: context,
      barrierDismissible: dismissible,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 620, height: height, child: child),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    isDismissible: dismissible,
    enableDrag: dismissible,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) {
      final keyboard = MediaQuery.viewInsetsOf(context).bottom;
      final available = max(
        0.0,
        MediaQuery.sizeOf(context).height -
            keyboard -
            MediaQuery.paddingOf(context).top -
            24,
      );
      return Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: SizedBox(height: min(height, available), child: child),
      );
    },
  );
}

Future<LanConnection?> chooseLanDevice(
  BuildContext context,
  LanController controller, {
  bool change = false,
}) async {
  if (!change && controller.connection != null) return controller.connection;
  return _lanPanel<LanConnection>(
    context,
    _LanDevices(controller: controller, change: change),
  );
}

void openLanSync(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  final controller = LanController.current;
  if (controller == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.lanNotReady)));
    return;
  }
  context.push(AppRoutes.lanSync);
}

class LanSyncScreen extends StatefulWidget {
  const LanSyncScreen({super.key, required this.controller});
  final LanController controller;
  @override
  State<LanSyncScreen> createState() => _LanSyncScreenState();
}

class _LanSyncScreenState extends State<LanSyncScreen> {
  AppLocalizations get l10n => AppLocalizations.of(context);
  late final LanSyncController _actions;
  LanController get link => widget.controller;

  @override
  void initState() {
    super.initState();
    ensureTelevisionFocus(context);
    _actions = LanSyncController(link: widget.controller)
      ..addListener(_actionsChanged);
  }

  @override
  void dispose() {
    _actions
      ..removeListener(_actionsChanged)
      ..dispose();
    super.dispose();
  }

  void _actionsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _perform(Future<void> Function() action) =>
      _actions.perform(action);

  Future<void> _rename() async {
    final epoch = link.store.profileEpoch;
    final name = TextEditingController(text: link.deviceName);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.lanDeviceName),
        content: TextField(
          controller: name,
          maxLength: 60,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.lanDisplayNameHint),
          onSubmitted: (_) => Navigator.pop(context, name.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    name.dispose();
    if (mounted &&
        value != null &&
        epoch == link.store.profileEpoch &&
        !link.store.locked) {
      await _perform(() => link.rename(value));
    }
  }

  Future<void> _cancel() => _actions.cancelSync();

  Future<void> _manual() async {
    final epoch = link.store.profileEpoch;
    await _perform(() async {
      await link.beginManual();
      try {
        if (mounted && epoch == link.store.profileEpoch && !link.store.locked) {
          await _lanPanel<void>(
            context,
            _LanManual(controller: link),
            dismissible: false,
          );
        }
      } finally {
        if (epoch == link.store.profileEpoch) link.endManual();
      }
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: link,
    builder: (context, _) {
      final remote = link.connection;
      int conflicts = 0;
      try {
        conflicts = link.conflictCount;
      } catch (_) {}
      final controlsEnabled =
          !_actions.busy &&
          !_actions.cancelling &&
          !link.syncing &&
          !link.store.locked;
      return Scaffold(
        appBar: AppBar(title: Text(l10n.lanSyncTitle)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                Card(
                  child: Column(
                    children: [
                      SwitchListTile.adaptive(
                        key: ValueKey('lan-enabled'),
                        title: Text(l10n.deviceInterop),
                        subtitle: Text(l10n.lanDirectHint),
                        value: link.enabled,
                        onChanged: _actions.busy || link.store.locked
                            ? null
                            : (value) => _perform(() => link.setEnabled(value)),
                      ),
                      ListTile(
                        leading: Icon(lanDeviceIcon(link.kind)),
                        title: Text(link.deviceName),
                        subtitle: Text(
                          l10n.lanLocalUser(link.store.profile.name),
                        ),
                        trailing: IconButton(
                          tooltip: l10n.lanRenameDevice,
                          onPressed: _actions.busy ? null : _rename,
                          icon: const Icon(Icons.edit_outlined),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        leading: Icon(
                          remote == null
                              ? Icons.devices_rounded
                              : lanDeviceIcon(remote.peer.kind),
                        ),
                        title: Text(
                          remote?.peer.name ?? link.connectionLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          remote == null
                              ? l10n.lanSingleAutoHint
                              : l10n.lanOtherUser + remote.user,
                        ),
                        trailing: remote == null
                            ? null
                            : PopupMenuButton<String>(
                                tooltip: l10n.lanDeviceActions,
                                onSelected: (value) => _perform(
                                  () => value == 'forget'
                                      ? link.forget(remote.peer)
                                      : link.disconnect(),
                                ),
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'disconnect',
                                    child: Text(l10n.lanDisconnect),
                                  ),
                                  PopupMenuItem(
                                    value: 'forget',
                                    child: Text(l10n.lanForgetPairing),
                                  ),
                                ],
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: OutlinedButton.icon(
                          icon: Icon(Icons.devices_other_rounded),
                          label: Text(
                            remote == null
                                ? l10n.lanSelectDevice
                                : l10n.lanSwitchDevice,
                          ),
                          onPressed: _actions.busy || link.store.locked
                              ? null
                              : () => chooseLanDevice(
                                  context,
                                  link,
                                  change: remote != null,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SwitchListTile.adaptive(
                        key: ValueKey('lan-auto-sync'),
                        title: Text(l10n.lanAutoSync),
                        subtitle: Text(l10n.lanAutoSyncHint),
                        value: link.autoSync,
                        onChanged: controlsEnabled
                            ? (value) => _perform(() => link.setAutoSync(value))
                            : null,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Semantics(
                          liveRegion: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (link.syncing) const LinearProgressIndicator(),
                              const SizedBox(height: 8),
                              Text(link.syncMessage),
                              if (link.lastSync != null)
                                Text(
                                  l10n.lanLastSync +
                                      MaterialLocalizations.of(
                                        context,
                                      ).formatTimeOfDay(
                                        TimeOfDay.fromDateTime(link.lastSync!),
                                      ),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              if (link.lastLocalCount != null)
                                Text(
                                  l10n.lanLocalLabel +
                                      link.lastLocalCount!.label,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              if (link.lastRemoteCount != null)
                                Text(
                                  l10n.lanRemoteLabel +
                                      link.lastRemoteCount!.label,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              if (link.skipped > 0)
                                Text(
                                  l10n.lanKeepOutsideRecords +
                                      link.skipped.toString(),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton.icon(
                          icon: Icon(
                            link.syncing
                                ? Icons.close_rounded
                                : Icons.sync_rounded,
                          ),
                          label: Text(
                            link.syncing ? l10n.lanCancelSync : l10n.lanSyncNow,
                          ),
                          onPressed: link.syncing
                              ? _actions.cancelling
                                    ? null
                                    : _cancel
                              : remote == null ||
                                    _actions.busy ||
                                    _actions.cancelling
                              ? null
                              : () => _perform(() => link.synchronize()),
                        ),
                      ),
                    ],
                  ),
                ),
                if (conflicts > 0)
                  Card(
                    child: ListTile(
                      leading: Icon(Icons.compare_arrows_rounded),
                      title: Text(l10n.lanConflictsPending(conflicts)),
                      subtitle: Text(l10n.lanConflictsKeptHint),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () =>
                          context.push(AppRoutes.lanConflicts, extra: link),
                    ),
                  ),
                ListTile(
                  leading: Icon(Icons.sync_alt_rounded),
                  title: Text(l10n.lanManualSync),
                  subtitle: Text(l10n.lanManualSyncHint),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  enabled: remote != null && controlsEnabled,
                  onTap: remote != null && controlsEnabled ? _manual : null,
                ),
                if ((_actions.error ?? link.error) case final message?)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (link.discoveryMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(link.discoveryMessage),
                  ),
                if (link.local != null)
                  ExpansionTile(
                    leading: Icon(Icons.info_outline_rounded),
                    title: Text(l10n.lanAddressHelp),
                    childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      Text(l10n.lanBothEnabledHint),
                      for (final address in link.local!.addresses)
                        ListTile(
                          title: SelectableText(address),
                          trailing: IconButton(
                            tooltip: l10n.lanCopyAddress,
                            icon: const Icon(Icons.copy_rounded),
                            onPressed: () =>
                                Clipboard.setData(ClipboardData(text: address)),
                          ),
                        ),
                      if (link.local!.addresses.isEmpty)
                        Text(l10n.lanNoAddress),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _LanDevices extends StatefulWidget {
  const _LanDevices({required this.controller, required this.change});
  final LanController controller;
  final bool change;
  @override
  State<_LanDevices> createState() => _LanDevicesState();
}

class _LanDevicesState extends State<_LanDevices> {
  AppLocalizations get l10n => AppLocalizations.of(context);
  final _address = TextEditingController();
  bool _busy = false;
  bool _manual = false;
  bool _selected = false;
  LanPeer? _target;
  bool _closing = false;
  String? _error;
  late final int _epoch;
  LanController get link => widget.controller;

  @override
  void initState() {
    super.initState();
    _epoch = link.store.profileEpoch;
    link.addListener(_changed);
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await link.ensureEnabled();
      if (widget.change) await link.rescan();
      _changed();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  void _changed() {
    if (!mounted) return;
    if (link.store.profileEpoch != _epoch || link.store.locked) {
      if (!_closing) {
        _closing = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.pop(context);
        });
      }
      return;
    }
    final remote = link.connection;
    if (remote != null &&
        (_selected
            ? remote.peer.id == _target?.id && remote.peer.pin == _target?.pin
            : !widget.change) &&
        !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, remote);
      });
    }
    setState(() {});
  }

  Future<void> _connect(LanPeer? peer) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _selected = true;
      _target = peer;
    });
    try {
      if (_epoch != link.store.profileEpoch || link.store.locked)
        throw StateError(l10n.lanCurrentUserChanged);
      final selected = peer ?? await link.probe(_address.text);
      if (!mounted || _epoch != link.store.profileEpoch || link.store.locked)
        return;
      _target = selected;
      await link.connect(selected);
      _changed();
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _selected = false;
          _target = null;
        });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(LanPeer peer) async {
    if (_busy || _epoch != link.store.profileEpoch || link.store.locked) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await link.forget(peer);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    link.removeListener(_changed);
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peers = [...link.peers];
    final remembered = link.remembered;
    if (remembered != null && !peers.any((peer) => peer.id == remembered.id))
      peers.add(remembered);
    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.change
                        ? l10n.lanSwitchDevice
                        : l10n.lanConnectDevice,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: l10n.lanRescan,
                  onPressed: _busy ? null : link.rescan,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  tooltip: l10n.lanClose,
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          if (link.connecting || _busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(l10n.lanDiscoveryHint),
                ),
                if (peers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Column(
                      children: [
                        const Icon(Icons.wifi_find_rounded, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          link.receiving
                              ? l10n.lanDiscovering
                              : l10n.lanEnabling,
                        ),
                        SizedBox(height: 8),
                        Text(
                          l10n.lanWaitingForeground,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                for (final peer in peers)
                  Card(
                    child: ListTile(
                      autofocus: peers.length == 1,
                      minVerticalPadding: 16,
                      leading: Icon(lanDeviceIcon(peer.kind)),
                      title: Text(
                        peer.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        link.connection?.peer.id == peer.id
                            ? l10n.lanConnected
                            : link.peers.any((found) => found.id == peer.id)
                            ? l10n.lanDeviceConnectable
                            : l10n.lanLastConnected,
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: l10n.lanDeviceActions,
                        enabled: !_busy && !link.connecting,
                        onSelected: (_) => _forget(peer),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'forget',
                            child: Text(l10n.lanForgetPairing),
                          ),
                        ],
                      ),
                      onTap: _busy || link.connecting
                          ? null
                          : () => _connect(peer),
                    ),
                  ),
                if (_error ?? link.error case final message?)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (link.discoveryMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(link.discoveryMessage),
                  ),
                TextButton.icon(
                  onPressed: () => setState(() => _manual = !_manual),
                  icon: Icon(Icons.keyboard_rounded),
                  label: Text(l10n.lanManualAddress),
                ),
                if (_manual) ...[
                  TextField(
                    controller: _address,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: l10n.lanRemoteDisplayAddress,
                      hintText: '192.168.1.8:53120',
                    ),
                    onSubmitted: (_) => _connect(null),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _busy ? null : () => _connect(null),
                    child: Text(l10n.lanConnect),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LanManual extends StatefulWidget {
  const _LanManual({required this.controller});
  final LanController controller;
  @override
  State<_LanManual> createState() => _LanManualState();
}

class _LanManualState extends State<_LanManual> {
  AppLocalizations get l10n => AppLocalizations.of(context);
  LanSyncMode _mode = LanSyncMode.merge;
  LanPreview? _preview;
  bool _busy = false;
  bool _cancelling = false;
  late final int _epoch;
  late final LanConnection? _connection;
  String? _error;
  LanController get link => widget.controller;

  @override
  void initState() {
    super.initState();
    _epoch = link.store.profileEpoch;
    _connection = link.connection;
  }

  Future<void> _cancel() async {
    if (_cancelling) return;
    setState(() => _cancelling = true);
    try {
      await link.cancelSync();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  void dispose() {
    if (_busy && _epoch == link.store.profileEpoch) {
      unawaited(link.cancelSync().catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_epoch != link.store.profileEpoch ||
          link.store.locked ||
          link.connection != _connection) {
        throw StateError(l10n.lanDeviceChanged);
      }
      if (_preview == null) {
        final preview = await link.preview(_mode);
        if (mounted) setState(() => _preview = preview);
      } else {
        await link.applyPreview(_preview!);
        if (mounted) Navigator.pop(context);
      }
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _preview = null;
        });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = link.connection?.peer.name ?? l10n.lanOtherLabel;
    return PopScope<void>(
      canPop: !_busy && !_cancelling,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.lanManualSync,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.lanClose,
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final mode in LanSyncMode.values)
                    Card(
                      color: _mode == mode
                          ? Theme.of(context).colorScheme.secondaryContainer
                          : null,
                      child: Semantics(
                        checked: _mode == mode,
                        inMutuallyExclusiveGroup: true,
                        child: ListTile(
                          autofocus: mode == LanSyncMode.merge,
                          minVerticalPadding: 16,
                          leading: Icon(
                            _mode == mode
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                          ),
                          title: Text(mode.label),
                          subtitle: Text(switch (mode) {
                            LanSyncMode.merge => l10n.lanMergeRecords(name),
                            LanSyncMode.push => l10n.lanReplaceRemote(name),
                            LanSyncMode.pull => l10n.lanReplaceLocal(name),
                          }),
                          onTap: _busy
                              ? null
                              : () => setState(() {
                                  _mode = mode;
                                  _preview = null;
                                }),
                        ),
                      ),
                    ),
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: LinearProgressIndicator(),
                    ),
                  if (_preview case final preview?)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.lanSyncPreview,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            SizedBox(height: 12),
                            Text(l10n.lanLocalDevice(link.store.profile.name)),
                            Text(preview.localCount.label),
                            const SizedBox(height: 12),
                            Text(name + ' · ' + preview.connection.user),
                            Text(preview.remoteCount.label),
                            if (preview.skipped > 0)
                              Padding(
                                padding: EdgeInsets.only(top: 12),
                                child: Text(
                                  l10n.lanScopeOutside +
                                      preview.skipped.toString() +
                                      l10n.lanRecordsKept,
                                ),
                              ),
                            if (_mode != LanSyncMode.merge)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Text(
                                  _mode == LanSyncMode.push
                                      ? l10n.lanReplaceRemoteShort(name) +
                                            preview.remoteCount.removed
                                                .toString() +
                                            l10n.lanFollowsSuffix
                                      : l10n.lanReplaceLocalShort +
                                            preview.localCount.removed
                                                .toString() +
                                            l10n.lanFollowsSuffix,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: _busy || _cancelling
                  ? OutlinedButton.icon(
                      onPressed: _cancelling ? null : _cancel,
                      icon: Icon(Icons.close_rounded),
                      label: Text(
                        _cancelling ? l10n.lanCancelling : l10n.lanCancelSync,
                      ),
                    )
                  : FilledButton(
                      onPressed: _submit,
                      child: Text(
                        _preview == null
                            ? l10n.lanViewPreview
                            : _mode == LanSyncMode.merge
                            ? l10n.lanStartSync
                            : _mode.label,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 处理记录冲突页。
///
/// 从路由表进入，因此不能再是私有类；控制器是运行期单例，
/// 通过 go_router 的 `extra` 传入。
class LanConflictsScreen extends StatelessWidget {
  const LanConflictsScreen({super.key, required this.controller});
  final LanController controller;

  String _value(String field, Object? value, AppLocalizations l10n) {
    if (field == 'member') {
      return value == true ? l10n.lanKeepFollow : l10n.lanCancelFollow;
    }
    if (value == null) return l10n.lanClearResume;
    final row = lanMap(value);
    if (field == 'status') {
      return switch (row['status']) {
        'planned' => l10n.lanPlanned,
        'watching' => l10n.lanWatching,
        _ => row['manual'] == true ? l10n.lanWatchedManual : l10n.lanWatched,
      };
    }
    return l10n.lanEpisodePrefix +
        row['episode'].toString() +
        l10n.lanEpisodeSeparator +
        formatPosition((row['position'] as num).toDouble());
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller.store,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final records = controller.store.locked
          ? <LanRecord>[]
          : controller.store.lanDocument.records.values
                .where(
                  (record) =>
                      record.conflicts > 0 &&
                      controller.store.allowsSource(record.drama.source),
                )
                .toList();
      return Scaffold(
        appBar: AppBar(title: Text(l10n.lanConflictsTitle)),
        body: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 720),
            child: records.isEmpty
                ? Center(child: Text(l10n.lanNoConflicts))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: records.length,
                    itemBuilder: (context, index) {
                      final record = records[index];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                record.drama.title,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              for (final field in record.fields.entries.where(
                                (field) => field.value.conflict,
                              )) ...[
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: 16,
                                    bottom: 4,
                                  ),
                                  child: Text(switch (field.key) {
                                    'member' => l10n.lanFollowList,
                                    'status' => l10n.lanWatchStatus,
                                    _ => l10n.lanResumeProgress,
                                  }),
                                ),
                                for (final candidate in field.value.values)
                                  ListTile(
                                    leading: const Icon(
                                      Icons.radio_button_unchecked_rounded,
                                    ),
                                    title: Text(
                                      _value(field.key, candidate.value, l10n),
                                    ),
                                    subtitle: Text(l10n.lanUseRecord),
                                    onTap: () =>
                                        saveUserChange(context, () async {
                                          await controller.store
                                              .resolveLanConflict(
                                                record.id,
                                                field.key,
                                                candidate,
                                                record.hash,
                                              );
                                          controller.flush();
                                        }),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      );
    },
  );
}

class LanPushButton extends StatelessWidget {
  const LanPushButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final link = LanController.current;
    if (link == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: link,
      builder: (context, _) => IconButton(
        tooltip: link.connection == null
            ? l10n.lanPush
            : l10n.lanPushTo + link.connection!.peer.name,
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        padding: EdgeInsets.zero,
        iconSize: 22,
        icon: link.pushing
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                link.connection == null
                    ? Icons.cast_rounded
                    : Icons.cast_connected_rounded,
              ),
      ),
    );
  }
}

Future<void> showLanPush(
  BuildContext context,
  LanController link, {
  required LanPlaybackIntent Function() snapshot,
  required bool Function() stillCurrent,
  required Future<void> Function() onAccepted,
}) async {
  final remote = await chooseLanDevice(context, link);
  if (remote == null || !context.mounted || !stillCurrent()) return;
  await _lanPanel<void>(
    context,
    _LanPushPanel(
      controller: link,
      snapshot: snapshot,
      stillCurrent: stillCurrent,
      onAccepted: onAccepted,
    ),
    maxHeight: 560,
  );
  if (link.pushing) await link.cancelPush();
}

class _LanPushPanel extends StatefulWidget {
  const _LanPushPanel({
    required this.controller,
    required this.snapshot,
    required this.stillCurrent,
    required this.onAccepted,
  });
  final LanController controller;
  final LanPlaybackIntent Function() snapshot;
  final bool Function() stillCurrent;
  final Future<void> Function() onAccepted;
  @override
  State<_LanPushPanel> createState() => _LanPushPanelState();
}

class _LanPushPanelState extends State<_LanPushPanel> {
  AppLocalizations get l10n => AppLocalizations.of(context);
  bool _done = false;
  bool _success = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted) return;
    try {
      await widget.controller.pushPlayback(
        snapshot: widget.snapshot,
        stillCurrent: () => mounted && widget.stillCurrent(),
        onAccepted: widget.onAccepted,
        confirmReplace: (title) async {
          if (!mounted) return false;
          return await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(l10n.lanSwitchRemoteTitle),
                  content: Text(l10n.lanSwitchRemoteBody(title)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(l10n.cancel),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(l10n.lanPushPlay),
                    ),
                  ],
                ),
              ) ??
              false;
        },
      );
      _success = true;
    } catch (_) {
    } finally {
      if (mounted) setState(() => _done = true);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              l10n.lanPushPlay,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(
                    _success
                        ? Icons.cast_connected_rounded
                        : Icons.cast_rounded,
                    size: 64,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    widget.snapshot().drama.title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  SizedBox(height: 12),
                  Text(
                    l10n.lanReceiveDevice +
                        (widget.controller.connection?.peer.name ??
                            l10n.lanConnectionLost),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (!_done) const LinearProgressIndicator(),
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      widget.controller.pushMessage,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (!_done)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        l10n.lanAutoPauseHint,
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: () async {
                if (!_done) await widget.controller.cancelPush();
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(_done ? l10n.lanComplete : l10n.lanCancelPush),
            ),
          ),
        ],
      ),
    ),
  );
}
