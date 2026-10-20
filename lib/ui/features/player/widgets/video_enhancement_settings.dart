import 'package:flutter/material.dart';

import 'package:duanju_app/ui/core/remote_widgets.dart';
import 'package:duanju_app/data/video_enhancement/video_enhancement.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/domain/video_enhancement_preferences.dart';

String _modeLabel(VideoEnhancementMode mode, AppLocalizations l10n) =>
    switch (mode) {
      VideoEnhancementMode.off => l10n.enhancementOff,
      VideoEnhancementMode.automatic => l10n.enhancementAutomatic,
      VideoEnhancementMode.economy => l10n.enhancementEconomy,
      VideoEnhancementMode.quality => l10n.enhancementQuality,
    };

String _contentLabel(VideoEnhancementContent content, AppLocalizations l10n) =>
    switch (content) {
      VideoEnhancementContent.automatic => l10n.contentAutomatic,
      VideoEnhancementContent.general => l10n.contentGeneral,
      VideoEnhancementContent.animation => l10n.contentAnimation,
    };

class VideoEnhancementSettings extends StatelessWidget {
  const VideoEnhancementSettings({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onCompare,
    this.television = false,
    this.busy = false,
  });

  final VideoEnhancementController controller;
  final ValueChanged<VideoEnhancementPreferences> onChanged;
  final VoidCallback onCompare;
  final bool television;
  final bool busy;

  Widget _choice({
    required String id,
    required String label,
    required bool selected,
    required VoidCallback action,
    bool enabled = true,
  }) => television
      ? RemoteButton(
          key: ValueKey(id),
          label: label,
          selected: selected,
          onPressed: busy || !enabled ? null : action,
        )
      : ChoiceChip(
          key: ValueKey(id),
          label: Text(label),
          selected: selected,
          onSelected: busy || !enabled ? null : (_) => action(),
        );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final preferences = controller.preferences;
      final colors = Theme.of(context).colorScheme;
      final helperStyle = TextStyle(
        fontSize: 13,
        color: colors.onSurfaceVariant,
        height: 1.5,
      );
      final enabled = preferences.mode != VideoEnhancementMode.off;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.enhancementTitle,
            style: television ? const TextStyle(fontSize: 18) : null,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mode in VideoEnhancementMode.values)
                _choice(
                  id: 'enhancement-mode-${mode.name}',
                  label: _modeLabel(mode, l10n),
                  selected: preferences.mode == mode,
                  enabled:
                      controller.supported || mode == VideoEnhancementMode.off,
                  action: () => onChanged(preferences.copyWith(mode: mode)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            enabled ? l10n.enhancementModeHint : l10n.enhancementOffHint,
            style: helperStyle,
          ),
          if (enabled) ...[
            const SizedBox(height: 16),
            Text(l10n.contentType),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final content in VideoEnhancementContent.values)
                  _choice(
                    id: 'enhancement-content-${content.name}',
                    label: _contentLabel(content, l10n),
                    selected: preferences.content == content,
                    enabled: controller.supported,
                    action: () =>
                        onChanged(preferences.copyWith(content: content)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              preferences.content == VideoEnhancementContent.automatic
                  ? l10n.enhancementContentHint(controller.contentLabel)
                  : l10n.enhancementAnimeHint,
              style: helperStyle,
            ),
            const SizedBox(height: 12),
            Text(controller.status, key: const ValueKey('enhancement-status')),
            if (controller.detail.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(controller.detail, style: helperStyle),
            ],
            const SizedBox(height: 8),
            if (television)
              RemoteButton(
                key: const ValueKey('enhancement-compare'),
                label: controller.comparing
                    ? l10n.restoreEnhancement
                    : l10n.compareOriginal,
                icon: Icons.compare_rounded,
                onPressed: controller.canCompare && !busy ? onCompare : null,
              )
            else
              OutlinedButton.icon(
                key: const ValueKey('enhancement-compare'),
                onPressed: controller.canCompare && !busy ? onCompare : null,
                icon: const Icon(Icons.compare_rounded),
                label: Text(
                  controller.comparing
                      ? l10n.restoreEnhancement
                      : l10n.compareOriginal,
                ),
              ),
          ] else if (!controller.supported) ...[
            const SizedBox(height: 12),
            Text(controller.status, key: const ValueKey('enhancement-status')),
          ],
          const SizedBox(height: 20),
        ],
      );
    },
  );
}
