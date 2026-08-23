import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/data/background_download_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  BackgroundDownloadService.initialize();

  if (Env.isSentryConfigured) {
    await SentryFlutter.init(
      (options) {
        options.dsn = Env.sentryDsn;
        options.tracesSampleRate = 0.2;
        options.environment = const String.fromEnvironment(
          'APP_ENV',
          defaultValue: 'production',
        );
        options.release = const String.fromEnvironment(
          'APP_VERSION',
          defaultValue: '1.0.0',
        );
      },
      appRunner: () =>
          runApp(const WithForegroundTask(child: FlixiumApp())),
    );
  } else {
    runApp(const WithForegroundTask(child: FlixiumApp()));
  }
}
