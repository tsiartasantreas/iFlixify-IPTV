import 'package:flutter/material.dart';

import '../../core/data/database.dart';
import '../../core/entitlement/entitlement_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/auth/profile_manager.dart';

/// Netflix-style "Who's watching?" profile switcher screen.
///
/// Displays a grid of profile avatars with colored circles and initials.
/// Users can tap to switch profiles, long-press to edit/delete, and
/// add new profiles (Pro only).
class ProfileSwitcherScreen extends StatefulWidget {
  const ProfileSwitcherScreen({super.key, this.profileManager});

  /// Injectable for testing.
  final ProfileManager? profileManager;

  @override
  State<ProfileSwitcherScreen> createState() => _ProfileSwitcherScreenState();
}

class _ProfileSwitcherScreenState extends State<ProfileSwitcherScreen> {
  late final ProfileManager _profileManager;
  List<UserProfile> _profiles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _profileManager = widget.profileManager ?? ProfileManager.instance;
    _loadProfiles();
  }

  // ---------------------------------------------------------------------------
  // Data loading
  // ---------------------------------------------------------------------------

  Future<void> _loadProfiles() async {
    final profiles = await _profileManager.getProfiles();
    if (mounted) {
      setState(() {
        _profiles = profiles;
        _isLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _switchProfile(UserProfile profile) async {
    await _profileManager.switchProfile(profile.id);
    if (mounted) {
      Navigator.of(context).pop(profile);
    }
  }

  Future<void> _addProfile() async {
    // The FIRST profile is always allowed — without one a free user could
    // never use profiles at all. Additional profiles are Pro-gated.
    if (_profiles.isNotEmpty) {
      final entitlement = EntitlementService();
      final isPro = await entitlement.getTier() == 'pro';

      if (!isPro) {
        if (mounted) {
          _showProUpsellDialog();
        }
        return;
      }
    }

    final name = await _showCreateProfileDialog();
    if (name != null && name.isNotEmpty) {
      try {
        await _profileManager.createProfile(name);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString()),
              backgroundColor: AppColors.bgSurface,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
      await _loadProfiles();
    }
  }

  void _editProfile(UserProfile profile) {
    _showEditProfileDialog(profile);
  }

  Future<void> _deleteProfile(UserProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Delete Profile',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: Text(
          'Delete "${profile.displayName}"? This cannot be undone.',
          style: const TextStyle(color: AppColors.textSecondary),
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
              'Delete',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _profileManager.deleteProfile(profile.id);
        await _loadProfiles();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString()),
              backgroundColor: AppColors.bgSurface,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  Future<String?> _showCreateProfileDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'New Profile',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Enter display name',
            hintStyle: TextStyle(color: AppColors.textSecondary),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.bgSurface),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.accentPrimary),
            ),
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
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
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text(
              'Create',
              style: TextStyle(color: AppColors.accentPrimary),
            ),
          ),
        ],
      ),
    );
  }

  void _showEditProfileDialog(UserProfile profile) {
    final controller = TextEditingController(text: profile.displayName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Edit Profile',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Enter display name',
            hintStyle: TextStyle(color: AppColors.textSecondary),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.bgSurface),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.accentPrimary),
            ),
          ),
          autofocus: true,
          textCapitalization: TextCapitalization.words,
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
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                await _profileManager.updateProfile(
                  profile.id,
                  displayName: name,
                );
                await _loadProfiles();
              }
              if (!mounted) return;
              // ignore: use_build_context_synchronously
              Navigator.of(context).pop();
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

  void _showProUpsellDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text(
          'Pro Feature',
          style: TextStyle(color: AppColors.textPrimary),
        ),
        content: const Text(
          'Multiple profiles are a Pro feature. '
          'Upgrade to create additional profiles for your family.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'OK',
              style: TextStyle(color: AppColors.accentPrimary),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Extracts initials from a display name (max 2 characters).
  String _getInitials(String name) {
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.isEmpty) return '?';
    if (words.length == 1) return words[0][0].toUpperCase();
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgBase,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Who's watching?",
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: AppColors.accentPrimary,
              ),
            )
          : Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.horizontalPadding,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Empty-state hint.
                    if (_profiles.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 24),
                        child: Text(
                          'No profiles yet — create one to get started.',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    // Profile grid.
                    Expanded(
                      child: Center(
                        child: Wrap(
                          spacing: 32,
                          runSpacing: 32,
                          alignment: WrapAlignment.center,
                          children: [
                            ..._profiles.map(_buildProfileAvatar),
                            _buildAddProfileButton(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildProfileAvatar(UserProfile profile) {
    final isActive = profile.isActive;
    final avatarColor = Color(profile.avatarColor);

    return GestureDetector(
      onTap: () => _switchProfile(profile),
      onLongPress: () => _showProfileOptions(profile),
      child: SizedBox(
        width: 120,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Avatar circle.
            Stack(
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: avatarColor,
                    shape: BoxShape.circle,
                    border: isActive
                        ? Border.all(
                            color: AppColors.textPrimary,
                            width: 3,
                          )
                        : null,
                  ),
                  child: Center(
                    child: Text(
                      _getInitials(profile.displayName),
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 36,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                // Active checkmark.
                if (isActive)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: const BoxDecoration(
                        color: AppColors.accentPrimary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.check,
                        color: AppColors.textPrimary,
                        size: 18,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Display name.
            Text(
              profile.displayName,
              style: TextStyle(
                color: isActive
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
                fontSize: 14,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddProfileButton() {
    return GestureDetector(
      onTap: _addProfile,
      child: SizedBox(
        width: 120,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: AppColors.bgSurface,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.textSecondary.withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: Icon(
                Icons.add,
                color: AppColors.textSecondary.withValues(alpha: 0.7),
                size: 40,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Add Profile',
              style: TextStyle(
                color: AppColors.textSecondary.withValues(alpha: 0.7),
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _showProfileOptions(UserProfile profile) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Profile Options',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: AppColors.textSecondary),
              title: const Text(
                'Edit Profile',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              onTap: () {
                Navigator.of(context).pop();
                _editProfile(profile);
              },
            ),
            if (!profile.isActive)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text(
                  'Delete Profile',
                  style: TextStyle(color: Colors.redAccent),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _deleteProfile(profile);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
