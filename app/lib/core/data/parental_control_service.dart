import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages parental control settings: PIN storage, verification, and
/// adult-content detection.
///
/// Uses a singleton pattern so the PIN state is shared across the app.
/// The PIN is stored as a SHA-256 hash in SharedPreferences under the
/// key `parental_pin_hash`.
class ParentalControlService {
  ParentalControlService._();

  static final ParentalControlService _instance = ParentalControlService._();

  /// Returns the shared singleton instance.
  static ParentalControlService get instance => _instance;

  /// SharedPreferences key for the hashed PIN.
  static const _pinHashKey = 'parental_pin_hash';

  /// SharedPreferences key for the PIN salt.
  static const _pinSaltKey = 'parental_pin_salt';

  /// SharedPreferences key for the hide-adult-content preference.
  static const _hideAdultContentKey = 'hide_adult_content';

  /// Set of rating strings considered adult-only.
  static const _adultRatings = {
    '18+',
    'r18',
    'nc-17',
    'x',
    'xxx',
    'adult',
  };

  // ---------------------------------------------------------------------------
  // PIN management
  // ---------------------------------------------------------------------------

  /// Hashes [pin] with a random salt using SHA-256 and stores both the
  /// salt and the hash in SharedPreferences.
  Future<void> setPin(String pin) async {
    final salt = _generateSalt();
    final hash = _hashPin(pin, salt);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pinHashKey, hash);
    await prefs.setString(_pinSaltKey, salt);
  }

  /// Returns `true` if [pin] matches the stored hash (verified against the
  /// stored salt).
  Future<bool> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final storedHash = prefs.getString(_pinHashKey);
    final storedSalt = prefs.getString(_pinSaltKey);
    if (storedHash == null || storedSalt == null) return false;
    return _hashPin(pin, storedSalt) == storedHash;
  }

  /// Returns `true` if a parental PIN has been configured.
  Future<bool> isPinSet() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_pinHashKey);
  }

  /// Removes the stored PIN and salt, effectively unlocking all content.
  Future<void> removePin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pinHashKey);
    await prefs.remove(_pinSaltKey);
  }

  /// Returns `true` if adult content should be hidden (i.e. the visibility
  /// preference is off and the user has not temporarily unlocked the
  /// session).
  ///
  /// This drives the browse/home filtering and never requires a PIN by
  /// itself — hiding or showing content is a plain preference (see
  /// [setAdultContentVisible]). The PIN is only used by the explicit
  /// "unlock" flow (see [unlockTemporarily]).
  Future<bool> isAdultContentLocked() async {
    if (_temporarilyUnlocked) return false;
    return !await isAdultContentVisible();
  }

  /// Whether the user has temporarily unlocked adult content for this
  /// app session. The flag resets when the app is killed.
  bool _temporarilyUnlocked = false;

  /// Returns `true` if the user has entered their PIN to temporarily
  /// show adult content during this app session.
  bool get isUnlocked => _temporarilyUnlocked;

  /// Unlocks adult content for the rest of the current app session.
  ///
  /// Call this after verifying the user's PIN. The unlock is lost when the
  /// process terminates (i.e. the app is fully closed, not just backgrounded).
  void unlockTemporarily() {
    _temporarilyUnlocked = true;
  }

  /// Re-locks adult content (e.g. user taps the lock button again).
  void lockAgain() {
    _temporarilyUnlocked = false;
  }

  // ---------------------------------------------------------------------------
  // Adult content visibility preference
  // ---------------------------------------------------------------------------

  /// Returns `true` if adult content should be visible.
  ///
  /// Reflects the stored preference directly, regardless of whether a PIN
  /// is set. Defaults to `true` (visible) when no PIN is set and the
  /// preference has never been changed; defaults to `false` (hidden) when
  /// a PIN is set and the preference has never been changed.
  Future<bool> isAdultContentVisible() async {
    final prefs = await SharedPreferences.getInstance();
    final pinSet = await isPinSet();
    final hidden = prefs.getBool(_hideAdultContentKey) ?? pinSet;
    return !hidden;
  }

  /// Sets whether adult content should be visible.
  ///
  /// This is a plain preference: it is saved unconditionally and never
  /// requires a PIN. The PIN is only used for the explicit "unlock" flow
  /// (see [unlockTemporarily]).
  Future<void> setAdultContentVisible(bool visible) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hideAdultContentKey, !visible);
  }

  // ---------------------------------------------------------------------------
  // Adult content detection
  // ---------------------------------------------------------------------------

  /// Determines whether the given content should be considered adult.
  ///
  /// Checks three criteria (any match returns `true`):
  /// 1. [isAdult] field is `"1"` or `"true"` (from the database).
  /// 2. [title] contains `"XXX"` (case-insensitive).
  /// 3. [rating] matches a known adult rating (case-insensitive).
  static bool isAdultContent({
    required String title,
    String? rating,
    String? isAdult,
  }) {
    // Check the database flag.
    if (isAdult != null) {
      final normalized = isAdult.trim().toLowerCase();
      if (normalized == '1' || normalized == 'true') return true;
    }

    // Check title for "XXX".
    if (title.toUpperCase().contains('XXX')) return true;

    // Check rating against known adult ratings.
    if (rating != null && rating.isNotEmpty) {
      final normalizedRating = rating.trim().toLowerCase();
      if (_adultRatings.contains(normalizedRating)) return true;
    }

    return false;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Generates a random 16-byte hex salt.
  static String _generateSalt() {
    final random = Random.secure();
    final saltBytes = List<int>.generate(16, (_) => random.nextInt(256));
    return saltBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Returns the SHA-256 hex digest of [salt] + [pin].
  static String _hashPin(String pin, String salt) {
    final bytes = utf8.encode(salt + pin);
    return sha256.convert(bytes).toString();
  }
}
