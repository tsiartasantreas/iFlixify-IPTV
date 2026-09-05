import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/animated_focus.dart';

/// A content card for Continue Watching items with a progress bar.
///
/// Displays the thumbnail/poster, title, subtitle, and a thin progress
/// indicator showing how much of the content has been watched.
class ContinueWatchingCard extends StatelessWidget {
  const ContinueWatchingCard({
    super.key,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.progress = 0,
    this.onTap,
  });

  final String title;

  /// Optional subtitle (e.g. "S1:E3 - Episode Title" for series).
  final String? subtitle;

  final String? imageUrl;

  /// Playback progress as a value between 0.0 and 1.0.
  final double progress;

  final VoidCallback? onTap;

  bool get _isTv =>
      Platform.isLinux ||
      (Platform.isAndroid &&
          MediaQueryData.fromView(
                WidgetsBinding.instance.platformDispatcher.views.first,
              ).size.shortestSide >
              600);

  @override
  Widget build(BuildContext context) {
    final card = GestureDetector(
      onTap: onTap,
      child: Container(
        width: 160,
        margin: const EdgeInsets.only(right: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // -- Thumbnail / poster -----------------------------------------
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.bgSurface,
                  borderRadius: BorderRadius.circular(6),
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

            // -- Progress bar ------------------------------------------------
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(6),
              ),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: AppColors.bgSurface,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppColors.accentPrimary,
                ),
              ),
            ),
            const SizedBox(height: 6),

            // -- Title -------------------------------------------------------
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),

            // -- Subtitle (optional) -----------------------------------------
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    if (_isTv) {
      return AnimatedFocus(
        isTv: true,
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
    return const Center(
      child: Icon(Icons.movie, color: AppColors.bgSurface, size: 40),
    );
  }
}
