import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/skeleton.dart';
import '../application/auth_controller.dart';

/// Drives the backend's web Google OAuth inside a WebView and captures the
/// session token from the final redirect (`/#auth=<token>`), then stores it
/// and refreshes auth state — reusing exactly the flow the web app uses.
///
/// The Worker must have GOOGLE_CLIENT_ID set; until then
/// `/api/auth/google/start` returns 501 and the WebView shows that message.
class GoogleSignInScreen extends ConsumerStatefulWidget {
  const GoogleSignInScreen({super.key});

  @override
  ConsumerState<GoogleSignInScreen> createState() => _GoogleSignInScreenState();
}

class _GoogleSignInScreenState extends ConsumerState<GoogleSignInScreen> {
  late final WebViewController _controller;
  bool _handled = false;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Black, not the WebView's default white, so a failed/slow load never
      // flashes a white page under our own overlay.
      ..setBackgroundColor(AppColors.bg)
      ..setNavigationDelegate(NavigationDelegate(
        onUrlChange: (change) => _inspect(change.url),
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        // Offline / server unreachable: swap the WebView's raw browser error
        // page (which leaks the workers.dev URL) for a clean message of ours.
        onWebResourceError: (error) {
          if (_handled) return;
          if (error.isForMainFrame ?? true) {
            if (mounted) setState(() { _error = true; _loading = false; });
          }
        },
        onNavigationRequest: (request) {
          // Intercept the final app redirect before the WebView navigates to
          // it, so we never actually render the token-bearing page.
          if (_looksLikeResult(request.url)) {
            _inspect(request.url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse('$kApiBaseUrl/api/auth/google/start'));
  }

  bool _looksLikeResult(String? url) =>
      url != null && (url.contains('#auth=') || url.contains('authError='));

  Future<void> _inspect(String? url) async {
    if (_handled || url == null) return;

    if (url.contains('#auth=')) {
      _handled = true;
      final token = Uri.decodeComponent(url.split('#auth=').last.split('&').first);
      await ref.read(authTokenStorageProvider).write(token);
      ref.invalidate(authControllerProvider);
      if (mounted) context.pop(true);
      return;
    }

    if (url.contains('authError=')) {
      _handled = true;
      if (mounted) context.pop(false);
    }
  }

  void _retry() {
    setState(() { _error = false; _loading = true; });
    _controller.loadRequest(Uri.parse('$kApiBaseUrl/api/auth/google/start'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('Continue with Google', style: AppTypography.sans(fontSize: 16))),
      body: _error
          ? _OfflineView(onRetry: _retry)
          : Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_loading)
                  const ColoredBox(
                    color: AppColors.bg,
                    child: Center(child: LoadingDots(size: 8)),
                  ),
              ],
            ),
    );
  }
}

/// Shown instead of the browser's own "Webpage not available" page (which
/// exposes the API domain) when the OAuth page can't load — offline, etc.
class _OfflineView extends StatelessWidget {
  const _OfflineView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, color: AppColors.muted, size: 44),
            const SizedBox(height: 16),
            Text('No internet connection',
                style: AppTypography.sans(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Check your connection and try again.',
                textAlign: TextAlign.center,
                style: AppTypography.sans(fontSize: 14, color: AppColors.muted)),
            const SizedBox(height: 20),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
