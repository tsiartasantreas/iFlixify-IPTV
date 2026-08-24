import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/profile_manager.dart';
import '../../core/data/database.dart';
import '../../core/data/offline_download_service.dart';
import '../../core/data/parental_control_service.dart';
import '../../core/data/supabase_client.dart';
import '../../core/data/sync_coordinator.dart';
import '../../core/entitlement/entitlement_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/pin_dialog.dart';
import '../auth/auth_screen.dart';
import '../offline/offline_screen.dart';
import '../profiles/profile_switcher_screen.dart';
import 'activate_pro_screen.dart';

/// Netflix-style settings screen.
///
/// Displays a list of settings grouped into sections: Profile, Playback,
/// Data, and About. Uses the app's dark theme consistently.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.database});

  /// Database instance -- injectable for testing.
  final AppDatabase? database;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppDatabase? _db;
  late final ProfileManager _profileManager;
  late final EntitlementService _entitlementService;

  // Player settings.
  bool _useExternalPlayer = false;

  // Navigation settings.
  bool _showRadioTab = false;

  // Display mode.
  bool _tvModeEnabled = false;

  // Parental controls.
  bool _parentalPinSet = false;
  bool _hideAdultContent = true; // Default: hidden when PIN is set.

  // Update check state.
  bool _isCheckingForUpdates = false;
  bool _isRefreshing = false;

  // Profile.
  String _profileName = 'User';
  String _profileEmail = '';

  /// Whether Pro features (multi-user profiles, cross-device sync, Continue
  /// Watching, unlimited playlists) are unlocked for the current user.
  /// True for the Pro tier and admins; false for anonymous / free users.
  bool _proFeaturesUnlocked = false;


  @override
  void initState() {
    super.initState();
    _db = widget.database;
    _profileManager = ProfileManager.instance;
    _entitlementService = EntitlementService();
    _loadSettings();
  }

  @override
  void dispose() {
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadSettings() async {
    // Lazily initialize Supabase if needed (user may have arrived via cached
    // auth flag without Supabase being initialized yet).
    if (!SupabaseService.isInitialized) {
      try {
        await SupabaseService.initialize();
      } catch (_) {
        // If initialization fails (e.g. no network), keep guest mode.
      }
    }

    // Load Supabase user info (if signed in).
    await _loadSignedInUserInfo();

    // Sync cloud data (favourites, watch progress) when a session already
    // exists, so returning users sync on app open (initState calls this).
    // No-op when Supabase is unavailable or the user is signed out.
    unawaited(SyncCoordinator.maybeFullSync());

    // Load active profile (fallback for name if no Supabase user).
    final activeProfile = await _profileManager.getActiveProfile();
    if (!mounted) return;
    if (activeProfile != null && _profileName == 'User') {
      setState(() {
        _profileName = activeProfile.displayName;
      });
    }

    // Load tier. Explicitly refresh from Supabase first so a stale cached
    // tier never gates features incorrectly (e.g. after the subscription
    // was purchased, restored, or removed on another device).
    await _entitlementService.refreshTier();
    final tier = await _entitlementService.getTier();
    if (!mounted) return;
    setState(() {
      _proFeaturesUnlocked = tier == 'pro' || _entitlementService.isAdmin;
    });

    // Load player preference and parental control state.
    final prefs = await SharedPreferences.getInstance();
    final pinSet = await ParentalControlService.instance.isPinSet();
    final adultVisible =
        await ParentalControlService.instance.isAdultContentVisible();
    if (!mounted) return;
    setState(() {
      _useExternalPlayer = prefs.getBool('use_external_player') ?? false;
      _showRadioTab = prefs.getBool('show_radio_tab') ?? false;
      _tvModeEnabled = prefs.getBool('tv_mode_enabled') ?? false;
      _parentalPinSet = pinSet;
      _hideAdultContent = !adultVisible;
    });
  }

  // ---------------------------------------------------------------------------
  // Signed-in user info
  // ---------------------------------------------------------------------------

  /// Loads the signed-in user's email, display name, tier, and admin status.
  ///
  /// The display name is preferred from the Supabase `profiles` table
  /// (the account's source of truth); the auth user metadata is used as a
  /// fallback when the profiles row is unreachable. Also reads `tier` and
  /// `is_admin` from the profiles table when available. No-op when signed out.
  Future<void> _loadSignedInUserInfo() async {
    if (!SupabaseService.isInitialized) return;
    final user = SupabaseService.client.auth.currentUser;
    if (user == null) return;

    String? displayName = user.userMetadata?['display_name'] as String?;
    String? profileTier;
    bool? profileIsAdmin;
    try {
      final profile = await SupabaseService.client
          .from('profiles')
          .select('display_name, tier, is_admin')
          .eq('id', user.id)
          .maybeSingle();
      if (profile != null) {
        final tableName = profile['display_name'] as String?;
        if (tableName != null && tableName.isNotEmpty) {
          displayName = tableName;
        }
        profileTier = profile['tier'] as String?;
        profileIsAdmin = profile['is_admin'] as bool?;
      }
    } catch (_) {
      // Network / RLS errors — fall back to the auth user metadata.
    }

    if (!mounted) return;
    setState(() {
      _profileEmail = user.email ?? '';
      if (displayName != null && displayName.isNotEmpty) {
        _profileName = displayName;
      }
      // Apply tier from profiles table if available.
      if (profileTier != null && profileTier.isNotEmpty) {
        _proFeaturesUnlocked =
            profileTier == 'pro' || (profileIsAdmin ?? false);
        }
    });
  }

  // ---------------------------------------------------------------------------
  // Refresh user profile
  // ---------------------------------------------------------------------------

  Future<void> _refreshUserProfile() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);

    try {
      // Re-fetch user info from Supabase.
      if (!SupabaseService.isInitialized) {
        try {
          await SupabaseService.initialize();
        } catch (_) {}
      }

      if (SupabaseService.isInitialized) {
        await _loadSignedInUserInfo();
      }

      // Reload playlist count and download count via _loadSettings.
      await _loadSettings();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile refreshed'),
            backgroundColor: AppColors.bgSurface,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Refresh failed: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Clear Cache',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will clear cached images and temporary files. '
          'Your downloaded content and favourites will not be affected.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Clear',
              style: TextStyle(color: AppColors.accentPrimary),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cache cleared'),
          backgroundColor: AppColors.bgSurface,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _clearEpgData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Clear EPG Data',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will remove all downloaded programme guide data. '
          'It will be re-downloaded on next refresh.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop(true);
            },
            child: const Text(
              'Clear',
              style: TextStyle(color: AppColors.accentPrimary),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      if (_db != null) {
        await _db!.delete(_db!.epgProgrammes).go();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('EPG data cleared'),
            backgroundColor: AppColors.bgSurface,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
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
          'Settings',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
        actions: [
          if (_isRefreshing)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: AppColors.accentPrimary,
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh, color: AppColors.textPrimary),
              onPressed: _refreshUserProfile,
              tooltip: 'Refresh profile',
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // -- Account Status section (top of screen) -------------------------
          _buildAccountStatusSection(),

          const SizedBox(height: 16),

          // -- Profile section -----------------------------------------------
          _buildSectionHeader('Profile'),
          _buildNavigationTile(
            icon: Icons.switch_account,
            title: 'Switch Profile',
            subtitle: 'Manage user profiles',
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ProfileSwitcherScreen()),
              );
            },
          ),

          const SizedBox(height: 16),

          // -- Parental Controls section ------------------------------------
          _buildSectionHeader('Parental Controls'),
          if (_parentalPinSet) ...[
            _buildNavigationTile(
              icon: Icons.lock_outline,
              title: 'Change PIN',
              subtitle: 'Update your parental control PIN',
              onTap: _changeParentalPin,
            ),
            _buildNavigationTile(
              icon: Icons.lock_open,
              title: 'Remove PIN',
              subtitle: 'Disable parental controls',
              onTap: _removeParentalPin,
            ),
          ] else ...[
            _buildNavigationTile(
              icon: Icons.shield_outlined,
              title: 'Set PIN',
              subtitle: 'Restrict adult content with a 4-digit PIN',
              onTap: _setParentalPin,
            ),
          ],
          _buildSwitchTile(
            icon: _hideAdultContent
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            title: _hideAdultContent
                ? 'Adult Content Hidden'
                : 'Adult Content Visible',
            subtitle: _hideAdultContent
                ? 'Adult content is filtered from browse and home screens'
                : 'All content is visible, including adult content',
            value: !_hideAdultContent,
            onChanged: _onAdultContentToggle,
          ),

          const SizedBox(height: 16),

          // -- Data section -------------------------------------------------
          _buildSectionHeader('Data'),
          _buildNavigationTile(
            icon: Icons.download_done_outlined,
            title: 'Downloads',
            subtitle: 'Manage offline content',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OfflineScreen()),
            ),
          ),
          _buildNavigationTile(
            icon: Icons.folder_open_outlined,
            title: 'Open Download Folder',
            subtitle: 'Open the iFlixify Downloads folder in your file manager',
            onTap: _openDownloadFolder,
          ),
          _buildNavigationTile(
            icon: Icons.delete_outline,
            title: 'Clear Cache',
            subtitle: 'Free up storage space',
            onTap: _clearCache,
          ),
          _buildNavigationTile(
            icon: Icons.tv_off,
            title: 'Clear EPG Data',
            subtitle: 'Remove programme guide data',
            onTap: _clearEpgData,
          ),

          const SizedBox(height: 16),

          // -- Player section -----------------------------------------------
          _buildSectionHeader('Player'),
          _buildSwitchTile(
            icon: Icons.open_in_new,
            title: 'External Player',
            subtitle: _useExternalPlayer
                ? 'Opens streams in VLC or your default video player'
                : 'Use the built-in player',
            value: _useExternalPlayer,
            onChanged: (value) async {
              setState(() => _useExternalPlayer = value);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('use_external_player', value);
            },
          ),
          _buildNavigationTile(
            icon: Icons.restore,
            title: 'Reset Player Selection',
            subtitle: 'Choose a different external video player on next play',
            onTap: _resetExternalPlayerSelection,
          ),

          const SizedBox(height: 16),

          // -- Radio section ------------------------------------------------
          _buildSectionHeader('Radio'),
          _buildSwitchTile(
            icon: Icons.radio_outlined,
            title: 'Show Radio tab in bottom navigation',
            subtitle: _showRadioTab
                ? 'Radio tab is visible in the bottom navigation bar'
                : 'Radio tab is hidden from the bottom navigation bar',
            value: _showRadioTab,
            onChanged: (value) async {
              setState(() => _showRadioTab = value);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('show_radio_tab', value);
            },
          ),

          const SizedBox(height: 16),

          // -- Display Mode section ----------------------------------------
          _buildSectionHeader('Display Mode'),
          _buildSwitchTile(
            icon: _tvModeEnabled ? Icons.tv : Icons.phone_android,
            title: _tvModeEnabled ? 'TV Mode' : 'Portable Mode',
            subtitle:
                'Optimize interface for TV (D-pad navigation) or phone/tablet (touch)',
            value: _tvModeEnabled,
            onChanged: (value) async {
              setState(() => _tvModeEnabled = value);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('tv_mode_enabled', value);
            },
          ),

          const SizedBox(height: 16),

          // -- About section ------------------------------------------------
          _buildSectionHeader('About'),
          _buildInfoTile(
            icon: Icons.info_outline,
            title: 'iFlixify IPTV',
            subtitle: 'iFlixify IPTV v6.2.0-beta',
          ),
          _buildNavigationTile(
            icon: Icons.system_update_outlined,
            title: 'Check for Updates',
            subtitle: _isCheckingForUpdates
                ? 'Checking...'
                : 'Check for the latest version',
            onTap: _checkForUpdates,
          ),
          _buildInfoTile(
            icon: Icons.person_outline,
            title: 'Developer',
            subtitle: 'iFlixify Team',
          ),
          _buildNavigationTile(
            icon: Icons.language_outlined,
            title: 'Website',
            subtitle: 'https://iflixify.wasmer.app',
            onTap: () => _launchUrl('https://iflixify.wasmer.app'),
          ),
          _buildNavigationTile(
            icon: Icons.email_outlined,
            title: 'Support',
            subtitle: 'support@iflixify.app',
            onTap: () => _launchUrl('mailto:support@iflixify.app'),
          ),
          _buildNavigationTile(
            icon: Icons.description_outlined,
            title: 'Terms of Service',
            subtitle: 'View terms and conditions',
            onTap: () => _launchUrl('https://iflixify.wasmer.app/terms'),
          ),
          _buildNavigationTile(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy Policy',
            subtitle: 'View privacy policy',
            onTap: () => _launchUrl('https://iflixify.wasmer.app/privacy'),
          ),
          _buildNavigationTile(
            icon: Icons.description_outlined,
            title: 'Licenses',
            subtitle: 'Open source licenses',
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'iFlixify IPTV',
              applicationVersion: '6.2.0-beta',
              applicationIcon: const Icon(
                Icons.live_tv,
                color: AppColors.accentPrimary,
                size: 32,
              ),
              applicationLegalese:
                  'iFlixify IPTV uses an open-source technology stack but is not open-source software itself. All rights reserved. The app is provided as-is for personal use.',
            ),
          ),

          // -- Account section (signed-in only, at the bottom) -------------
          if (_profileEmail.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSectionHeader('Account'),
            if (!_proFeaturesUnlocked) ...[
              _buildNavigationTile(
                icon: Icons.workspace_premium,
                title: 'Upgrade to Pro',
                subtitle:
                    'Unlimited playlists, profiles & sync — \$8.99 lifetime',
                onTap: _navigateToActivatePro,
              ),
            ] else ...[
              _buildInfoTile(
                icon: Icons.check_circle_outline,
                title: 'iFlixify Pro — Active ✓',
                subtitle: 'All Pro features are unlocked',
              ),
            ],
            _buildNavigationTile(
              icon: Icons.logout,
              title: 'Sign Out',
              subtitle: _profileEmail,
              onTap: _showSignOutDialog,
              isDestructive: true,
            ),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section header
  // ---------------------------------------------------------------------------

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.horizontalPadding,
        8,
        AppTheme.horizontalPadding,
        4,
      ),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Hero auth banner (logged-out state)
  // ---------------------------------------------------------------------------
  // Account Status section (top of settings)
  // ---------------------------------------------------------------------------

  Widget _buildAccountStatusSection() {
    // Not logged in — prompt to sign in.
    if (_profileEmail.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: AppTheme.horizontalPadding),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            const Text(
              'Sign in to sync your data across devices',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton(
                      onPressed: () => _navigateToAuth(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accentPrimary,
                        foregroundColor: AppColors.textPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text(
                        'Sign In',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      onPressed: () => _navigateToAuth(initialSignUp: true),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textPrimary,
                        side: const BorderSide(color: AppColors.bgSurface),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text(
                        'Create Account',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // Logged in + Pro user.
    if (_proFeaturesUnlocked) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: AppTheme.horizontalPadding),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.green.withValues(alpha: 0.4),
            width: 1,
          ),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: GestureDetector(
                    onTap: _showEditNameDialog,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            _profileName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.edit,
                          size: 14,
                          color: AppColors.textSecondary.withValues(alpha: 0.6),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              _profileEmail,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            const Text(
              '✨ Pro Member',
              style: TextStyle(
                color: Colors.greenAccent,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Thank you for being a Pro user!',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    // Logged in + Free user.
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppTheme.horizontalPadding),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: GestureDetector(
                  onTap: _showEditNameDialog,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          _profileName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.edit,
                        size: 14,
                        color: AppColors.textSecondary.withValues(alpha: 0.6),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _profileEmail,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          const Text(
            "You're on the Free plan",
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton(
              onPressed: _navigateToActivatePro,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentPrimary,
                foregroundColor: AppColors.textPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Upgrade to Pro - \$8.99',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Switch tile
  // ---------------------------------------------------------------------------

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(
        title,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
        ),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppColors.accentPrimary,
        activeTrackColor: AppColors.accentPrimary.withValues(alpha: 0.3),
        inactiveTrackColor: AppColors.bgSurface,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Navigation tile
  // ---------------------------------------------------------------------------

  Widget _buildNavigationTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return ListTile(
      leading: Icon(
        icon,
        color: isDestructive ? Colors.red : AppColors.textSecondary,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: isDestructive ? Colors.red : AppColors.textPrimary,
          fontSize: 16,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: AppColors.textSecondary.withValues(alpha: 0.5),
      ),
      onTap: onTap,
    );
  }

  // ---------------------------------------------------------------------------
  // Info tile (non-interactive)
  // ---------------------------------------------------------------------------

  Widget _buildInfoTile({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(
        title,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 16,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 13,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------


  void _navigateToAuth({bool initialSignUp = false}) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuthScreen(initialSignUp: initialSignUp),
      ),
    );
    // Reload settings when returning — the user may have signed in.
    _loadSettings();
    // Kick off a cloud sync now that the user may have signed in (no-op when
    // still signed out).
    unawaited(SyncCoordinator.maybeFullSync());
  }

  /// Opens the Activate Pro upsell screen.
  void _navigateToActivatePro() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ActivateProScreen()),
    );
    // Reload settings when returning — the tier may have changed (restore).
    if (mounted) {
      _loadSettings();
    }
  }

  void _showSignOutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Sign Out',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'Are you sure you want to sign out?',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              final navigator = Navigator.of(context);
              navigator.pop(); // Close the dialog.
              // Only sign out if Supabase is initialized (user is authenticated).
              if (SupabaseService.isInitialized) {
                await AuthService().signOut();
              }
              // Clear the cached auth flag.
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('auth_user_email');
              // Reload settings to show the Sign In / Register option.
              if (mounted) {
                setState(() {
                  _profileEmail = '';
                  _profileName = 'User';
                  _proFeaturesUnlocked = false;
                });
                _loadSettings();
              }
            },
            child: const Text(
              'Sign Out',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Edit display name
  // ---------------------------------------------------------------------------

  void _showEditNameDialog() {
    final controller = TextEditingController(text: _profileName);
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Edit Display Name',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              hintText: 'Enter your display name',
              hintStyle: TextStyle(color: AppColors.textSecondary),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.bgSurface),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.accentPrimary),
              ),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Name cannot be empty';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              final newName = controller.text.trim();
              Navigator.of(context).pop();
              await _updateDisplayName(newName);
            },
            child: const Text(
              'Save',
              style: TextStyle(color: AppColors.accentPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _updateDisplayName(String newName) async {
    try {
      if (SupabaseService.isInitialized) {
        final user = SupabaseService.client.auth.currentUser;
        if (user != null) {
          await SupabaseService.client
              .from('profiles')
              .update({'display_name': newName}).eq('id', user.id);
        }
      }

      if (mounted) {
        setState(() => _profileName = newName);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Display name updated'),
            backgroundColor: AppColors.bgSurface,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update name: $e'),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Parental controls
  // ---------------------------------------------------------------------------

  Future<void> _setParentalPin() async {
    final saved = await showPinSetDialog(context);
    if (saved && mounted) {
      setState(() => _parentalPinSet = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Parental PIN set. Adult content is now locked.'),
          backgroundColor: AppColors.bgSurface,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _changeParentalPin() async {
    final saved = await showPinSetDialog(context, isChanging: true);
    if (saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Parental PIN changed.'),
          backgroundColor: AppColors.bgSurface,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _removeParentalPin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Remove Parental PIN',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'This will unlock all content, including adult content. '
          'Are you sure?',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Remove',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await ParentalControlService.instance.removePin();
      setState(() => _parentalPinSet = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Parental PIN removed. All content is unlocked.'),
            backgroundColor: AppColors.bgSurface,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // URL launcher helper
  // ---------------------------------------------------------------------------

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open $url'),
            backgroundColor: AppColors.bgSurface,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Check for updates
  // ---------------------------------------------------------------------------

  Future<void> _checkForUpdates() async {
    setState(() => _isCheckingForUpdates = true);

    try {
      // Open the latest release page directly.
      await _launchUrl('https://iflixify.wasmer.app/dl/latest');
    } finally {
      if (mounted) {
        setState(() => _isCheckingForUpdates = false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Adult content toggle
  // ---------------------------------------------------------------------------

  Future<void> _onAdultContentToggle(bool showAdult) async {
    // Unconditional preference update — no PIN is ever required here.
    // The PIN is only used by the explicit "unlock" button on the
    // home/browse screens, and only when a PIN is actually set.
    await ParentalControlService.instance.setAdultContentVisible(showAdult);
    if (mounted) {
      setState(() => _hideAdultContent = !showAdult);
    }
  }

  // ---------------------------------------------------------------------------
  // Open download folder
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Reset external player selection
  // ---------------------------------------------------------------------------

  Future<void> _resetExternalPlayerSelection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('external_player_package');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Player selection reset. You will be asked to choose a player on next play.'),
          backgroundColor: AppColors.bgSurface,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Open download folder
  // ---------------------------------------------------------------------------

  Future<void> _openDownloadFolder() async {
    try {
      final downloadPath = await OfflineDownloadService.instance.downloadDirectoryPath;
      if (downloadPath.isNotEmpty) {
        await OpenFilex.open(downloadPath);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Download folder not found'),
              backgroundColor: AppColors.bgSurface,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Settings] Failed to open download folder: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open download folder'),
            backgroundColor: AppColors.bgSurface,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}
