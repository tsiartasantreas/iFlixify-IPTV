import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../../core/theme/app_colors.dart';

// ---------------------------------------------------------------------------
// Stream info overlay — title, category, resolution badge
// ---------------------------------------------------------------------------

/// Compact overlay showing the current stream's title, category, and
/// resolution. Positioned at the top-left of the player.
class StreamInfoOverlay extends StatelessWidget {
  const StreamInfoOverlay({
    super.key,
    required this.title,
    this.category,
    this.resolution,
    this.contentType,
  });

  final String title;
  final String? category;
  final String? resolution;
  final String? contentType;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Title
          Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          // Row of badges: category, content type, resolution
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (category != null && category!.isNotEmpty)
                _InfoBadge(
                  label: category!,
                  color: AppColors.bgSurface,
                ),
              if (contentType != null && contentType!.isNotEmpty)
                _InfoBadge(
                  label: _contentTypeLabel(contentType!),
                  color: _contentTypeColor(contentType!),
                ),
              if (resolution != null && resolution!.isNotEmpty)
                _InfoBadge(
                  label: resolution!,
                  color: AppColors.accentPrimary.withValues(alpha: 0.3),
                  textColor: AppColors.accentPrimary,
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _contentTypeLabel(String type) {
    switch (type) {
      case 'live':
        return 'LIVE';
      case 'vod':
        return 'Movie';
      case 'series':
        return 'Series';
      case 'radio':
        return 'Radio';
      default:
        return type;
    }
  }

  static Color _contentTypeColor(String type) {
    switch (type) {
      case 'live':
        return Colors.red.withValues(alpha: 0.3);
      case 'vod':
        return AppColors.accentPrimary.withValues(alpha: 0.3);
      case 'series':
        return Colors.blue.withValues(alpha: 0.3);
      case 'radio':
        return Colors.green.withValues(alpha: 0.3);
      default:
        return AppColors.bgSurface;
    }
  }
}

class _InfoBadge extends StatelessWidget {
  const _InfoBadge({
    required this.label,
    required this.color,
    this.textColor,
  });

  final String label;
  final Color color;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor ?? AppColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Brightness / Volume indicator pill
// ---------------------------------------------------------------------------

/// A floating pill that appears when the user adjusts brightness or volume.
/// Shows an icon and percentage, fades out after a short delay.
class AdjustIndicator extends StatelessWidget {
  const AdjustIndicator({
    super.key,
    required this.icon,
    required this.value,
    required this.visible,
  });

  final IconData icon;
  final double value; // 0.0 – 1.0
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.textPrimary, size: 28),
            const SizedBox(height: 6),
            SizedBox(
              width: 48,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: value,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    AppColors.textPrimary,
                  ),
                  minHeight: 3,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${(value * 100).round()}%',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Audio track selector bottom sheet
// ---------------------------------------------------------------------------

/// Shows a modal bottom sheet listing available audio tracks.
/// Returns the selected [AudioTrack] or null if dismissed.
Future<AudioTrack?> showAudioTrackSelector(
  BuildContext context, {
  required List<AudioTrack> tracks,
  required AudioTrack current,
}) async {
  if (tracks.isEmpty) return null;

  return showModalBottomSheet<AudioTrack>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Audio Track',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Divider(height: 1, color: AppColors.bgSurface),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: tracks.length,
                itemBuilder: (_, i) {
                  final track = tracks[i];
                  final isSelected = track == current;
                  return ListTile(
                    leading: Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: isSelected
                          ? AppColors.accentPrimary
                          : AppColors.textSecondary,
                    ),
                    title: Text(
                      _audioTrackLabel(track, i),
                      style: TextStyle(
                        color: isSelected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    onTap: () => Navigator.of(ctx).pop(track),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Subtitle track selector bottom sheet
// ---------------------------------------------------------------------------

/// Shows a modal bottom sheet listing available subtitle tracks.
/// Returns the selected [SubtitleTrack] or null if dismissed.
Future<SubtitleTrack?> showSubtitleTrackSelector(
  BuildContext context, {
  required List<SubtitleTrack> tracks,
  required SubtitleTrack current,
}) async {
  // Always include "Off" as the first option.
  final allTracks = <SubtitleTrack>[SubtitleTrack.no(), ...tracks];

  return showModalBottomSheet<SubtitleTrack>(
    context: context,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Subtitles',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Divider(height: 1, color: AppColors.bgSurface),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: allTracks.length,
                itemBuilder: (_, i) {
                  final track = allTracks[i];
                  final isNone = track == SubtitleTrack.no();
                  final isSelected = track == current ||
                      (isNone && current == SubtitleTrack.no());
                  return ListTile(
                    leading: Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: isSelected
                          ? AppColors.accentPrimary
                          : AppColors.textSecondary,
                    ),
                    title: Text(
                      isNone ? 'Off' : _subtitleTrackLabel(track, i - 1),
                      style: TextStyle(
                        color: isSelected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                        fontWeight:
                            isSelected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    onTap: () => Navigator.of(ctx).pop(track),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Next / Previous channel buttons
// ---------------------------------------------------------------------------

/// A row of skip-previous / skip-next buttons for navigating between
/// channels in the same group.
class NextPrevChannelButtons extends StatelessWidget {
  const NextPrevChannelButtons({
    super.key,
    this.onPrevious,
    this.onNext,
  });

  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CircleIconButton(
          icon: Icons.skip_previous,
          onPressed: onPrevious,
          tooltip: 'Previous channel',
        ),
        const SizedBox(width: 32),
        _CircleIconButton(
          icon: Icons.skip_next,
          onPressed: onNext,
          tooltip: 'Next channel',
        ),
      ],
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip ?? '',
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.bgSurface.withValues(alpha: 0.7)
                : AppColors.bgSurface.withValues(alpha: 0.3),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: enabled
                ? AppColors.textPrimary
                : AppColors.textSecondary.withValues(alpha: 0.4),
            size: 24,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Progress bar with live / VOD awareness
// ---------------------------------------------------------------------------

/// Enhanced seek bar that shows "LIVE" badge for live streams and a full
/// seekable slider for VOD/series content.
class PlayerProgressBar extends StatelessWidget {
  const PlayerProgressBar({
    super.key,
    required this.positionText,
    required this.durationText,
    required this.seekFraction,
    required this.isLive,
    this.onSeek,
  });

  final String positionText;
  final String durationText;
  final double seekFraction;
  final bool isLive;
  final ValueChanged<double>? onSeek;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // Current position
          Text(
            positionText,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),

          // Slider (or live bar)
          Expanded(
            child: isLive ? _buildLiveBar() : _buildSeekBar(),
          ),

          const SizedBox(width: 8),

          // Duration / LIVE badge
          if (isLive)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text(
                'LIVE',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else
            Text(
              durationText,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSeekBar() {
    return SliderTheme(
      data: const SliderThemeData(
        activeTrackColor: AppColors.accentPrimary,
        inactiveTrackColor: AppColors.bgSurface,
        thumbColor: AppColors.accentPrimary,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        trackHeight: 3,
        overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      ),
      child: Slider(
        value: seekFraction,
        onChanged: onSeek,
      ),
    );
  }

  Widget _buildLiveBar() {
    // For live streams, show a bar pinned to the end with a pulsing indicator.
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: 1.0,
              backgroundColor: AppColors.bgSurface,
              valueColor: AlwaysStoppedAnimation<Color>(
                AppColors.accentPrimary.withValues(alpha: 0.6),
              ),
              minHeight: 3,
            ),
          ),
        ),
        const SizedBox(width: 6),
        // Pulsing red dot
        Container(
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: Colors.red,
            shape: BoxShape.circle,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Quick-seek pill + speed chip (bottom control bar)
// ---------------------------------------------------------------------------

/// Compact rounded pill used for the quick-seek actions (`-30s`, `+10s`, ...)
/// in the bottom control bar.
class QuickSeekButton extends StatelessWidget {
  const QuickSeekButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.bgSurface.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Chip showing the current playback speed. Tinted with the accent color
/// when the rate differs from 1.0. Tapping opens a speed selector.
class SpeedChip extends StatelessWidget {
  const SpeedChip({
    super.key,
    required this.rate,
    required this.onTap,
  });

  final double rate;
  final VoidCallback onTap;

  bool get _isDefault => (rate - 1.0).abs() < 0.001;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _isDefault
              ? AppColors.bgSurface.withValues(alpha: 0.7)
              : AppColors.accentPrimary,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          '${rate.toStringAsFixed(rate % 1 == 0 ? 1 : 2)}×',
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings sheet chips
// ---------------------------------------------------------------------------

/// A single selectable chip used inside the player settings bottom sheet
/// (aspect ratio, rotation, zoom fit, buffer size, speed, sleep timer...).
class SettingsChip extends StatelessWidget {
  const SettingsChip({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.accentPrimary
              : AppColors.bgSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? AppColors.accentPrimary
                : AppColors.textSecondary.withValues(alpha: 0.4),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? AppColors.textPrimary
                : AppColors.textSecondary,
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// A horizontally scrollable row of [SettingsChip]s.
class SettingsChipRow extends StatelessWidget {
  const SettingsChipRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _audioTrackLabel(AudioTrack track, int index) {
  // Try to build a meaningful label from the track metadata.
  final parts = <String>[];
  if (track.language != null && track.language!.isNotEmpty) {
    parts.add(track.language!.toUpperCase());
  }
  if (track.title != null && track.title!.isNotEmpty) {
    parts.add(track.title!);
  }
  if (parts.isEmpty) {
    return 'Audio ${index + 1}';
  }
  return parts.join(' - ');
}

String _subtitleTrackLabel(SubtitleTrack track, int index) {
  final parts = <String>[];
  if (track.language != null && track.language!.isNotEmpty) {
    parts.add(track.language!.toUpperCase());
  }
  if (track.title != null && track.title!.isNotEmpty) {
    parts.add(track.title!);
  }
  if (parts.isEmpty) {
    return 'Subtitle ${index + 1}';
  }
  return parts.join(' - ');
}
