import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/config/tv_mode.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/animated_focus.dart';
import '../../../core/widgets/favorite_button.dart';

/// Individual content card showing thumbnail/poster and title.
///
/// Used in horizontal scrollable rows on the home screen.
class ContentCard extends StatelessWidget {
  const ContentCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.isTv = false,
    this.onTap,
    this.autofocus = false,
    this.focusNode,
    this.contentId,
    this.contentType,
    this.url,
  });

  final String title;
  final String? imageUrl;
  final bool isTv;
  final VoidCallback? onTap;
  final bool autofocus;

  /// Focus node to attach to the card's TV focus wrapper, allowing the
  /// parent to request focus on this card programmatically.
  final FocusNode? focusNode;

  /// Polymorphic ID for favourites (e.g. `"vod:42"`).
  final String? contentId;

  /// Content type for favourites (`"live"`, `"vod"`, `"series"`).
  final String? contentType;

  /// Stream URL for favourites.
  final String? url;

  /// Whether this card should render with TV focus behaviour.
  ///
  /// True when the caller explicitly passes [isTv] OR when the shared
  /// [TvMode] single source of truth is enabled (replaces the old
  /// shortestSide > 600 device heuristic).
  bool _resolveIsTv(BuildContext context) => isTv || TvModeScope.of(context);

  @override
  Widget build(BuildContext context) {
    final card = GestureDetector(
      onTap: onTap,
      child: Container(
        width: 140,
        margin: const EdgeInsets.only(right: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // -- Thumbnail / poster with favourite button -------------------
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.bgSurface,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: imageUrl != null && imageUrl!.isNotEmpty
                        ? Image.network(
                            imageUrl!,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            errorBuilder: (context, error, stackTrace) =>
                                _buildPlaceholder(),
                          )
                        : _buildPlaceholder(),
                  ),
                  // -- Favourite heart (top-right) -------------------------
                  if (contentId != null && contentType != null)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: AppColors.bgBase.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: FavoriteButton(
                          contentId: contentId!,
                          contentType: contentType!,
                          title: title,
                          poster: imageUrl,
                          url: url,
                          size: 16,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // -- Title ------------------------------------------------------
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );

    if (_resolveIsTv(context)) {
      return AnimatedFocus(
        isTv: true,
        child: Focus(
          autofocus: autofocus,
          focusNode: focusNode,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent || event is KeyRepeatEvent) {
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.select ||
                  key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.space ||
                  key == LogicalKeyboardKey.gameButtonA) {
                onTap?.call();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            onTap: onTap,
            child: card,
          ),
        ),
      );
    }

    return card;
  }

  Widget _buildPlaceholder() {
    return const Center(
      child: Icon(
        Icons.movie,
        color: AppColors.bgSurface,
        size: 40,
      ),
    );
  }
}
