import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/netflix_animations.dart';

/// A wrapper that adds Netflix-style focus / hover animations to its child.
///
/// **TV (D-pad):** scales the child to [scaleFactor] with a subtle glow and
/// accent-coloured ring when focused.
///
/// **Mobile (touch):** applies a brief scale-down on tap for tactile feedback.
///
/// Use this to wrap any interactive widget (cards, buttons, list tiles) to get
/// consistent Netflix-style motion across the app.
class NetflixFocus extends StatefulWidget {
  const NetflixFocus({
    super.key,
    required this.child,
    this.onFocusChanged,
    this.scaleFactor = 1.08,
    this.isTv = false,
    this.shouldAutoFocus = false,
    this.onActivate,
  });

  /// The child widget to wrap with focus animations.
  final Widget child;

  /// Called when focus state changes, with `true` when focused.
  final ValueChanged<bool>? onFocusChanged;

  /// Scale factor applied to the child when focused on TV.
  final double scaleFactor;

  /// Whether this widget is on a TV interface.
  final bool isTv;

  /// Whether this widget should auto-focus on build (TV D-pad).
  final bool shouldAutoFocus;

  /// D-pad activation callback (TV only). When set, pressing Select / Enter /
  /// Space / Game Button A while this wrapper holds focus invokes it — same
  /// action as a touch tap on the wrapped child (touch parity).
  final VoidCallback? onActivate;

  @override
  State<NetflixFocus> createState() => _NetflixFocusState();
}

class _NetflixFocusState extends State<NetflixFocus>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _glowAnimation;
  bool _hasFocus = false;

  bool get _effectiveIsTv =>
      widget.isTv ||
      Platform.isLinux ||
      (Platform.isAndroid &&
          WidgetsBinding.instance.platformDispatcher.views.isNotEmpty &&
          MediaQueryData.fromView(
                WidgetsBinding.instance.platformDispatcher.views.first,
              ).size.shortestSide >
              600);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: NetflixAnimations.focusScale,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: widget.scaleFactor)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: NetflixAnimations.focusCurve,
          ),
        );
    _glowAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: NetflixAnimations.focusCurve),
    );
  }

  @override
  void didUpdateWidget(NetflixFocus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scaleFactor != widget.scaleFactor) {
      _scaleAnimation = Tween<double>(begin: 1.0, end: widget.scaleFactor)
          .animate(
            CurvedAnimation(
              parent: _controller,
              curve: NetflixAnimations.focusCurve,
            ),
          );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange(bool hasFocus) {
    if (!mounted) return;
    setState(() => _hasFocus = hasFocus);
    if (hasFocus) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
    widget.onFocusChanged?.call(hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    if (_effectiveIsTv) {
      return _buildTvFocus();
    }
    return _buildMobileFocus();
  }

  /// TV: Focus widget with D-pad support, scale animation, and glow.
  Widget _buildTvFocus() {
    return Focus(
      autofocus: widget.shouldAutoFocus,
      onFocusChange: _onFocusChange,
      onKeyEvent: widget.onActivate == null
          ? null
          : (node, event) {
              if (event is KeyDownEvent || event is KeyRepeatEvent) {
                final key = event.logicalKey;
                if (key == LogicalKeyboardKey.select ||
                    key == LogicalKeyboardKey.enter ||
                    key == LogicalKeyboardKey.space ||
                    key == LogicalKeyboardKey.gameButtonA) {
                  widget.onActivate!();
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final scale = _scaleAnimation.value;
          final glow = _glowAnimation.value;

          return Transform.scale(
            scale: scale,
            child: Container(
              decoration: _hasFocus
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        AppTheme.cardBorderRadius,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accentPrimary.withValues(
                            alpha: 0.3 * glow,
                          ),
                          blurRadius: 16 * glow,
                          spreadRadius: 2 * glow,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4 * glow),
                          blurRadius: 8 * glow,
                          spreadRadius: 1 * glow,
                        ),
                      ],
                      border: Border.all(
                        color: AppColors.accentPrimary.withValues(
                          alpha: 0.6 * glow,
                        ),
                        width: 2.0,
                      ),
                    )
                  : null,
              child: widget.child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }

  /// Mobile: GestureDetector with brief scale-down on tap.
  Widget _buildMobileFocus() {
    return GestureDetector(
      onTapDown: (_) {
        if (mounted) {
          setState(() => _hasFocus = true);
          _controller.forward();
        }
      },
      onTapUp: (_) {
        if (mounted) {
          setState(() => _hasFocus = false);
          _controller.reverse();
        }
      },
      onTapCancel: () {
        if (mounted) {
          setState(() => _hasFocus = false);
          _controller.reverse();
        }
      },
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // On mobile we scale DOWN slightly on press (1.0 -> 0.96).
          final mobileScale = 1.0 - (0.04 * _glowAnimation.value);
          return Transform.scale(scale: mobileScale, child: widget.child);
        },
        child: widget.child,
      ),
    );
  }
}
