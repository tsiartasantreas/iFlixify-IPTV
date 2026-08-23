import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/data/offline_download_service.dart';
import '../../../core/theme/app_colors.dart';

/// A download / cancel / play button for use on detail screens.
///
/// States:
/// - **Idle**: shows a download icon. Tap to start downloading.
/// - **Downloading**: shows a circular progress indicator. Tap to cancel.
/// - **Downloaded**: shows a checkmark. Tap to play offline.
class DownloadButton extends StatefulWidget {
  const DownloadButton({
    super.key,
    required this.contentId,
    required this.title,
    required this.url,
    required this.contentType,
    this.thumbnailUrl,
    this.onPlayOffline,
  });

  /// Unique identifier for this content item.
  final String contentId;

  /// Display title for the download record.
  final String title;

  /// URL to stream / download from.
  final String url;

  /// Content type: `"movie"`, `"series"`, `"radio"`, or `"live"`.
  final String contentType;

  /// Optional thumbnail URL stored with the download.
  final String? thumbnailUrl;

  /// Called when the user taps a downloaded item to play it offline.
  final VoidCallback? onPlayOffline;

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  final _downloadService = OfflineDownloadService.instance;
  bool _isDownloaded = false;
  bool _isDownloading = false;
  double _progress = 0.0;
  StreamSubscription<Map<String, DownloadProgress>>? _progressSub;

  @override
  void initState() {
    super.initState();
    _checkDownloaded();
    _listenToProgress();
  }

  void _listenToProgress() {
    // Check if there's already progress for this content.
    final existing = _downloadService.currentProgress[widget.contentId];
    if (existing != null &&
        (existing.state == DownloadState.downloading ||
            existing.state == DownloadState.queued)) {
      _isDownloading = true;
      _progress = existing.progress;
    }

    _progressSub = _downloadService.progressStream.listen((progressMap) {
      if (!mounted) return;
      final p = progressMap[widget.contentId];
      if (p == null) return;

      setState(() {
        switch (p.state) {
          case DownloadState.queued:
          case DownloadState.downloading:
            _isDownloading = true;
            _progress = p.progress;
            break;
          case DownloadState.completed:
            _isDownloading = false;
            _isDownloaded = true;
            _progress = 1.0;
            break;
          case DownloadState.failed:
          case DownloadState.cancelled:
            _isDownloading = false;
            _progress = 0;
            break;
        }
      });
    });
  }

  Future<void> _checkDownloaded() async {
    final result = await _downloadService.isDownloaded(widget.contentId);
    if (mounted) {
      setState(() => _isDownloaded = result);
    }
  }

  Future<void> _startDownload() async {
    await _downloadService.enqueueDownload(
      contentId: widget.contentId,
      url: widget.url,
      title: widget.title,
      contentType: widget.contentType,
      thumbnailUrl: widget.thumbnailUrl,
    );
    // If the item was already downloaded (e.g. hydrated from DB), the
    // progress stream will have already updated _isDownloaded. Only show
    // the downloading state if the download was actually enqueued.
    if (mounted && !_isDownloaded) {
      setState(() {
        _isDownloading = true;
        _progress = 0;
      });
    }
  }

  void _cancelDownload() {
    _downloadService.cancelDownload(widget.contentId);
    setState(() {
      _isDownloading = false;
      _progress = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 48,
      height: 48,
      child: _buildButton(),
    );
  }

  Widget _buildButton() {
    if (_isDownloading) {
      return Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: CircularProgressIndicator(
              value: _progress > 0 ? _progress : null,
              strokeWidth: 3,
              color: AppColors.accentPrimary,
              backgroundColor: AppColors.bgSurface,
            ),
          ),
          GestureDetector(
            onTap: _cancelDownload,
            child: const Icon(
              Icons.close,
              color: AppColors.textPrimary,
              size: 18,
            ),
          ),
        ],
      );
    }

    if (_isDownloaded) {
      return IconButton(
        onPressed: widget.onPlayOffline,
        icon: const Icon(
          Icons.check_circle,
          color: AppColors.accentPrimary,
          size: 32,
        ),
        tooltip: 'Downloaded - tap to play offline',
      );
    }

    return IconButton(
      onPressed: _startDownload,
      icon: const Icon(
        Icons.download,
        color: AppColors.textSecondary,
        size: 32,
      ),
      tooltip: 'Download for offline viewing',
    );
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    // Do NOT close the download service -- it's a singleton that continues
    // running in the background.
    super.dispose();
  }
}
