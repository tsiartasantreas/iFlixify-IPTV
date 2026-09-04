import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import 'content_card.dart';

/// A single row showing a label and horizontally scrollable content items.
///
/// Used on the home screen to display sections like "Live TV", "Movies", etc.
class ContentRow extends StatelessWidget {
  const ContentRow({
    super.key,
    required this.label,
    required this.items,
    this.isTv = false,
    this.onSeeAll,
    this.autofocusFirst = false,
    this.firstCardFocusNode,
  });

  /// Section header label (e.g. "Live TV").
  final String label;

  /// List of content items to display horizontally.
  final List<ContentItem> items;

  /// Whether this is a TV layout (enables D-pad focus).
  final bool isTv;

  /// Callback when the "See All" header is tapped.
  final VoidCallback? onSeeAll;

  /// Whether the first card in this row should auto-focus (for TV D-pad).
  final bool autofocusFirst;

  /// Focus node attached to the first card, so the parent can re-request
  /// TV focus on it programmatically (e.g. after a pushed route pops).
  final FocusNode? firstCardFocusNode;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // -- Section header -------------------------------------------------
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (onSeeAll != null)
                TextButton(
                  onPressed: onSeeAll,
                  child: const Text(
                    'See All',
                    style: TextStyle(
                      color: AppColors.accentPrimary,
                      fontSize: 14,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // -- Horizontal scrollable row --------------------------------------
        SizedBox(
          height: 230,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return ContentCard(
                title: item.title,
                imageUrl: item.imageUrl,
                isTv: isTv,
                autofocus: autofocusFirst && index == 0,
                focusNode: index == 0 ? firstCardFocusNode : null,
                onTap: item.onTap,
                contentId: item.contentId,
                contentType: item.contentType,
                url: item.url,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A content item for use in [ContentRow].
class ContentItem {
  const ContentItem({
    required this.title,
    this.imageUrl,
    required this.onTap,
    this.contentId,
    this.contentType,
    this.url,
  });

  final String title;
  final String? imageUrl;
  final VoidCallback onTap;

  /// Polymorphic ID for favourites (e.g. `"vod:42"`).
  final String? contentId;

  /// Content type for favourites (`"live"`, `"vod"`, `"series"`).
  final String? contentType;

  /// Stream URL for favourites.
  final String? url;
}
