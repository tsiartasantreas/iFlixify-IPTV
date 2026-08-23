import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/data/offline_download_service.dart';
import '../../../core/theme/app_colors.dart';

/// A compact download button for episode list tiles.
///
/// Shows a cloud_download icon when idle, a small circular progress indicator
/// while downloading, and a checkmark when downloaded.
class EpisodeDownloadButton extends StatefulWidget {
  const EpisodeDownloadButton({
    super.key,
    required this.contentId,
    required this.title,
    required this.url,
    this.thumbnailUrl,
    this.onPlayOffline,
  });

  final String contentId;
  final String title;
  final String url;
  final String? thumbnailUrl;
  final VoidCallback? onPlayOffline;

  @override
  State<EpisodeDownloadButton> createState() => _EpisodeDownloadButtonState();
}

class _EpisodeDownloadButtonState extends State<EpisodeDownloadButton> {
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
      contentType: 'series',
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
    if (_isDownloading) {
      return GestureDetector(
        onTap: _cancelDownload,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  strokeWidth: 2.5,
                  color: AppColors.accentPrimary,
                  backgroundColor: AppColors.bgSurface,
                ),
              ),
              const Icon(
                Icons.close,
                color: AppColors.textPrimary,
                size: 14,
              ),
            ],
          ),
        ),
      );
    }

    if (_isDownloaded) {
      return GestureDetector(
        onTap: widget.onPlayOffline,
        child: const Icon(
          Icons.check_circle,
          color: AppColors.accentPrimary,
          size: 28,
        ),
      );
    }

    return GestureDetector(
      onTap: _startDownload,
      child: const Icon(
        Icons.cloud_download_outlined,
        color: AppColors.textSecondary,
        size: 28,
      ),
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
