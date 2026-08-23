/// Reads build-time config supplied via `--dart-define`.
///
/// Centralizes env access so secrets never leak into widgets. The Supabase
/// anon key is safe to ship; the service-role key MUST NEVER appear here.
class Env {
  Env._();

  // Supabase project URL — public knowledge, safe to hardcode.
  static const String _supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://zosckkklctvrsjqjmyiv.supabase.co',
  );

  // Supabase anon key (JWT format) — safe to ship in client apps.
  // Required for supabase_flutter SDK compatibility.
  static const String _supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inpvc2Nra2tsY3R2cnNqcWpteWl2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYyODA2NDAsImV4cCI6MjEwMTg1NjY0MH0.bVAxexYv9e7Jo8PLRwYVyzLi6L9PFvxE3M8ZIheMmmA',
  );

  static String get supabaseUrl {
    if (_supabaseUrl.isEmpty) {
      throw StateError(
        'SUPABASE_URL not set. Run with --dart-define=SUPABASE_URL=...',
      );
    }
    return _supabaseUrl;
  }

  static String get supabaseAnonKey {
    if (_supabaseAnonKey.isEmpty) {
      throw StateError(
        'SUPABASE_ANON_KEY not set. Run with --dart-define=SUPABASE_ANON_KEY=...',
      );
    }
    return _supabaseAnonKey;
  }

  /// True when both are configured. Lets the app run a placeholder in CI / first
  /// boot before Supabase wiring exists.
  static bool get isConfigured =>
      _supabaseUrl.isNotEmpty && _supabaseAnonKey.isNotEmpty;

  // Sentry DSN for crash reporting. Replace with your actual DSN from sentry.io
  static const String _sentryDsn = String.fromEnvironment(
    'SENTRY_DSN',
    defaultValue: '', // Empty = disabled
  );

  static String get sentryDsn => _sentryDsn;
  static bool get isSentryConfigured => _sentryDsn.isNotEmpty;
}
