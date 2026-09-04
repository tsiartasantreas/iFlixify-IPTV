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
/// Downloads, Settings, Import Playlist.
///
/// Focus model (TV mode):
/// - D-pad Up/Down moves focus between rail items (never changes tabs).
/// - Select/Enter/Space/Game Button A on a focused item activates the tab.
/// - D-pad Right exits the rail and transfers focus into the content pane
///   via [onFocusContent].
/// - The visual highlight follows the FOCUSED item; the selected tab keeps
///   its own accent indicator.
class TvLeftRail extends StatefulWidget {
  const TvLeftRail({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.onFocusContent,
    this.onItemFocused,
  });

  /// The currently selected tab index (0–9).
  final int currentIndex;

  /// Called when the user activates a nav item. The new index is passed.
  final ValueChanged<int> onTap;

  /// Called when the user presses Right on the rail: the shell must move
  /// focus into the content pane.
  final VoidCallback onFocusContent;

  /// Optional notification that rail item [index] gained focus.
  final ValueChanged<int>? onItemFocused;

  @override
  State<TvLeftRail> createState() => _TvLeftRailState();
}

class _TvLeftRailState extends State<TvLeftRail> {
  bool _expanded = false;

  /// Index of the rail item that currently holds focus (visual highlight).
  int _focusedIndex = 0;

  final FocusNode _railFocus = FocusNode();

  /// One focus node per rail item so the rail can drive focus explicitly.
  late final List<FocusNode> _itemNodes = List<FocusNode>.generate(
    _items.length,
    (i) => FocusNode(debugLabel: 'rail-item-$i'),
  );

  @override
  void dispose() {
    for (final node in _itemNodes) {
      node.dispose();
    }
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
  // Key handling
  // ---------------------------------------------------------------------------

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    // D-pad Up/Down: move focus between rail items. Never changes tabs.
    if (key == LogicalKeyboardKey.arrowDown) {
      final next = _focusedIndex + 1;
      if (next < _itemNodes.length) {
        _itemNodes[next].requestFocus();
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      final prev = _focusedIndex - 1;
      if (prev >= 0) {
        _itemNodes[prev].requestFocus();
      }
      return KeyEventResult.handled;
    }

    // Right: hand focus to the content pane.
    if (key == LogicalKeyboardKey.arrowRight) {
      widget.onFocusContent();
      return KeyEventResult.handled;
    }

    // Left: collapse the rail (stay on the rail).
    if (key == LogicalKeyboardKey.arrowLeft) {
      setState(() => _expanded = false);
      return KeyEventResult.handled;
    }

    // Activation keys: select the tab of the currently focused item. Only
    // fires when an item (not the rail scope itself) has focus.
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space) {
      final primaryFocus = FocusManager.instance.primaryFocus;
      if (primaryFocus != null && _itemNodes.contains(primaryFocus)) {
        widget.onTap(_focusedIndex);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _railFocus,
      onKeyEvent: _handleKeyEvent,
      // Collapse when focus leaves the rail entirely.
      onFocusChange: (has) {
        if (!has) {
          setState(() => _expanded = false);
        }
      },
      child: FocusTraversalGroup(
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
        focusNode: _itemNodes[index],
        autofocus: index == 0,
        onTap: () {
          // Touch: focus the item first so D-pad continues from here, then
          // activate the tab.
          _itemNodes[index].requestFocus();
          widget.onTap(index);
        },
        onFocusChanged: (focused) {
          if (focused) {
            setState(() {
              _focusedIndex = index;
              _expanded = true;
            });
            widget.onItemFocused?.call(index);
          }
        },
      ),
    );
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
    required this.focusNode,
    required this.onTap,
    required this.onFocusChanged,
    this.autofocus = false,
  });

  final _RailItem item;
  final bool isSelected;
  final bool expanded;
  final FocusNode focusNode;
  final VoidCallback onTap;
  final ValueChanged<bool> onFocusChanged;
  final bool autofocus;

  @override
  State<_RailItemWidget> createState() => _RailItemWidgetState();
}

class _RailItemWidgetState extends State<_RailItemWidget> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // Visual state: focused item gets the bright highlight; selected tab
    // keeps its own accent tint + bold label. They are independent.
    final highlight = _focused;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      padding: EdgeInsets.symmetric(
        horizontal: widget.expanded ? 16 : 0,
        vertical: 12,
      ),
      decoration: BoxDecoration(
        color: _focused
            ? AppColors.bgSurface.withValues(alpha: 0.9)
            : widget.isSelected
                ? AppColors.accentPrimary.withValues(alpha: 0.15)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: (focused) {
          setState(() => _focused = focused);
          widget.onFocusChanged(focused);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.item.icon,
              color: highlight || widget.isSelected
                  ? AppColors.accentPrimary
                  : AppColors.textSecondary,
              size: 24,
            ),
            if (widget.expanded) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.item.label,
                  style: TextStyle(
                    color: highlight || widget.isSelected
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
