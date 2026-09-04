import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single source of truth for TV mode.
///
/// TV mode is controlled exclusively by the user preference
/// `tv_mode_enabled` (the "TV Mode" toggle in Settings). Both touch and
/// D-pad input remain enabled at all times.
class TvMode extends ChangeNotifier {
  TvMode._();
  static final TvMode instance = TvMode._();

  bool _enabled = false;
  bool _loaded = false;

  bool get isEnabled => _enabled;

  /// Whether the preference has been loaded from disk at least once.
  bool get isLoaded => _loaded;

  /// Loads the preference at app startup.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('tv_mode_enabled') ?? false;
    _loaded = true;
    notifyListeners();
  }

  /// Sets TV mode and persists the preference.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tv_mode_enabled', value);
    notifyListeners();
  }
}

/// InheritedWidget so the whole widget tree can read TV mode reactively.
class TvModeScope extends InheritedNotifier<TvMode> {
  const TvModeScope({super.key, required TvMode notifier, required super.child})
      : super(notifier: notifier);

  static bool of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<TvModeScope>();
    return scope?.notifier?.isEnabled ?? false;
  }
}
