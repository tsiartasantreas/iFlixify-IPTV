import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/netflix_animations.dart';
import 'netflix_focus.dart';

/// A full-width Netflix-style hero banner (billboard) at the top of the home
/// screen.
///
/// Features:
/// - Full-width backdrop image (or gradient placeholder if no image).
/// - Bottom gradient scrim (dark at bottom, transparent at top).
/// - Large title text (bold, condensed).
/// - Synopsis text (1-2 lines).
/// - "Play" button ([accentPrimary] background).
/// - "My List" button (outlined / semi-transparent background).
/// - Auto-cycles through featured items every 8 seconds (crossfade).
/// - TV: D-pad focus on buttons.
class NetflixBillboard extends StatefulWidget {
  const NetflixBillboard({
    super.key,
    required this.items,
    this.isTv = false,
    this.autoCycleInterval = const Duration(seconds: 8),
    this.crossfadeDuration = NetflixAnimations.billboardCrossfade,
  });

  /// List of featured items to rotate through.
  final List<NetflixBillboardItem> items;

  /// Whether this widget is on a TV interface.
  final bool isTv;

  /// Interval between automatic item transitions.
  final Duration autoCycleInterval;

  /// Duration of the crossfade transition between items.
  final Duration crossfadeDuration;

  @override
  State<NetflixBillboard> createState() => _NetflixBillboardState();
}

class _NetflixBillboardState extends State<NetflixBillboard> {
  int _currentIndex = 0;
  Timer? _autoCycleTimer;

  bool get _isTv =>
      widget.isTv ||
      Platform.isLinux ||
      (Platform.isAndroid &&
          WidgetsBinding.instance.platformDispatcher.views.isNotEmpty &&
          MediaQueryData.fromView(
                WidgetsBinding.instance.platformDispatcher.views.first,
              ).size.shortestSide >
              960);

  @override
  void initState() {
    super.initState();
    _startAutoCycle();
  }

  @override
  void didUpdateWidget(NetflixBillboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items) {
      _currentIndex = _currentIndex.clamp(0, widget.items.length - 1);
      _restartAutoCycle();
    }
  }

  @override
  void dispose() {
    _autoCycleTimer?.cancel();
    super.dispose();
  }

  void _startAutoCycle() {
    _autoCycleTimer?.cancel();
    if (widget.items.length > 1) {
      _autoCycleTimer = Timer.periodic(widget.autoCycleInterval, (_) {
        if (mounted) {
          setState(() {
            _currentIndex = (_currentIndex + 1) % widget.items.length;
          });
        }
      });
    }
  }

  void _restartAutoCycle() {
    _autoCycleTimer?.cancel();
    _startAutoCycle();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    final item = widget.items[_currentIndex];
    final screenHeight = MediaQuery.of(context).size.height;
    final heroHeight = _isTv ? screenHeight * 0.70 : screenHeight * 0.60;

    return Semantics(
      label: 'Featured content billboard',
      child: SizedBox(
        height: heroHeight,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // -- Backdrop image with crossfade -------------------------------
            AnimatedSwitcher(
              duration: widget.crossfadeDuration,
              switchInCurve: NetflixAnimations.billboardCurve,
              switchOutCurve: NetflixAnimations.billboardCurve,
              transitionBuilder: (child, animation) {
                return FadeTransition(opacity: animation, child: child);
              },
              child: KeyedSubtree(
                key: ValueKey<int>(_currentIndex),
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

            // -- Bottom gradient scrim ----------------------------------------
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

            // -- Top gradient scrim (for status bar contrast) -----------------
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

            // -- Title, synopsis, and buttons ---------------------------------
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
                    key: ValueKey<String>('title_$_currentIndex'),
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: _isTv
                          ? AppTheme.heroTitleSizeTv
                          : AppTheme.heroTitleSize,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      letterSpacing: -0.5,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: 12),

                  // Synopsis
                  if (item.synopsis != null && item.synopsis!.isNotEmpty)
                    Text(
                      item.synopsis!,
                      key: ValueKey<String>('synopsis_$_currentIndex'),
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
                    (index) => AnimatedContainer(
                      duration: NetflixAnimations.fast,
                      width: index == _currentIndex ? 24 : 8,
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
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
      ),
    );
  }

  Widget _buildPlayButton() {
    final buttonHeight = _isTv ? 56.0 : 48.0;

    return SizedBox(
      height: buttonHeight,
      child: NetflixFocus(
        isTv: _isTv,
        scaleFactor: 1.05,
        // D-pad activation on the wrapper focus node (touch parity: same
        // action as tapping the button).
        onActivate: () => widget.items[_currentIndex].onPlay?.call(),
        child: ElevatedButton.icon(
          onPressed: () => widget.items[_currentIndex].onPlay?.call(),
          icon: Icon(Icons.play_arrow, size: _isTv ? 32 : 24),
          label: Text(
            'Play',
            style: TextStyle(
              fontSize: _isTv ? 20 : 16,
              fontWeight: FontWeight.w700,
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
      child: NetflixFocus(
        isTv: _isTv,
        scaleFactor: 1.05,
        onActivate: () => widget.items[_currentIndex].onMyList?.call(),
        child: OutlinedButton.icon(
          onPressed: () => widget.items[_currentIndex].onMyList?.call(),
          icon: Icon(Icons.add, size: _isTv ? 28 : 20),
          label: Text(
            'My List',
            style: TextStyle(
              fontSize: _isTv ? 20 : 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          style: OutlinedButton.styleFrom(
            backgroundColor: AppColors.bgSurface.withValues(alpha: 0.7),
            foregroundColor: AppColors.textPrimary,
            side: const BorderSide(color: AppColors.textSecondary, width: 1),
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
      key: const ValueKey<String>('placeholder'),
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

/// A featured item for use in [NetflixBillboard].
class NetflixBillboardItem {
  const NetflixBillboardItem({
    required this.title,
    this.imageUrl,
    this.synopsis,
    this.onPlay,
    this.onMyList,
  });

  /// Large title text for the billboard.
  final String title;

  /// URL of the backdrop image.
  final String? imageUrl;

  /// Short synopsis or tagline text (1-2 lines).
  final String? synopsis;

  /// Callback when the Play button is pressed.
  final VoidCallback? onPlay;

  /// Callback when the My List button is pressed.
  final VoidCallback? onMyList;
}
