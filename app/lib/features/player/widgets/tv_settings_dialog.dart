import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/player/player_controller.dart';
import '../../../core/theme/app_colors.dart';

/// Tabs of the extended TV settings dialog, top-to-bottom in the left rail.
enum TvSettingsTab { playback, video, audio, subtitles, advanced }

/// Whether [key] is one of the TV "activate" keys
/// (Select / Enter / Space / Gamepad A).
bool tvIsActivateKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.space ||
    key == LogicalKeyboardKey.gameButtonA;

/// Formats a playback rate for chips/labels, e.g. `1.0×`, `0.25×`, `1.25×`.
String formatTvRate(double rate) {
  if (rate == rate.truncateToDouble()) {
    return '${rate.toStringAsFixed(1)}×';
  }
  return '${rate.toStringAsFixed(2)}×';
}

/// Opens the full-screen (90%) TV settings dialog.
///
/// All subtitle state lives on the player screen; the dialog mutates it via
/// the [onSubtitle*] callbacks (persistence to SharedPreferences stays on the
/// screen so the `Video` ValueKey keeps rebuilding with the new style).
/// Sleep-timer state also lives on the player screen and is surfaced here via
/// [sleepRemaining] / [onSelectSleepTimer].
Future<void> showTvSettingsDialog(
  BuildContext context, {
  required PlayerController controller,
  TvSettingsTab initialTab = TvSettingsTab.playback,
  required double subtitleFontSize,
  required double subtitleBgOpacity,
  required double subtitleOffset,
  required bool subtitleOutline,
  required ValueChanged<double> onSubtitleFontSize,
  required ValueChanged<double> onSubtitleBgOpacity,
  required ValueChanged<double> onSubtitleOffset,
  required ValueChanged<bool> onSubtitleOutline,
  required Duration sleepRemaining,
  required ValueChanged<int> onSelectSleepTimer,
}) {
  return showDialog(
    context: context,
    barrierColor: Colors.black54,
    barrierDismissible: false,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: TvSettingsDialog(
          controller: controller,
          initialTab: initialTab,
          subtitleFontSize: subtitleFontSize,
          subtitleBgOpacity: subtitleBgOpacity,
          subtitleOffset: subtitleOffset,
          subtitleOutline: subtitleOutline,
          onSubtitleFontSize: onSubtitleFontSize,
          onSubtitleBgOpacity: onSubtitleBgOpacity,
          onSubtitleOffset: onSubtitleOffset,
          onSubtitleOutline: onSubtitleOutline,
          sleepRemaining: sleepRemaining,
          onSelectSleepTimer: onSelectSleepTimer,
        ),
      );
    },
  );
}

/// VLC-grade, 10-foot-UI settings dialog for the TV player.
///
/// Layout: a LEFT vertical tab rail (Playback / Video / Audio / Subtitles /
/// Advanced) and a RIGHT content pane. The rail is a focus traversal group;
/// pressing RIGHT on a tab moves focus into the pane's first control and LEFT
/// inside the pane returns to the rail. Back / Escape closes the dialog.
class TvSettingsDialog extends StatefulWidget {
  const TvSettingsDialog({
    super.key,
    required this.controller,
    this.initialTab = TvSettingsTab.playback,
    required this.subtitleFontSize,
    required this.subtitleBgOpacity,
    required this.subtitleOffset,
    required this.subtitleOutline,
    required this.onSubtitleFontSize,
    required this.onSubtitleBgOpacity,
    required this.onSubtitleOffset,
    required this.onSubtitleOutline,
    required this.sleepRemaining,
    required this.onSelectSleepTimer,
  });

  final PlayerController controller;
  final TvSettingsTab initialTab;

  // -- Subtitle state (owned by the player screen) ---------------------------
  final double subtitleFontSize;
  final double subtitleBgOpacity;
  final double subtitleOffset;
  final bool subtitleOutline;
  final ValueChanged<double> onSubtitleFontSize;
  final ValueChanged<double> onSubtitleBgOpacity;
  final ValueChanged<double> onSubtitleOffset;
  final ValueChanged<bool> onSubtitleOutline;

  // -- Sleep timer (owned by the player screen) ------------------------------
  final Duration sleepRemaining;
  final ValueChanged<int> onSelectSleepTimer;

  @override
  State<TvSettingsDialog> createState() => _TvSettingsDialogState();
}

class _TvSettingsDialogState extends State<TvSettingsDialog> {
  static const _tabLabels = [
    (Icons.play_circle_outline, 'Playback'),
    (Icons.aspect_ratio, 'Video'),
    (Icons.volume_up, 'Audio'),
    (Icons.subtitles, 'Subtitles'),
    (Icons.tune, 'Advanced'),
  ];

  late int _tabIndex;
  late final List<FocusNode> _tabNodes;
  /// Focus node attached to the FIRST control of whichever pane is active, so
  /// pressing RIGHT on the rail can jump into the pane.
  final FocusNode _paneFirstNode = FocusNode();

  // Local mirrors of the subtitle prefs (kept in sync via the callbacks).
  late double _fontSize;
  late double _bgOpacity;
  late double _offset;
  late bool _outline;

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.initialTab.index;
    _tabNodes = List.generate(_tabLabels.length, (_) => FocusNode());
    _fontSize = widget.subtitleFontSize;
    _bgOpacity = widget.subtitleBgOpacity;
    _offset = widget.subtitleOffset;
    _outline = widget.subtitleOutline;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tabNodes[_tabIndex].requestFocus();
    });
  }

  @override
  void dispose() {
    for (final node in _tabNodes) {
      node.dispose();
    }
    _paneFirstNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Key handling
  // ---------------------------------------------------------------------------

  KeyEventResult _onRootKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.goBack)) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// LEFT anywhere inside the pane returns focus to the tab rail.
  KeyEventResult _onPaneKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _tabNodes[_tabIndex].requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _selectTab(int index) {
    if (mounted) setState(() => _tabIndex = index);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onRootKey,
      child: Container(
        width: size.width * 0.9,
        height: size.height * 0.9,
        decoration: BoxDecoration(
          color: AppColors.bgBase.withValues(alpha: 0.97),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.bgSurface, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTabRail(),
            Container(width: 1, color: AppColors.bgSurface),
            Expanded(
              child: Focus(
                canRequestFocus: false,
                onKeyEvent: _onPaneKey,
                child: FocusTraversalGroup(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _buildPane(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Left tab rail
  // ---------------------------------------------------------------------------

  Widget _buildTabRail() {
    return SizedBox(
      width: 230,
      child: FocusTraversalGroup(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Settings',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView.builder(
                  itemCount: _tabLabels.length,
                  itemBuilder: (context, index) => _buildTabItem(index),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabItem(int index) {
    final (icon, label) = _tabLabels[index];
    return Focus(
      focusNode: _tabNodes[index],
      // Autofocus lands on the initially selected tab only.
      autofocus: index == widget.initialTab.index,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (tvIsActivateKey(event.logicalKey)) {
          _selectTab(index);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _selectTab(index);
          _paneFirstNode.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final focused = Focus.of(ctx).hasFocus;
          final selected = _tabIndex == index;
          return GestureDetector(
            onTap: () {
              _selectTab(index);
              _paneFirstNode.requestFocus();
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.accentPrimary.withValues(alpha: 0.25)
                    : focused
                        ? AppColors.accentPrimary.withValues(alpha: 0.15)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: focused
                      ? AppColors.accentPrimary
                      : selected
                          ? AppColors.accentPrimary.withValues(alpha: 0.6)
                          : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 22,
                    color: selected || focused
                        ? AppColors.accentPrimary
                        : AppColors.textSecondary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: selected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontSize: 16,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Right content pane
  // ---------------------------------------------------------------------------

  Widget _buildPane() {
    final ctrl = widget.controller;
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        switch (TvSettingsTab.values[_tabIndex]) {
          case TvSettingsTab.playback:
            return _buildPlaybackPane(ctrl);
          case TvSettingsTab.video:
            return _buildVideoPane(ctrl);
          case TvSettingsTab.audio:
            return _buildAudioPane(ctrl);
          case TvSettingsTab.subtitles:
            return _buildSubtitlesPane();
          case TvSettingsTab.advanced:
            return _buildAdvancedPane(ctrl);
        }
      },
    );
  }

  // -- Playback ---------------------------------------------------------------

  Widget _buildPlaybackPane(PlayerController ctrl) {
    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0, 4.0];
    return _paneList([
      _chipRow(
        'Playback Speed',
        [
          for (final speed in speeds)
            TvFocusChip(
              key: ValueKey('speed-$speed'),
              label: formatTvRate(speed),
              focusNode: speed == speeds.first ? _paneFirstNode : null,
              selected: (ctrl.rate - speed).abs() < 0.01,
              onActivated: () => ctrl.setRate(speed),
            ),
        ],
      ),
      _chipRow(
        'Audio Delay  (${ctrl.audioDelay.toStringAsFixed(1)}s)',
        [
          TvFocusChip(
            label: '−0.5s',
            onActivated: () =>
                ctrl.setAudioDelay(ctrl.audioDelay - 0.5),
          ),
          TvFocusChip(
            label: '+0.5s',
            onActivated: () =>
                ctrl.setAudioDelay(ctrl.audioDelay + 0.5),
          ),
          TvFocusChip(
            label: 'Reset',
            selected: ctrl.audioDelay == 0,
            onActivated: () => ctrl.setAudioDelay(0),
          ),
        ],
      ),
      _buildSleepRow(),
    ]);
  }

  Widget _buildSleepRow() {
    final remaining = widget.sleepRemaining;
    final active = remaining > Duration.zero;
    const minuteOptions = [0, 15, 30, 45, 60, 90];
    return _chipRow(
      active
          ? 'Sleep Timer  ('
              '${remaining.inMinutes.remainder(60).toString().padLeft(2, '0')}:'
              '${remaining.inSeconds.remainder(60).toString().padLeft(2, '0')}'
              ' remaining)'
          : 'Sleep Timer  (Off)',
      [
        for (final minutes in minuteOptions)
          TvFocusChip(
            key: ValueKey('sleep-$minutes'),
            label: minutes == 0 ? 'Off' : '$minutes min',
            selected: minutes == 0 && !active,
            onActivated: () => widget.onSelectSleepTimer(minutes),
          ),
      ],
    );
  }

  // -- Video ------------------------------------------------------------------

  Widget _buildVideoPane(PlayerController ctrl) {
    return _paneList([
      _chipRow(
        'Aspect Ratio',
        [
          TvFocusChip(
            label: 'Auto',
            focusNode: _paneFirstNode,
            selected: ctrl.aspectOverride == null,
            onActivated: () => ctrl.setAspectRatio(null),
          ),
          for (final preset in PlayerController.aspectPresets)
            TvFocusChip(
              key: ValueKey('aspect-$preset'),
              label: preset,
              selected: ctrl.aspectOverride == preset,
              onActivated: () => ctrl.setAspectRatio(preset),
            ),
        ],
      ),
      _chipRow(
        'Rotation',
        [
          for (final degrees in const [0, 90, 180, 270])
            TvFocusChip(
              key: ValueKey('rot-$degrees'),
              label: '$degrees°',
              selected: ctrl.rotation == degrees,
              onActivated: () => ctrl.setRotation(degrees),
            ),
        ],
      ),
      _toggleRow(
        'Deinterlace',
        'Improves quality of interlaced broadcasts',
        ctrl.deinterlace,
        () {
          final next = !ctrl.deinterlace;
          ctrl.setDeinterlace(next);
        },
      ),
    ]);
  }

  // -- Audio ------------------------------------------------------------------

  Widget _buildAudioPane(PlayerController ctrl) {
    final boostPercent = ctrl.volume.clamp(0.0, PlayerController.maxVolumePercent);
    return _paneList([
      _AdjustRow(
        key: const ValueKey('volume-boost'),
        focusNode: _paneFirstNode,
        label: 'Volume Boost',
        valueText: '${boostPercent.round()}%',
        fraction: boostPercent / PlayerController.maxVolumePercent,
        onDecrease: () => ctrl.setVolumeBoostPercent(
            (boostPercent - 10).clamp(0.0, PlayerController.maxVolumePercent)),
        onIncrease: () => ctrl.setVolumeBoostPercent(
            (boostPercent + 10).clamp(0.0, PlayerController.maxVolumePercent)),
      ),
      _chipRow(
        'Subtitle Delay  (${ctrl.subDelay.toStringAsFixed(1)}s)',
        [
          TvFocusChip(
            label: '−0.5s',
            onActivated: () => ctrl.setSubDelay(ctrl.subDelay - 0.5),
          ),
          TvFocusChip(
            label: '+0.5s',
            onActivated: () => ctrl.setSubDelay(ctrl.subDelay + 0.5),
          ),
          TvFocusChip(
            label: 'Reset',
            selected: ctrl.subDelay == 0,
            onActivated: () => ctrl.setSubDelay(0),
          ),
        ],
      ),
    ]);
  }

  // -- Subtitles --------------------------------------------------------------

  Widget _buildSubtitlesPane() {
    return _paneList([
      _chipRow(
        'Font Size  (${_fontSize.round()}px)',
        [
          for (final size in const [14.0, 18.0, 24.0, 32.0])
            TvFocusChip(
              key: ValueKey('font-$size'),
              label: '${size.round()}',
              focusNode: size == 14.0 ? _paneFirstNode : null,
              selected: (_fontSize - size).abs() < 0.01,
              onActivated: () {
                setState(() => _fontSize = size);
                widget.onSubtitleFontSize(size);
              },
            ),
        ],
      ),
      _AdjustRow(
        key: const ValueKey('subtitle-bg'),
        label: 'Background Opacity',
        valueText: '${(_bgOpacity * 100).round()}%',
        fraction: _bgOpacity,
        onDecrease: () => _setBgOpacity((_bgOpacity - 0.1).clamp(0.0, 1.0)),
        onIncrease: () => _setBgOpacity((_bgOpacity + 0.1).clamp(0.0, 1.0)),
      ),
      _AdjustRow(
        key: const ValueKey('subtitle-pos'),
        label: 'Vertical Position',
        valueText: _offset.toStringAsFixed(2),
        fraction: (_offset + 1.0) / 2.0,
        onDecrease: () => _setOffset((_offset - 0.1).clamp(-1.0, 1.0)),
        onIncrease: () => _setOffset((_offset + 0.1).clamp(-1.0, 1.0)),
      ),
      _toggleRow(
        'Text Outline',
        'Black outline around subtitle text',
        _outline,
        () {
          final next = !_outline;
          setState(() => _outline = next);
          widget.onSubtitleOutline(next);
        },
      ),
      const Text(
        'Styling is applied instantly and persisted.',
        style: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontStyle: FontStyle.italic,
        ),
      ),
    ]);
  }

  void _setBgOpacity(double value) {
    setState(() => _bgOpacity = value);
    widget.onSubtitleBgOpacity(value);
  }

  void _setOffset(double value) {
    setState(() => _offset = value);
    widget.onSubtitleOffset(value);
  }

  // -- Advanced ---------------------------------------------------------------

  Widget _buildAdvancedPane(PlayerController ctrl) {
    return _paneList([
      _chipRow(
        'Network Buffer',
        [
          for (final mb in const [16, 64, 150])
            TvFocusChip(
              key: ValueKey('buffer-$mb'),
              label: '$mb MB',
              focusNode: mb == 16 ? _paneFirstNode : null,
              selected: ctrl.bufferMb == mb,
              onActivated: () => ctrl.setBufferMegabytes(mb),
            ),
        ],
      ),
      _aboutCard(ctrl),
    ]);
  }

  Widget _aboutCard(PlayerController ctrl) {
    final config = ctrl.currentConfig;
    final resolution =
        ctrl.videoResolution.isEmpty ? 'Unknown' : ctrl.videoResolution;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.bgSurface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.bgSurface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'About',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _aboutLine('Resolution', resolution),
          _aboutLine('Decoder', config.hwdec),
          _aboutLine('User agent', config.userAgent ?? 'Default'),
          _aboutLine('Buffer', '${ctrl.bufferMb} MB'),
          _aboutLine('Engine', 'libmpv (media_kit)'),
        ],
      ),
    );
  }

  Widget _aboutLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Pane building blocks
  // ---------------------------------------------------------------------------

  Widget _paneList(List<Widget> rows) {
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 20),
      itemBuilder: (context, index) => rows[index],
    );
  }

  Widget _paneTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  /// A labelled row of focusable chips. The row is its own traversal group so
  /// LEFT/RIGHT on a chip stays within the row.
  Widget _chipRow(String label, List<Widget> chips) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _paneTitle(label),
        const SizedBox(height: 10),
        FocusTraversalGroup(
          child: Wrap(spacing: 10, runSpacing: 10, children: chips),
        ),
      ],
    );
  }

  Widget _toggleRow(
    String label,
    String subtitle,
    bool value,
    VoidCallback onToggle, {
    FocusNode? focusNode,
  }) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && tvIsActivateKey(event.logicalKey)) {
          onToggle();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final focused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: onToggle,
            child: Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: focused
                    ? AppColors.accentPrimary.withValues(alpha: 0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: focused
                      ? AppColors.accentPrimary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: value,
                    onChanged: (_) => onToggle(),
                    activeThumbColor: AppColors.accentPrimary,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

}

/// A focusable horizontal adjustment row (VLC-style slider replacement).
///
/// LEFT / RIGHT while focused invoke [onDecrease] / [onIncrease]; UP / DOWN
/// fall through to the default directional focus traversal so the user can
/// move between rows.
class _AdjustRow extends StatelessWidget {
  const _AdjustRow({
    super.key,
    required this.label,
    required this.valueText,
    required this.fraction,
    required this.onDecrease,
    required this.onIncrease,
    this.focusNode,
  });

  final String label;
  final String valueText;
  final double fraction;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          onDecrease();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          onIncrease();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final focused = Focus.of(ctx).hasFocus;
          return Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: focused
                  ? AppColors.accentPrimary.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color:
                    focused ? AppColors.accentPrimary : Colors.transparent,
                width: 2,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Text(
                      valueText,
                      style: const TextStyle(
                        color: AppColors.accentPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: fraction.clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: AppColors.bgSurface,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.accentPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Use ◄ ► to adjust',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A single focusable chip used across the TV settings dialog and the TV
/// player bottom bar. Activates on Select / Enter / Space / Gamepad A; the
/// arrows move focus horizontally within the enclosing row.
class TvFocusChip extends StatelessWidget {
  const TvFocusChip({
    super.key,
    required this.label,
    required this.onActivated,
    this.selected = false,
    this.accentWhenActive = false,
    this.focusNode,
    this.autofocus = false,
    this.icon,
  });

  final String label;
  final VoidCallback onActivated;

  /// Draws the accent-tinted "currently selected value" state.
  final bool selected;

  /// Additional accent tint used by bottom-bar chips (e.g. speed != 1.0).
  final bool accentWhenActive;
  final FocusNode? focusNode;
  final bool autofocus;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (tvIsActivateKey(event.logicalKey)) {
          onActivated();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          node.previousFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          node.nextFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final focused = Focus.of(ctx).hasFocus;
          final accent = selected || accentWhenActive;
          return GestureDetector(
            onTap: onActivated,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: focused
                    ? AppColors.accentPrimary.withValues(alpha: 0.35)
                    : accent
                        ? AppColors.accentPrimary.withValues(alpha: 0.2)
                        : AppColors.bgSurface.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: focused
                      ? AppColors.accentPrimary
                      : accent
                          ? AppColors.accentPrimary.withValues(alpha: 0.7)
                          : AppColors.textSecondary.withValues(alpha: 0.4),
                  width: focused ? 2 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 16,
                      color: accent
                          ? AppColors.accentPrimary
                          : AppColors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: accent
                          ? AppColors.accentPrimary
                          : focused
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                      fontSize: 14,
                      fontWeight: accent || focused
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
