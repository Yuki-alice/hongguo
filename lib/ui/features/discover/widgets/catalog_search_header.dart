import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

import 'package:duanju_app/ui/theme/md3_tokens.dart';
import 'package:duanju_app/ui/core/search_input.dart';

/// 发现页顶部的搜索区：搜索框 + 最近搜索 chips。
///
/// 只在需要时构建；所有取值与回调都由调用方注入，便于单独测试。
class CatalogSearchHeader extends StatelessWidget {
  const CatalogSearchHeader({
    super.key,
    required this.groupId,
    required this.controller,
    required this.hint,
    required this.recentSearches,
    required this.suggestions,
    required this.onChanged,
    required this.onSearch,
    required this.onClearRecent,
    required this.onCancelSuggestions,
  });

  final String groupId;
  final TextEditingController controller;
  final String hint;
  final List<String> recentSearches;
  final Future<List<String>> Function(String)? suggestions;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSearch;
  final VoidCallback onClearRecent;
  final VoidCallback onCancelSuggestions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Md3Spacing.lg,
            Md3Spacing.xs,
            Md3Spacing.lg,
            Md3Spacing.xs,
          ),
          child: SearchInput(
            key: ValueKey('search-$groupId'),
            controller: controller,
            autofocus: true,
            hint: hint,
            suggestions: suggestions,
            onChanged: onChanged,
            onCancel: onCancelSuggestions,
            onSearch: onSearch,
          ),
        ),
        if (controller.text.trim().isEmpty && recentSearches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Md3Spacing.lg,
              0,
              Md3Spacing.lg,
              Md3Spacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final query in recentSearches)
                          Padding(
                            padding: const EdgeInsets.only(
                              right: Md3Spacing.sm,
                            ),
                            child: ActionChip(
                              avatar: const Icon(
                                Icons.history_rounded,
                                size: 16,
                              ),
                              label: Text(query),
                              onPressed: () => onSearch(query),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: AppLocalizations.of(context).clearRecentSearches,
                  onPressed: onClearRecent,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
