import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../core/data/background_download_service.dart';
import '../../core/data/database.dart';
import '../../core/data/import_progress_service.dart';
import '../../core/data/m3u_parser.dart';
import '../../core/data/m3u_url_parser.dart';
import '../../core/data/playlist_manager.dart';
import '../../core/data/xtream_importer.dart';
import '../../core/theme/app_colors.dart';
import '../settings/activate_pro_screen.dart';

/// The user-selected import method.
enum ImportType {
  /// Standard M3U playlist URL.
  m3u,

  /// Xtream Codes: base URL + username + password.
  xtream,
}

/// Playlist import screen.
///
/// Users can choose between M3U URL or Xtream Codes import, select which
/// content types to import, view existing playlists, and remove them.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => ImportScreenState();
}

@visibleForTesting
class ImportScreenState extends State<ImportScreen> {
  // --- Text controllers -------------------------------------------------------
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  // --- State ------------------------------------------------------------------
  final _db = AppDatabase();
  late final PlaylistManager _playlistManager;
  List<Playlist> _playlists = [];
  bool _isLoading = false;
  String? _errorMessage;

  /// Set when the import failed because the free playlist limit was hit;
  /// shows an "Upgrade to Pro" call-to-action below the error.
  bool _freeLimitReached = false;

  /// Which import method the user has selected (defaults to M3U).
  ImportType _importType = ImportType.m3u;

  /// Stream type selection.
  bool _importLive = true;
  bool _importMovies = true;
  bool _importSeries = true;
  bool _importRadio = false;

  @override
  void initState() {
    super.initState();
    _playlistManager = PlaylistManager(database: _db);
    _loadPlaylists();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data operations
  // ---------------------------------------------------------------------------

  Future<void> _loadPlaylists() async {
    final playlists = await _playlistManager.getPlaylists();
    if (mounted) {
      setState(() => _playlists = playlists);
    }
  }

  /// Kicks off the import in the background and navigates back to the home
  /// screen immediately. The [ImportProgressService] tracks progress so the
  /// home screen can display it.
  Future<void> _addPlaylist() async {
    // Clear previous error.
    setState(() {
      _errorMessage = null;
      _freeLimitReached = false;
    });

    // --- Validate inputs based on selected import type ------------------------
    if (_importType == ImportType.m3u) {
      final url = _urlController.text.trim();
      if (url.isEmpty) {
        setState(() => _errorMessage = 'Please enter an M3U URL');
        return;
      }
    } else {
      // Xtream Codes validation.
      final url = _urlController.text.trim();
      final username = _usernameController.text.trim();
      final password = _passwordController.text.trim();

      if (url.isEmpty) {
        setState(() => _errorMessage = 'Please enter the server URL');
        return;
      }
      if (username.isEmpty) {
        setState(() => _errorMessage = 'Please enter your username');
        return;
      }
      if (password.isEmpty) {
        setState(() => _errorMessage = 'Please enter your password');
        return;
      }
    }

    // --- Validate content type selection --------------------------------------
    if (_importType == ImportType.xtream) {
      if (!_importLive && !_importMovies && !_importSeries) {
        setState(
            () => _errorMessage = 'Please select at least one content type');
        return;
      }
    }

    // --- Create playlist record, then run import in background ---------------
    setState(() => _isLoading = true);

    try {
      if (_importType == ImportType.xtream) {
        await _startBackgroundXtreamImport();
      } else {
        await _startBackgroundM3uImport();
      }

      _urlController.clear();
      _usernameController.clear();
      _passwordController.clear();

      // Navigate back to home immediately after the playlist record is created.
      // The actual import continues in the background via ImportProgressService.
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          // StateError from PlaylistManager = free playlist limit reached.
          // Show its friendly message instead of "Bad state: ...".
          _freeLimitReached = e is StateError;
          _errorMessage =
              e is StateError ? e.message : 'Import failed: $e';
          _isLoading = false;
        });
      }
    }
    // Note: _isLoading is intentionally NOT reset on success because the
    // screen is popped. It is only reset on error so the user can retry.
  }

  // ---------------------------------------------------------------------------
  // Background Xtream import
  // ---------------------------------------------------------------------------

  /// Creates the playlist record and starts the Xtream import in a background
  /// [Future] that continues after navigation.
  Future<void> _startBackgroundXtreamImport() async {
    final rawUrl = _urlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    // Extract base URL: strip path/query if the user pasted a full
    // get.php URL, otherwise use the URL as-is.
    String baseUrl;
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      throw const FormatException('Invalid server URL');
    }
    if (uri.queryParameters.containsKey('username') ||
        uri.queryParameters.containsKey('password')) {
      baseUrl = Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      ).toString();
    } else {
      baseUrl = rawUrl.replaceAll(RegExp(r'/+$'), '');
    }

    // Build the set of selected content types.
    final selectedTypes = <XtreamContentType>{};
    if (_importLive) selectedTypes.add(XtreamContentType.live);
    if (_importMovies) selectedTypes.add(XtreamContentType.vod);
    if (_importSeries) selectedTypes.add(XtreamContentType.series);

    // Create the playlist record synchronously so we have the ID.
    final playlist = await _playlistManager.addPlaylist(
      '$username@$baseUrl',
      baseUrl,
      username: username,
      password: password,
    );

    // Fire-and-forget: the import continues in the background after we
    // navigate away. Progress is tracked via ImportProgressService.
    // ignore: unawaited_futures
    ImportProgressService.instance.startXtreamImport(
      db: _db,
      playlistManager: _playlistManager,
      playlistId: playlist.id,
      baseUrl: baseUrl,
      username: username,
      password: password,
      importTypes: selectedTypes,
    );
  }

  // ---------------------------------------------------------------------------
  // Background M3U import
  // ---------------------------------------------------------------------------

  /// Creates the playlist record and starts the M3U import in a background
  /// [Future] that continues after navigation.
  Future<void> _startBackgroundM3uImport() async {
    final url = _urlController.text.trim();

    // Auto-detect if the URL is actually an Xtream get.php URL.
    final urlInfo = M3uUrlParser.parse(url);
    if (urlInfo.isXtream) {
      // Switch to Xtream flow using parsed credentials.
      _usernameController.text = urlInfo.username ?? '';
      _passwordController.text = urlInfo.password ?? '';
      if (mounted) {
        setState(() => _importType = ImportType.xtream);
      }
      await _startBackgroundXtreamImport();
      return;
    }

    // Create the playlist record.
    final playlist = await _playlistManager.addPlaylist(
      'Playlist ${_playlists.length + 1}',
      url,
    );

    // Fire-and-forget the M3U import in the background.
    // ignore: unawaited_futures
    _runM3uImportInBackground(playlist.id, url);
  }

  /// Runs the M3U fetch + parse + insert in the background.
  Future<void> _runM3uImportInBackground(int playlistId, String url) async {
    final progress = ImportProgressService.instance;
    progress.progressNotifier.value = ImportProgress(
      playlistName: url,
      message: 'Fetching M3U playlist...',
      progress: 0.0,
      isComplete: false,
    );

    // Keep the foreground service alive so the import continues even when
    // the app is minimised or the screen is off.
    final bgService = BackgroundDownloadService.instance;
    await bgService.incrementTaskCount(
      notificationText: 'Importing playlist...',
    );

    try {
      final response = await http.get(Uri.parse(url)).timeout(
            const Duration(seconds: 30),
          );
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      progress.progressNotifier.value = ImportProgress(
        playlistName: url,
        message: 'Parsing playlist...',
        progress: 0.3,
        isComplete: false,
      );

      final result = M3uParser.parse(response.body);

      if (result.totalItems == 0) {
        throw Exception('No items found in playlist');
      }

      final channels = result.channels;
      final vodItems = result.vodItems;
      final seriesList = result.series;
      final radioStations = result.radioStations;

      progress.progressNotifier.value = ImportProgress(
        playlistName: url,
        message: 'Saving channels...',
        progress: 0.5,
        isComplete: false,
      );

      for (final ch in channels) {
        await _db.into(_db.channels).insert(
              ChannelsCompanion.insert(
                playlistId: playlistId,
                name: ch.name,
                logo: drift.Value(ch.logo),
                url: ch.url,
                groupTitle: drift.Value(ch.groupTitle),
                tvgName: drift.Value(ch.tvgName),
              ),
            );
      }

      for (final vod in vodItems) {
        await _db.into(_db.vodItems).insert(
              VodItemsCompanion.insert(
                playlistId: playlistId,
                title: vod.title,
                poster: drift.Value(vod.poster),
                url: vod.url,
                groupTitle: drift.Value(vod.groupTitle),
              ),
            );
      }

      for (final s in seriesList) {
        final seriesId = await _db.into(_db.tvSeries).insert(
              TvSeriesCompanion.insert(
                playlistId: playlistId,
                title: s.title,
                poster: drift.Value(s.poster),
              ),
            );
        for (final ep in s.episodes) {
          await _db.into(_db.episodes).insert(
                EpisodesCompanion.insert(
                  seriesId: seriesId,
                  season: ep.season,
                  episode: ep.episode,
                  title: ep.title,
                  url: ep.url,
                  thumbnail: drift.Value(ep.thumbnail),
                ),
              );
        }
      }

      for (final radio in radioStations) {
        await _db.into(_db.radioStations).insert(
              RadioStationsCompanion.insert(
                playlistId: playlistId,
                name: radio.name,
                logo: drift.Value(radio.logo),
                url: radio.url,
              ),
            );
      }

      progress.progressNotifier.value = ImportProgress(
        playlistName: url,
        message: 'Import complete',
        progress: 1.0,
        isComplete: true,
        channels: channels.length,
        vodItems: vodItems.length,
        series: seriesList.length,
        radio: radioStations.length,
      );
    } catch (e) {
      progress.progressNotifier.value = ImportProgress(
        playlistName: url,
        message: 'Import failed: $e',
        progress: 0.0,
        isComplete: true,
        error: e.toString(),
      );
    } finally {
      await bgService.decrementTaskCount(
        notificationText: 'Import finished.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Playlist management
  // ---------------------------------------------------------------------------

  Future<void> _removePlaylist(Playlist playlist) async {
    await _playlistManager.deletePlaylist(playlist.id);
    await _loadPlaylists();
  }

  // ---------------------------------------------------------------------------
  // Pro upsell
  // ---------------------------------------------------------------------------

  /// Opens the Activate Pro screen when the free playlist limit blocks
  /// an import.
  Future<void> _openActivatePro() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ActivateProScreen()),
    );
    // Re-check entitlement — the tier may have changed after a restore.
    if (mounted) {
      _loadPlaylists();
    }
  }

  // ---------------------------------------------------------------------------
  // Edit playlist
  // ---------------------------------------------------------------------------

  /// Opens an edit dialog pre-filled with the decrypted credentials of
  /// [playlist]. On save, updates the record and optionally re-imports.
  void _editPlaylist(Playlist playlist) {
    final decryptedUrl = _playlistManager.getDecryptedUrl(playlist);
    final decryptedUsername = _playlistManager.getDecryptedUsername(playlist);
    final decryptedPassword = _playlistManager.getDecryptedPassword(playlist);

    final editUrlController = TextEditingController(text: decryptedUrl);
    final editUsernameController =
        TextEditingController(text: decryptedUsername ?? '');
    final editPasswordController =
        TextEditingController(text: decryptedPassword ?? '');
    final editNameController = TextEditingController(text: playlist.name);

    final isXtream = decryptedUsername != null && decryptedUsername.isNotEmpty;

    showDialog(
      context: context,
      builder: (ctx) => _EditPlaylistDialog(
        playlist: playlist,
        isXtream: isXtream,
        nameController: editNameController,
        urlController: editUrlController,
        usernameController: editUsernameController,
        passwordController: editPasswordController,
        playlistManager: _playlistManager,
        db: _db,
        onSaved: () {
          _loadPlaylists();
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Import Playlists',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
      body: FocusTraversalGroup(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // -- Import type selector ----------------------------------------
              _buildImportTypeSelector(),
              const SizedBox(height: 16),

              // -- Input fields (conditional on import type) -------------------
              _buildInputFields(),
              const SizedBox(height: 16),

              // -- Stream type checkboxes --------------------------------------
              _buildStreamTypeCheckboxes(),
              const SizedBox(height: 16),

              // -- Add button -------------------------------------------------
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _addPlaylist,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentPrimary,
                    foregroundColor: AppColors.textPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    _isLoading ? 'Starting import...' : 'Add Playlist',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),

              // -- Error message -----------------------------------------------
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 14),
                ),
                if (_freeLimitReached)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _openActivatePro,
                        icon: const Icon(
                          Icons.workspace_premium,
                          size: 18,
                          color: AppColors.accentPrimary,
                        ),
                        label: const Text(
                          'Upgrade to Pro',
                          style: TextStyle(color: AppColors.accentPrimary),
                        ),
                      ),
                    ),
                  ),
              ],

              const SizedBox(height: 24),

              // -- Imported playlists header ------------------------------------
              const Text(
                'Imported Playlists',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),

              // -- Playlist list ------------------------------------------------
              _playlists.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No playlists imported yet.\nAdd a playlist above.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = _playlists[index];
                        return _buildPlaylistTile(playlist);
                      },
                    ),

              const SizedBox(height: 12),

              // -- Skip button (navigate to home) ------------------------------
              SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.bgSurface),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text('Skip for now'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Import type selector (toggle at the top)
  // ---------------------------------------------------------------------------

  Widget _buildImportTypeSelector() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildTypeTab(
              label: 'M3U URL',
              icon: Icons.link,
              type: ImportType.m3u,
            ),
          ),
          Expanded(
            child: _buildTypeTab(
              label: 'Xtream Codes',
              icon: Icons.dns,
              type: ImportType.xtream,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeTab({
    required String label,
    required IconData icon,
    required ImportType type,
  }) {
    final isSelected = _importType == type;
    return GestureDetector(
      onTap: () {
        if (_importType != type) {
          setState(() {
            _importType = type;
            _errorMessage = null;
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.accentPrimary.withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(
                  color: AppColors.accentPrimary.withValues(alpha: 0.5))
              : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color:
                  isSelected ? AppColors.accentPrimary : AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: isSelected
                    ? AppColors.accentPrimary
                    : AppColors.textSecondary,
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Input fields (changes based on import type)
  // ---------------------------------------------------------------------------

  Widget _buildInputFields() {
    if (_importType == ImportType.m3u) {
      return _buildM3UFields();
    } else {
      return _buildXtreamFields();
    }
  }

  Widget _buildM3UFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _urlController,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: 'M3U URL',
            labelStyle: const TextStyle(color: AppColors.textSecondary),
            hintText: 'https://example.com/playlist.m3u',
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.bgSurface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            prefixIcon: const Icon(
              Icons.link,
              color: AppColors.accentPrimary,
              size: 20,
            ),
          ),
          onSubmitted: (_) => _addPlaylist(),
        ),
      ],
    );
  }

  Widget _buildXtreamFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Server URL field.
        TextField(
          controller: _urlController,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: 'Server URL',
            labelStyle: const TextStyle(color: AppColors.textSecondary),
            hintText: 'https://server.com:8080',
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.bgSurface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            prefixIcon: const Icon(
              Icons.dns,
              color: AppColors.accentPrimary,
              size: 20,
            ),
          ),
          onSubmitted: (_) => _addPlaylist(),
        ),
        const SizedBox(height: 8),

        // Username field.
        TextField(
          controller: _usernameController,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: 'Username',
            labelStyle: const TextStyle(color: AppColors.textSecondary),
            hintText: 'Enter Xtream username',
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.bgSurface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            prefixIcon: const Icon(
              Icons.person,
              color: AppColors.accentPrimary,
              size: 20,
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Password field.
        TextField(
          controller: _passwordController,
          obscureText: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: 'Password',
            labelStyle: const TextStyle(color: AppColors.textSecondary),
            hintText: 'Enter Xtream password',
            hintStyle: const TextStyle(color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.bgSurface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            prefixIcon: const Icon(
              Icons.lock,
              color: AppColors.accentPrimary,
              size: 20,
            ),
          ),
          onSubmitted: (_) => _addPlaylist(),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Stream type checkboxes (always visible)
  // ---------------------------------------------------------------------------

  Widget _buildStreamTypeCheckboxes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Content to import',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _buildContentTypeChip(
              label: 'Live TV',
              icon: Icons.live_tv,
              value: _importLive,
              onChanged: (v) => setState(() => _importLive = v),
            ),
            _buildContentTypeChip(
              label: 'Movies',
              icon: Icons.movie,
              value: _importMovies,
              onChanged: (v) => setState(() => _importMovies = v),
            ),
            _buildContentTypeChip(
              label: 'Series',
              icon: Icons.tv,
              value: _importSeries,
              onChanged: (v) => setState(() => _importSeries = v),
            ),
            _buildContentTypeChip(
              label: 'Radio',
              icon: Icons.radio,
              value: _importRadio,
              onChanged: (v) => setState(() => _importRadio = v),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Playlist tile
  // ---------------------------------------------------------------------------

  Widget _buildPlaylistTile(Playlist playlist) {
    // Decrypt the URL for display.
    final displayUrl = _playlistManager.getDecryptedUrl(playlist);
    return Card(
      color: AppColors.bgElevated,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: const Icon(
          Icons.playlist_play,
          color: AppColors.accentPrimary,
          size: 32,
        ),
        title: Text(
          playlist.name,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          displayUrl,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.select) {
                  _editPlaylist(playlist);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: IconButton(
                icon: const Icon(Icons.edit_outlined,
                    color: AppColors.accentPrimary),
                onPressed: () => _editPlaylist(playlist),
                tooltip: 'Edit playlist',
              ),
            ),
            Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.select) {
                  _confirmRemove(playlist);
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: IconButton(
                icon:
                    const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: () => _confirmRemove(playlist),
                tooltip: 'Remove playlist',
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Content type chip
  // ---------------------------------------------------------------------------

  Widget _buildContentTypeChip({
    required String label,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: value ? AppColors.textPrimary : AppColors.textSecondary,
          ),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
      selected: value,
      onSelected: onChanged,
      backgroundColor: AppColors.bgSurface,
      selectedColor: AppColors.accentPrimary.withValues(alpha: 0.2),
      checkmarkColor: AppColors.accentPrimary,
      labelStyle: TextStyle(
        color: value ? AppColors.textPrimary : AppColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      side: BorderSide(
        color: value
            ? AppColors.accentPrimary.withValues(alpha: 0.5)
            : AppColors.bgSurface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    );
  }

  // ---------------------------------------------------------------------------
  // Confirm remove dialog
  // ---------------------------------------------------------------------------

  void _confirmRemove(Playlist playlist) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Remove Playlist',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          'Remove "${playlist.name}" and all its content?',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _removePlaylist(playlist);
            },
            child: const Text(
              'Remove',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Edit Playlist Dialog
// =============================================================================

/// A dialog for editing an existing playlist's name, URL, and credentials.
class _EditPlaylistDialog extends StatefulWidget {
  const _EditPlaylistDialog({
    required this.playlist,
    required this.isXtream,
    required this.nameController,
    required this.urlController,
    required this.usernameController,
    required this.passwordController,
    required this.playlistManager,
    required this.db,
    required this.onSaved,
  });

  final Playlist playlist;
  final bool isXtream;
  final TextEditingController nameController;
  final TextEditingController urlController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final PlaylistManager playlistManager;
  final AppDatabase db;
  final VoidCallback onSaved;

  @override
  State<_EditPlaylistDialog> createState() => _EditPlaylistDialogState();
}

class _EditPlaylistDialogState extends State<_EditPlaylistDialog> {
  bool _isSaving = false;
  String? _error;
  bool _reImport = false;

  Future<void> _save() async {
    final name = widget.nameController.text.trim();
    final url = widget.urlController.text.trim();

    if (name.isEmpty || url.isEmpty) {
      setState(() => _error = 'Name and URL are required');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      await widget.playlistManager.updatePlaylist(
        widget.playlist.id,
        name: name,
        url: url,
        username:
            widget.isXtream ? widget.usernameController.text.trim() : null,
        password:
            widget.isXtream ? widget.passwordController.text.trim() : null,
      );

      // Optionally re-import content.
      if (_reImport) {
        // Delete existing content for this playlist.
        await widget.playlistManager.deletePlaylist(widget.playlist.id);
        // Re-add the playlist (creates a fresh record).
        final newPlaylist = await widget.playlistManager.addPlaylist(
          name,
          url,
          username:
              widget.isXtream ? widget.usernameController.text.trim() : null,
          password:
              widget.isXtream ? widget.passwordController.text.trim() : null,
        );

        // Start background re-import if Xtream.
        if (widget.isXtream) {
          final username = widget.usernameController.text.trim();
          final password = widget.passwordController.text.trim();

          String baseUrl;
          final uri = Uri.tryParse(url);
          if (uri != null &&
              (uri.queryParameters.containsKey('username') ||
                  uri.queryParameters.containsKey('password'))) {
            baseUrl = Uri(
              scheme: uri.scheme,
              host: uri.host,
              port: uri.hasPort ? uri.port : null,
            ).toString();
          } else {
            baseUrl = url.replaceAll(RegExp(r'/+$'), '');
          }

          // ignore: unawaited_futures
          ImportProgressService.instance.startXtreamImport(
            db: widget.db,
            playlistManager: widget.playlistManager,
            playlistId: newPlaylist.id,
            baseUrl: baseUrl,
            username: username,
            password: password,
            importTypes: {
              XtreamContentType.live,
              XtreamContentType.vod,
              XtreamContentType.series,
            },
          );
        }
      }

      widget.onSaved();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Save failed: $e';
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Text(
        'Edit Playlist',
        style: TextStyle(color: AppColors.textPrimary),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Name field.
            TextField(
              controller: widget.nameController,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Name',
                labelStyle: const TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.bgSurface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // URL field.
            TextField(
              controller: widget.urlController,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: widget.isXtream ? 'Server URL' : 'M3U URL',
                labelStyle: const TextStyle(color: AppColors.textSecondary),
                filled: true,
                fillColor: AppColors.bgSurface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),

            // Xtream-specific fields.
            if (widget.isXtream) ...[
              const SizedBox(height: 12),
              TextField(
                controller: widget.usernameController,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Username',
                  labelStyle: const TextStyle(color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.bgSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: widget.passwordController,
                obscureText: true,
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Password',
                  labelStyle: const TextStyle(color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.bgSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 16),

            // Re-import toggle.
            CheckboxListTile(
              value: _reImport,
              onChanged: (v) => setState(() => _reImport = v ?? false),
              title: const Text(
                'Re-import content',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
              ),
              subtitle: const Text(
                'Delete existing channels and re-fetch from source',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              activeColor: AppColors.accentPrimary,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),

            // Error message.
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accentPrimary,
                  ),
                )
              : const Text(
                  'Save',
                  style: TextStyle(color: AppColors.accentPrimary),
                ),
        ),
      ],
    );
  }
}
