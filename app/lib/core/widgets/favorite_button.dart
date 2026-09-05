import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/tv_mode.dart';
import '../data/favorites_service.dart';
import '../theme/app_colors.dart';

/// A toggleable heart button that adds/removes an item from favourites.
///
/// Displays a filled red heart when favourited, or an outline heart when not.
/// Tap toggles the state. Supports optional size customisation.
///
/// Usage:
/// ```dart
/// FavoriteButton(
///   contentId: 'vod:42',
///   contentType: 'vod',
///   title: 'Inception',
///   poster: 'https://...',
///   url: 'http://...',
/// )
/// ```
class FavoriteButton extends StatefulWidget {
  const FavoriteButton({
    super.key,
    required this.contentId,
    required this.contentType,
    this.title,
    this.poster,
    this.url,
    this.size = 24.0,
  });

  /// Polymorphic ID (e.g. `"channel:42"`, `"vod:7"`, `"series:19"`).
  final String contentId;

  /// Entity type: `"live"`, `"vod"`, `"series"`, or `"radio"`.
  final String contentType;

  /// Display title for the favourite record.
  final String? title;

  /// Poster / thumbnail URL for the favourite record.
  final String? poster;

  /// Stream URL for the favourite record.
  final String? url;

  /// Icon size (default 24).
  final double size;

  @override
  State<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<FavoriteButton> {
  final _service = FavoritesService();
  bool _isFavorite = false;
  bool _isLoading = true;

  /// Whether the TV (D-pad) focus ring is shown.
  bool _tvFocused = false;

  @override
  void initState() {
    super.initState();
    _checkFavorite();
  }

  Future<void> _checkFavorite() async {
    final result = await _service.isFavorite(widget.contentId);
    if (mounted) {
      setState(() {
        _isFavorite = result;
        _isLoading = false;
      });
    }
  }

  Future<void> _toggle() async {
    // Optimistic UI update.
    setState(() => _isFavorite = !_isFavorite);

    final nowFavorite = await _service.toggleFavorite(
      contentId: widget.contentId,
      contentType: widget.contentType,
      title: widget.title,
      poster: widget.poster,
      url: widget.url,
    );

    if (mounted) {
      setState(() => _isFavorite = nowFavorite);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.textSecondary,
        ),
      );
    }

    final heart = GestureDetector(
      onTap: _toggle,
      child: Icon(
        _isFavorite ? Icons.favorite : Icons.favorite_border,
        color: _isFavorite ? Colors.red : AppColors.textSecondary,
        size: widget.size,
      ),
    );

    // TV touch parity: the heart is focusable and activates via
    // Select / Enter / Space / Game Button A, with a visible focus ring.
    // Touch (onTap) keeps working exactly as before.
    if (!TvModeScope.of(context)) return heart;
    return Focus(
      onFocusChange: (focused) {
        if (mounted) setState(() => _tvFocused = focused);
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.gameButtonA) {
            _toggle();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedScale(
        duration: const Duration(milliseconds: 150),
        scale: _tvFocused ? 1.2 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: _tvFocused
              ? BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.accentPrimary, width: 2),
                )
              : null,
          child: heart,
        ),
      ),
    );
  }
}
