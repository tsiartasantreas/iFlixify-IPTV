import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';

/// Simple data holder for a rail navigation item.
class _RailItem {
  const _RailItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// Netflix-style left vertical nav rail for TV navigation.
///
/// Ten items: Home, Series, Movies, Live TV, Radio, My List, Search,
/// Downloads, Settings, Import Playlist. Supports D-pad up/down navigation between items and left/right
/// to enter/exit the rail. Collapsed width is ~80 px; expands to ~200 px
/// when focused, revealing labels.
class TvLeftRail extends StatefulWidget {
  const TvLeftRail({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  /// The currently selected tab index (0–9).
  final int currentIndex;

  /// Called when the user selects a nav item. The new index is passed.
  final ValueChanged<int> onTap;

  @override
  State<TvLeftRail> createState() => _TvLeftRailState();
}

class _TvLeftRailState extends State<TvLeftRail> {
  bool _expanded = false;
  final FocusNode _railFocus = FocusNode();

  @override
  void dispose() {
    _railFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  static const _items = <_RailItem>[
    _RailItem(icon: Icons.home, label: 'Home'),
    _RailItem(icon: Icons.tv, label: 'Series'),
    _RailItem(icon: Icons.movie, label: 'Movies'),
    _RailItem(icon: Icons.live_tv, label: 'Live TV'),
    _RailItem(icon: Icons.radio, label: 'Radio'),
    _RailItem(icon: Icons.playlist_play, label: 'My List'),
    _RailItem(icon: Icons.search, label: 'Search'),
    _RailItem(icon: Icons.download_done, label: 'Downloads'),
    _RailItem(icon: Icons.settings, label: 'Settings'),
    _RailItem(icon: Icons.playlist_add, label: 'Import Playlist'),
  ];

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _railFocus,
      onKeyEvent: _handleKeyEvent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: _expanded ? 200 : 80,
        decoration: const BoxDecoration(
          color: AppColors.bgBase,
          border: Border(
            right: BorderSide(color: AppColors.bgSurface, width: 0.5),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 24),

            // Brand mark
            AnimatedOpacity(
              opacity: _expanded ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Text(
                  'iFlixify IPTV',
                  style: TextStyle(
                    color: AppColors.accentPrimary,
                    fontSize: _expanded ? 20 : 0,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            // Nav items
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  return _buildNavItem(index);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(int index) {
    final item = _items[index];
    final isSelected = index == widget.currentIndex;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: _RailItemWidget(
        item: item,
        isSelected: isSelected,
        expanded: _expanded,
        autofocus: index == 0,
        onTap: () => widget.onTap(index),
        onFocusChanged: (focused) {
          if (focused) {
            setState(() => _expanded = true);
          }
        },
        onRightArrow: () {
          setState(() => _expanded = true);
          return KeyEventResult.ignored;
        },
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final next = (widget.currentIndex + 1).clamp(0, _items.length - 1);
      if (next != widget.currentIndex) {
        widget.onTap(next);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final prev = (widget.currentIndex - 1).clamp(0, _items.length - 1);
      if (prev != widget.currentIndex) {
        widget.onTap(prev);
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      setState(() => _expanded = true);
      return KeyEventResult.ignored; // focus moves to content area
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      setState(() => _expanded = false);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }
}

// ---------------------------------------------------------------------------
// Private widget for a single rail item to manage focus state cleanly.
// ---------------------------------------------------------------------------

class _RailItemWidget extends StatefulWidget {
  const _RailItemWidget({
    required this.item,
    required this.isSelected,
    required this.expanded,
    required this.onTap,
    required this.onFocusChanged,
    required this.onRightArrow,
    this.autofocus = false,
  });

  final _RailItem item;
  final bool isSelected;
  final bool expanded;
  final VoidCallback onTap;
  final ValueChanged<bool> onFocusChanged;
  final KeyEventResult Function() onRightArrow;
  final bool autofocus;

  @override
  State<_RailItemWidget> createState() => _RailItemWidgetState();
}

class _RailItemWidgetState extends State<_RailItemWidget> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isSelected || _focused;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      padding: EdgeInsets.symmetric(
        horizontal: widget.expanded ? 16 : 0,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: widget.isSelected
            ? AppColors.accentPrimary.withValues(alpha: 0.15)
            : _focused
                ? AppColors.bgSurface.withValues(alpha: 0.5)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Focus(
        autofocus: widget.autofocus,
        onFocusChange: (focused) {
          setState(() => _focused = focused);
          widget.onFocusChanged(focused);
        },
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.arrowRight) {
            return widget.onRightArrow();
          }
          return KeyEventResult.ignored;
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.item.icon,
              color: active ? AppColors.accentPrimary : AppColors.textSecondary,
              size: 24,
            ),
            if (widget.expanded) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.item.label,
                  style: TextStyle(
                    color: active
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    fontSize: 14,
                    fontWeight:
                        widget.isSelected ? FontWeight.w600 : FontWeight.normal,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
