import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'animated_focus.dart';

/// A Netflix-style content card.
///
/// Displays a poster (2:3) for VOD or thumbnail (16:9) for Live/Radio,
/// with a title below. Supports focus animations for TV and hover dimming.
class NetflixCard extends StatelessWidget {
  const NetflixCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.isTv = false,
    this.contentType = 'vod',
    this.onTap,
    this.onFocusChanged,
    this.isNeighborDimmed = false,
  });

  /// Title text displayed below the image.
  final String title;

  /// URL of the poster or thumbnail image.
  final String? imageUrl;

  /// Whether this card is on a TV interface.
  final bool isTv;

  /// Content type: 'vod', 'live', or 'radio'.
  /// Determines aspect ratio (poster vs thumbnail).
  final String contentType;

  /// Callback when the card is tapped or selected.
  final VoidCallback? onTap;

  /// Called when the focus state of this card changes.
  final ValueChanged<bool>? onFocusChanged;

  /// Whether this card should appear dimmed (neighbor of a focused card on TV).
  final bool isNeighborDimmed;

  bool get _useLandscape => contentType == 'live' || contentType == 'radio';

  bool get _isTv =>
      isTv ||
      Platform.isLinux ||
      (Platform.isAndroid &&
          MediaQueryData.fromView(
                WidgetsBinding.instance.platformDispatcher.views.first,
              ).size.shortestSide >
              600);

  @override
  Widget build(BuildContext context) {
    final cardWidth = _isTv ? AppTheme.tvCardWidth : AppTheme.cardWidth;
    final aspectRatio = _useLandscape
        ? AppTheme.thumbnailAspectRatio
        : AppTheme.posterAspectRatio;

    final card = GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: isNeighborDimmed ? AppTheme.cardHoverDim : 1.0,
        duration: AppTheme.cardFocusDuration,
        child: Container(
          width: cardWidth,
          margin: const EdgeInsets.only(right: AppTheme.cardSpacing),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // -- Image ---------------------------------------------------
              AspectRatio(
                aspectRatio: aspectRatio,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.bgSurface,
                    borderRadius: BorderRadius.circular(
                      AppTheme.cardBorderRadius,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: imageUrl != null && imageUrl!.isNotEmpty
                      ? Image.network(
                          imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              _buildPlaceholder(),
                        )
                      : _buildPlaceholder(),
                ),
              ),
              const SizedBox(height: 6),

              // -- Title ---------------------------------------------------
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: AppTheme.cardTitleSize,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (_isTv) {
      return AnimatedFocus(
        isTv: true,
        onFocusChanged: onFocusChanged,
        child: Focus(
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
          child: card,
        ),
      );
    }

    return card;
  }

  Widget _buildPlaceholder() {
    final iconSize = _isTv ? 48.0 : 40.0;
    return Center(
      child: Icon(
        _useLandscape ? Icons.live_tv : Icons.movie,
        color: AppColors.bgSurface,
        size: iconSize,
      ),
    );
  }
}
