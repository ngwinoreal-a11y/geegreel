import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/push/push_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/application/auth_controller.dart';

class BelopleApp extends ConsumerWidget {
  const BelopleApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The device token is only useful once it's attached to an account, and at
    // launch nobody may be signed in yet — /push/device would 401 and the phone
    // would never receive anything. Re-register the moment a user appears.
    ref.listen(authControllerProvider, (previous, next) {
      final wasSignedIn = previous?.valueOrNull != null;
      final isSignedIn = next.valueOrNull != null;
      if (isSignedIn && !wasSignedIn) ref.read(pushServiceProvider).start();
    });

    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Belople',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
