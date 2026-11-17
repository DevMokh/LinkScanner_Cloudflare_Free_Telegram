import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'security_policy.dart';

/// Change this URL to the HTTPS homepage of the site you are authorized to
/// display inside the app.
const String startUrl = 'https://example.com/';

/// Explicit allowlist. Add each trusted hostname separately.
/// Do not add broad or unrelated domains.
const Set<String> allowedHosts = {
  'example.com',
};

/// Optional HTTPS endpoint on a server you control.
/// Leave empty to disable startup notifications.
/// Telegram credentials must exist only on that server, never in this APK.
const String notificationEndpoint =
    String.fromEnvironment('NOTIFICATION_ENDPOINT', defaultValue: '');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LinkScannerApp());
}

class LinkScannerApp extends StatelessWidget {
  const LinkScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Link Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const WebViewScreen(),
    );
  }
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;
  int _progress = 0;
  String? _errorMessage;
  bool _controllerReady = false;

  @override
  void initState() {
    super.initState();
    _initializeWebView();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _askForNotificationConsent();
    });
  }

  void _initializeWebView() {
    final initialUri = Uri.tryParse(startUrl);
    if (initialUri == null ||
        !isAllowedWebUri(initialUri, allowedHosts)) {
      _controllerReady = false;
      _isLoading = false;
      _errorMessage =
          'إعداد رابط البداية غير صحيح أو أن النطاق غير موجود في قائمة السماح.';
      return;
    }

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              _progress = progress;
              _isLoading = progress < 100;
            });
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
              _errorMessage = null;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _progress = 100;
            });
          },
          onWebResourceError: (error) {
            if (!error.isForMainFrame || !mounted) return;
            setState(() {
              _isLoading = false;
              _errorMessage =
                  'تعذر تحميل الصفحة. تحقق من اتصال الإنترنت أو إعدادات النطاق.';
            });
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null || !isAllowedWebUri(uri, allowedHosts)) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    _controllerReady = true;
    _controller.loadRequest(initialUri);
  }

  Future<void> _askForNotificationConsent() async {
    if (!mounted || notificationEndpoint.isEmpty) return;

    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إشعارات التطبيق'),
        content: const Text(
          'هل توافق على إرسال إشعار تشغيل عام إلى خادم التطبيق؟ '
          'لن يتم إرسال محتوى التصفح أو بيانات الجهاز.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('رفض'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('موافقة'),
          ),
        ],
      ),
    );

    if (approved == true) {
      await _sendStartupEvent();
    }
  }

  Future<void> _sendStartupEvent() async {
    final endpoint = Uri.tryParse(notificationEndpoint);
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        (endpoint.hasPort && endpoint.port != 443)) {
      return;
    }

    try {
      final response = await http
          .post(
            endpoint,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(const {
              'event': 'app_started',
              'application': 'LinkScanner',
              'version': '1.1.0',
            }),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('Startup notification endpoint returned an error.');
      }
    } catch (_) {
      // Notification failure must never prevent the WebView from working.
      debugPrint('Startup notification could not be delivered.');
    }
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (!mounted) return;

    var message = status.isGranted
        ? 'تم منح إذن الكاميرا'
        : 'لم يتم منح إذن الكاميرا';

    if (status.isPermanentlyDenied) {
      message = 'الإذن مرفوض نهائيًا. يمكنك مراجعته من إعدادات التطبيق.';
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: status.isPermanentlyDenied
            ? SnackBarAction(
                label: 'الإعدادات',
                onPressed: openAppSettings,
              )
            : null,
      ),
    );
  }

  Future<void> _reload() async {
    if (!_controllerReady) return;
    setState(() {
      _errorMessage = null;
      _isLoading = true;
      _progress = 0;
    });
    await _controller.reload();
  }

  Future<void> _goBack() async {
    if (!_controllerReady) return;
    if (await _controller.canGoBack()) {
      await _controller.goBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link Scanner'),
        actions: [
          IconButton(
            tooltip: 'إعادة تحميل',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading && _controllerReady)
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress / 100,
              minHeight: 3,
            ),
          Expanded(
            child: Stack(
              children: [
                if (_controllerReady)
                  WebViewWidget(controller: _controller),
                if (_isLoading && _controllerReady)
                  const Center(child: CircularProgressIndicator()),
                if (_errorMessage != null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.security, size: 48),
                              const SizedBox(height: 12),
                              Text(
                                _errorMessage!,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: _reload,
                                child: const Text('إعادة المحاولة'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: 'رجوع',
              onPressed: _goBack,
              icon: const Icon(Icons.arrow_back),
            ),
            IconButton(
              tooltip: 'تحديث',
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'طلب إذن الكاميرا',
              onPressed: _requestCameraPermission,
              icon: const Icon(Icons.camera_alt),
            ),
          ],
        ),
      ),
    );
  }
}