import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config/tv_mode.dart';
import '../../core/data/database.dart';
import '../../core/data/offline_download_service.dart';
import '../../core/data/watch_progress_service.dart';
import '../../core/player/player_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/animated_focus.dart';
import '../player/player_screen.dart';
import '../player/tv_player_screen.dart';

/// Netflix-style "Downloads" screen showing locally stored content.
///
/// Displays a grid of downloaded items with thumbnails, titles, and file sizes.
/// Shows active and queued downloads with progress indicators.
/// Supports tap-to-play and long-press-to-delete.
class OfflineScreen extends StatefulWidget {
  const OfflineScreen({
    super.key,
    this.tabChangeNotifier,
    this.tabIndex = 0,
    this.onExploreContent,
  });

  /// Notifier from the parent shell that fires when the active tab changes.
  final ValueNotifier<int>? tabChangeNotifier;

  /// The index of this tab in the parent shell's navigation.
  final int tabIndex;

  /// Called when the user taps "Explore Content" in the empty state.
  /// Typically switches the parent shell to the Movies tab.
  final VoidCallback? onExploreContent;

  @override
  State<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends State<OfflineScreen> {
  final _downloadService = OfflineDownloadService.instance;
  final _watchService = WatchProgressService();
  List<DownloadedItem> _items = [];
  Map<String, DownloadProgress> _activeDownloads = {};
  bool _isLoading = true;
  StreamSubscription<Map<String, DownloadProgress>>? _progressSub;

  /// Tracks the last seen tab-change notifier value so we only reload when
  /// the tab actually changes (not on the initial build).
  int _lastSeenChangeCount = 0;

  // TV mode follows the shared single source of truth (the user's "TV Mode"
  // toggle), not a device-size heuristic — TV focus visuals and D-pad support
  // must apply wherever the user enabled TV mode.
  bool get _isTv => TvMode.instance.isEnabled;

  @override
  void initState() {
    super.initState();
    debugPrint('[OfflineScreen] initState: loading downloaded items from DB');
    _loadItems();
    _listenToProgress();
    // Listen for tab changes from the parent shell.
    widget.tabChangeNotifier?.addListener(_onTabChange);
  }

  void _listenToProgress() {
    // Load initial state.
    _activeDownloads = _downloadService.currentProgress;

    _progressSub = _downloadService.progressStream.listen((progressMap) {
      if (!mounted) return;

      // Check if any download just completed -- refresh the DB list.
      final hasNewCompleted = progressMap.values.any(
        (p) =>
            p.state == DownloadState.completed &&
            (_activeDownloads[p.contentId]?.state != DownloadState.completed),
      );

      setState(() {
        _activeDownloads = progressMap;
      });

      if (hasNewCompleted) {
        debugPrint(
          '[OfflineScreen] new download completed, refreshing DB list',
        );
        _loadItems();
      }
    });
  }

  /// Called when the parent shell switches tabs. Reloads items if this
  /// screen just became visible (skips the initial build).
  void _onTabChange() {
    if (!mounted) return;
    final currentValue = widget.tabChangeNotifier!.value;
    if (currentValue == _lastSeenChangeCount) return;
    _lastSeenChangeCount = currentValue;
    _loadItems();
  }

  Future<void> _loadItems() async {
    debugPrint('[OfflineScreen] _loadItems: querying downloaded items...');
    try {
      final items = await _downloadService.getDownloadedItems();
      debugPrint(
        '[OfflineScreen] _loadItems: got ${items.length} items from DB',
      );
      if (mounted) {
        setState(() {
          _items = items;
          _isLoading = false;
        });
      }
    } catch (e, st) {
      debugPrint('[OfflineScreen] _loadItems: ERROR querying DB: $e');
      debugPrint('[OfflineScreen] _loadItems: stack trace: $st');
      if (mounted) {
        setState(() {
          _items = [];
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _playItem(DownloadedItem item) async {
    // Map the download key (e.g. "vod_42", "series_ep_12") to the
    // polymorphic watch-progress key ("vod:42", "episode:12") so offline
    // playback also records progress and resumes where the user left off.
    String? watchContentId;
    if (item.contentId.startsWith('series_ep_')) {
      watchContentId =
          'episode:${item.contentId.substring('series_ep_'.length)}';
    } else {
      final parts = item.contentId.split('_');
      if (parts.length == 2) {
        watchContentId = '${parts[0]}:${parts[1]}';
      }
    }

    // Look up saved watch progress so playback resumes from the same
    // position as online playback (same rule as DetailScreen: resume when
    // > 30 s in and < 95% watched).
    Duration? startPosition;
    if (watchContentId != null) {
      try {
        final progress = await _watchService.getProgress(watchContentId);
        if (progress != null &&
            progress.positionMs > 30000 &&
            progress.durationMs > 0 &&
            progress.positionMs < progress.durationMs * 0.95) {
          startPosition = Duration(milliseconds: progress.positionMs);
        }
      } catch (e) {
        debugPrint('[OfflineScreen] Failed to load watch progress: $e');
      }
    }

    if (!mounted) return;
    final controller = PlayerController();
    // Don't autoplay when resuming from a saved position — the player
    // screen seeks first (mirrors DetailScreen's open pattern).
    await controller.open(
      item.filePath,
      autoPlay: startPosition == null || startPosition <= Duration.zero,
    );

    if (!mounted) {
      // The screen went away while opening — release the controller.
      controller.dispose();
      return;
    }

    final playerScreen = _isTv
        ? TvPlayerScreen(
            controller: controller,
            title: item.title,
            contentId: watchContentId,
            startPosition: startPosition,
          )
        : PlayerScreen(
            controller: controller,
            title: item.title,
            contentId: watchContentId,
            startPosition: startPosition,
          );

    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => playerScreen))
        .then((_) => controller.dispose());
  }

  void _showItemContextMenu(DownloadedItem item, Offset position) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      color: AppColors.bgElevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: [
        const PopupMenuItem<String>(
          value: 'play',
          child: Row(
            children: [
              Icon(Icons.play_arrow, color: AppColors.accentPrimary, size: 20),
              SizedBox(width: 12),
              Text('Play', style: TextStyle(color: AppColors.textPrimary)),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'open_location',
          child: Row(
            children: [
              Icon(Icons.folder_open, color: AppColors.textSecondary, size: 20),
              SizedBox(width: 12),
              Text(
                'Open File Location',
                style: TextStyle(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'share',
          child: Row(
            children: [
              Icon(Icons.share, color: AppColors.textSecondary, size: 20),
              SizedBox(width: 12),
              Text('Share', style: TextStyle(color: AppColors.textPrimary)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
              SizedBox(width: 12),
              Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'play':
          _playItem(item);
          break;
        case 'open_location':
          _openFileLocation(item);
          break;
        case 'share':
          _shareItem(item);
          break;
        case 'delete':
          _deleteItem(item);
          break;
      }
    });
  }

  Future<void> _openFileLocation(DownloadedItem item) async {
    try {
      final file = File(item.filePath);
      if (!await file.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File not found on disk'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      // Open the file itself with the system default handler. On Android this
      // will open the file manager at the containing folder when no suitable
      // app is found, or show the file in the Downloads UI.
      final result = await OpenFilex.open(
        item.filePath,
        type: _getMimeType(item.contentType),
      );

      if (result.type != ResultType.done && mounted) {
        // Fallback: try opening the parent directory.
        final parentDir = file.parent.path;
        await OpenFilex.open(parentDir);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open file location: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  String? _getMimeType(String contentType) {
    switch (contentType) {
      case 'movie':
      case 'series':
        return 'video/mp4';
      case 'radio':
        return 'audio/mpeg';
      default:
        return null;
    }
  }

  Future<void> _shareItem(DownloadedItem item) async {
    try {
      final file = File(item.filePath);
      if (!await file.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File not found on disk'),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      await Share.shareXFiles([XFile(item.filePath)], text: item.title);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not share file: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _deleteItem(DownloadedItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Delete Download',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          'Remove "${item.title}" from your downloads?',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _downloadService.deleteDownload(item.contentId);
      await _loadItems();
    }
  }

  void _cancelActiveDownload(String contentId) {
    _downloadService.cancelDownload(contentId);
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Returns active downloads (queued or currently downloading), excluding
  /// completed/failed/cancelled.
  List<DownloadProgress> get _inProgressDownloads {
    return _activeDownloads.values
        .where(
          (p) =>
              p.state == DownloadState.queued ||
              p.state == DownloadState.downloading,
        )
        .toList();
  }

  Future<void> _onRefresh() async {
    await _loadItems();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Downloads',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accentPrimary),
            )
          : _items.isEmpty && _inProgressDownloads.isEmpty
          ? _buildEmptyState()
          : RefreshIndicator(
              color: AppColors.accentPrimary,
              backgroundColor: AppColors.bgElevated,
              onRefresh: _onRefresh,
              child: _buildContent(),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.download_done_outlined,
              size: 80,
              color: AppColors.textSecondary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 24),
            const Text(
              'No Downloads Yet',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Download movies and series to watch offline',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 32),
            SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                onPressed:
                    widget.onExploreContent ??
                    () => Navigator.of(
                      context,
                    ).popUntil((route) => route.isFirst),
                icon: const Icon(Icons.explore),
                label: const Text('Explore Content'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentPrimary,
                  foregroundColor: AppColors.textPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final totalSize = _items.fold<int>(0, (sum, item) => sum + item.fileSize);
    final active = _inProgressDownloads;

    return CustomScrollView(
      slivers: [
        // -- Storage usage banner ------------------------------------------
        SliverToBoxAdapter(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: AppColors.bgElevated,
            child: Row(
              children: [
                const Icon(
                  Icons.storage,
                  color: AppColors.textSecondary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '${_items.length} downloads  \u00B7  ${_formatFileSize(totalSize)}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),

        // -- Active downloads section -------------------------------------
        if (active.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.only(
                left: 16,
                right: 16,
                top: 12,
                bottom: 4,
              ),
              child: Text(
                'Downloading (${active.length})',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildActiveDownloadTile(active[index]),
              childCount: active.length,
            ),
          ),
        ],

        // -- Completed downloads grid -------------------------------------
        if (_items.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _isTv ? 5 : 3,
                childAspectRatio: 0.55,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildDownloadCard(_items[index]),
                childCount: _items.length,
              ),
            ),
          )
        else if (active.isNotEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'Completed downloads will appear here',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildActiveDownloadTile(DownloadProgress progress) {
    final isQueued = progress.state == DownloadState.queued;

    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CircularProgressIndicator(
              value: isQueued
                  ? null
                  : (progress.progress > 0 ? progress.progress : null),
              strokeWidth: 3,
              color: AppColors.accentPrimary,
              backgroundColor: AppColors.bgSurface,
            ),
            if (!isQueued)
              Text(
                '${(progress.progress * 100).toInt()}%',
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              )
            else
              const Icon(
                Icons.hourglass_bottom,
                color: AppColors.textSecondary,
                size: 16,
              ),
          ],
        ),
      ),
      title: Text(
        progress.title,
        style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        isQueued ? 'Queued...' : 'Downloading...',
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, color: AppColors.textSecondary, size: 20),
        onPressed: () => _cancelActiveDownload(progress.contentId),
      ),
    );
  }

  Widget _buildDownloadCard(DownloadedItem item) {
    final card = GestureDetector(
      onTap: () => _playItem(item),
      onLongPressStart: (details) =>
          _showItemContextMenu(item, details.globalPosition),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -- Thumbnail ----------------------------------------------------
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: AppColors.bgSurface,
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Poster image (if available).
                  if (item.thumbnailUrl != null &&
                      item.thumbnailUrl!.isNotEmpty)
                    Image.network(
                      item.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _buildPlaceholderIcon(item.contentType),
                    )
                  else
                    _buildPlaceholderIcon(item.contentType),

                  // Play overlay icon.
                  Center(
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        color: AppColors.textPrimary,
                        size: 28,
                      ),
                    ),
                  ),

                  // Content type badge.
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.contentType.toUpperCase(),
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 6),

          // -- Title --------------------------------------------------------
          Text(
            item.title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),

          // -- File size ----------------------------------------------------
          Text(
            _formatFileSize(item.fileSize),
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );

    // TV parity: the card gets a visible focus ring and D-pad activation
    // (select/enter/space/A) mirroring the touch tap-to-play action.
    if (!_isTv) return card;
    return AnimatedFocus(
      isTv: true,
      child: Focus(
        autofocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent || event is KeyRepeatEvent) {
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.space ||
                key == LogicalKeyboardKey.gameButtonA) {
              _playItem(item);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: card,
      ),
    );
  }

  Widget _buildPlaceholderIcon(String contentType) {
    IconData icon;
    switch (contentType) {
      case 'movie':
        icon = Icons.movie;
        break;
      case 'series':
        icon = Icons.tv;
        break;
      case 'radio':
        icon = Icons.radio;
        break;
      default:
        icon = Icons.play_circle_outline;
    }

    return Center(child: Icon(icon, color: AppColors.bgElevated, size: 48));
  }

  @override
  void dispose() {
    widget.tabChangeNotifier?.removeListener(_onTabChange);
    _progressSub?.cancel();
    // Do NOT close the download service -- it's a singleton.
    super.dispose();
  }
}
