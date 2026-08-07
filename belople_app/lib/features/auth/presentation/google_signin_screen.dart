import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
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

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onUrlChange: (change) => _inspect(change.url),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('Continue with Google', style: AppTypography.sans(fontSize: 16))),
      body: WebViewWidget(controller: _controller),
    );
  }
}
