import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// A full-screen Netflix-style hero banner.
///
/// Features:
/// - Full-bleed backdrop image (or gradient placeholder).
/// - Gradient scrim from bottom to top.
/// - Large title, synopsis text, and Play / My List buttons.
/// - Auto-crossfade between featured items every 8 seconds.
/// - Mobile: ~60% viewport height; TV: ~70%.
class NetflixHero extends StatefulWidget {
  const NetflixHero({super.key, required this.items, this.isTv = false});

  /// List of featured items to rotate through.
  final List<NetflixHeroItem> items;

  /// Whether this is a TV layout.
  final bool isTv;

  @override
  State<NetflixHero> createState() => _NetflixHeroState();
}

class _NetflixHeroState extends State<NetflixHero> {
  int _currentIndex = 0;
  Timer? _autoRotateTimer;

  bool get _isTv =>
      widget.isTv ||
      Platform.isLinux ||
      (Platform.isAndroid &&
          MediaQueryData.fromView(
                WidgetsBinding.instance.platformDispatcher.views.first,
              ).size.shortestSide >
              960);

  @override
  void initState() {
    super.initState();
    _startAutoRotate();
  }

  @override
  void dispose() {
    _autoRotateTimer?.cancel();
    super.dispose();
  }

  void _startAutoRotate() {
    _autoRotateTimer?.cancel();
    _autoRotateTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted && widget.items.length > 1) {
        setState(() {
          _currentIndex = (_currentIndex + 1) % widget.items.length;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final item = widget.items[_currentIndex];
    final screenHeight = MediaQuery.of(context).size.height;
    final heroHeight = _isTv ? screenHeight * 0.70 : screenHeight * 0.60;

    return SizedBox(
      height: heroHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // -- Backdrop image with crossfade -------------------------------
          AnimatedSwitcher(
            duration: AppTheme.heroCrossfadeDuration,
            transitionBuilder: (child, animation) {
              return FadeTransition(opacity: animation, child: child);
            },
            child: KeyedSubtree(
              key: ValueKey(_currentIndex),
              child: item.imageUrl != null && item.imageUrl!.isNotEmpty
                  ? Image.network(
                      item.imageUrl!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (context, error, stackTrace) =>
                          _buildGradientPlaceholder(),
                    )
                  : _buildGradientPlaceholder(),
            ),
          ),

          // -- Bottom gradient scrim (dark at bottom, transparent at top) ---
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: heroHeight * 0.6,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, AppColors.bgBase],
                ),
              ),
            ),
          ),

          // -- Top gradient scrim (for status bar contrast) ----------------
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 80,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [AppColors.bgBase, Colors.transparent],
                ),
              ),
            ),
          ),

          // -- Title, synopsis, and buttons --------------------------------
          Positioned(
            bottom: _isTv ? 80 : 60,
            left: AppTheme.horizontalPadding,
            right: AppTheme.horizontalPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title
                Text(
                  item.title,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: _isTv
                        ? AppTheme.heroTitleSizeTv
                        : AppTheme.heroTitleSize,
                    fontWeight: FontWeight.bold,
                    height: 1.1,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),

                const SizedBox(height: 12),

                // Synopsis
                if (item.synopsis != null && item.synopsis!.isNotEmpty)
                  Text(
                    item.synopsis!,
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: _isTv ? 18.0 : AppTheme.bodySize,
                      height: 1.3,
                    ),
                    maxLines: _isTv ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),

                const SizedBox(height: 20),

                // Buttons
                Row(
                  children: [
                    // Play button
                    _buildPlayButton(),
                    const SizedBox(width: 12),

                    // My List button
                    _buildMyListButton(),
                  ],
                ),
              ],
            ),
          ),

          // -- Indicator dots -----------------------------------------------
          if (widget.items.length > 1)
            Positioned(
              bottom: _isTv ? 40 : 24,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                  widget.items.length,
                  (index) => Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: index == _currentIndex
                          ? AppColors.textPrimary
                          : AppColors.textSecondary.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPlayButton() {
    final buttonHeight = _isTv ? 56.0 : 48.0;

    return SizedBox(
      height: buttonHeight,
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent || event is KeyRepeatEvent) {
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space ||
                key == LogicalKeyboardKey.gameButtonA) {
              widget.items[_currentIndex].onPlay?.call();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: ElevatedButton.icon(
          onPressed: () => widget.items[_currentIndex].onPlay?.call(),
          icon: Icon(Icons.play_arrow, size: _isTv ? 32 : 24),
          label: Text(
            'Play',
            style: TextStyle(
              fontSize: _isTv ? 20 : 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.textPrimary,
            foregroundColor: AppColors.bgBase,
            padding: EdgeInsets.symmetric(horizontal: _isTv ? 32 : 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMyListButton() {
    final buttonHeight = _isTv ? 56.0 : 48.0;

    return SizedBox(
      height: buttonHeight,
      child: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent || event is KeyRepeatEvent) {
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space ||
                key == LogicalKeyboardKey.gameButtonA) {
              widget.items[_currentIndex].onMyList?.call();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: ElevatedButton.icon(
          onPressed: () => widget.items[_currentIndex].onMyList?.call(),
          icon: Icon(Icons.add, size: _isTv ? 28 : 20),
          label: Text(
            'My List',
            style: TextStyle(
              fontSize: _isTv ? 20 : 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.bgSurface.withValues(alpha: 0.8),
            foregroundColor: AppColors.textPrimary,
            padding: EdgeInsets.symmetric(horizontal: _isTv ? 32 : 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.cardBorderRadius),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGradientPlaceholder() {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.bgElevated, AppColors.bgSurface],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.movie_filter,
          color: AppColors.textSecondary.withValues(alpha: 0.15),
          size: 120,
        ),
      ),
    );
  }
}

/// A featured item for use in [NetflixHero].
class NetflixHeroItem {
  const NetflixHeroItem({
    required this.title,
    this.imageUrl,
    this.synopsis,
    this.onPlay,
    this.onMyList,
  });

  /// Large title text for the hero.
  final String title;

  /// URL of the backdrop image.
  final String? imageUrl;

  /// Short synopsis or tagline text.
  final String? synopsis;

  /// Callback when the Play button is pressed.
  final VoidCallback? onPlay;

  /// Callback when the My List button is pressed.
  final VoidCallback? onMyList;
}
