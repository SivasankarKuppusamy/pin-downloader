import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() => runApp(const PinVideoApp());

class PinVideoApp extends StatelessWidget {
  const PinVideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFBD081C);
    return MaterialApp(
      title: 'PinVideo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: red),
        scaffoldBackgroundColor: const Color(0xFFF7F7F8),
        useMaterial3: true,
      ),
      home: const DownloaderPage(),
    );
  }
}

class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});

  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> {
  final _url = TextEditingController();
  final _dio = Dio();
  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  WebViewController? _webController;

  bool _busy = false;
  double _progress = 0;
  String _status =
      'Share a Pin from Pinterest into this app, or paste a link below.';
  String _quality = '720';
  bool _pageChecked = false;

  @override
  void initState() {
    super.initState();
    _initShareHandling();
  }

  Future<void> _initShareHandling() async {
    // Links shared while the app is already running (ACTION_SEND text/plain).
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (items) {
        final candidate = _firstUrl(items.map((item) => item.path).join('\n'));
        if (candidate != null && mounted) {
          setState(() {
            _url.text = candidate;
            _status = 'Link received from Share. Tap “Find video”.';
            _pageChecked = false;
          });
        }
        ReceiveSharingIntent.instance.reset();
      },
      onError: (_) {},
    );

    // Link shared while the app was closed.
    try {
      final items = await ReceiveSharingIntent.instance.getInitialMedia();
      final candidate = _firstUrl(items.map((item) => item.path).join('\n'));
      if (candidate != null && mounted) {
        setState(() {
          _url.text = candidate;
          _status = 'Link received from Share. Tap “Find video”.';
        });
      }
      ReceiveSharingIntent.instance.reset();
    } catch (_) {
      // User can still paste a link manually.
    }
  }

  String? _firstUrl(String text) {
    final match = RegExp(r'https?://[^\s]+', caseSensitive: false)
        .firstMatch(text);
    if (match == null) return null;
    return match.group(0)!.replaceAll(RegExp(r'[),.;]+$'), '');
  }

  bool _isPinterestOrDirectUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    final host = uri.host.toLowerCase();
    return host == 'pinterest.com' ||
        host.endsWith('.pinterest.com') ||
        host == 'pinterest.in' ||
        host.endsWith('.pinterest.in') ||
        host == 'pin.it' ||
        host.endsWith('.pin.it') ||
        uri.path.toLowerCase().endsWith('.mp4') ||
        uri.path.toLowerCase().endsWith('.m4v') ||
        uri.path.toLowerCase().endsWith('.mov') ||
        uri.path.toLowerCase().endsWith('.webm');
  }

  Future<void> _findVideo() async {
    final value = _url.text.trim();
    if (!_isPinterestOrDirectUrl(value)) {
      setState(() => _status = 'Enter a valid HTTPS Pinterest link or direct video URL.');
      return;
    }

    final uri = Uri.parse(value);
    final isDirect = RegExp(r'\.(mp4|m4v|mov|webm)$', caseSensitive: false)
        .hasMatch(uri.path);

    if (isDirect) {
      setState(() {
        _pageChecked = true;
        _status = 'Direct video URL detected. You can download it below.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Opening public Pin page to look for an exposed video URL…';
      _pageChecked = false;
    });

    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onWebResourceError: (error) {
            // Ignore subresource failures; final extraction result is shown below.
          },
        ))
        ..loadRequest(uri);
      _webController = controller;
      // Rebuild now so WebViewWidget is attached before JavaScript is queried.
      if (mounted) setState(() {});

      // Wait for dynamic public page content to load. This is best-effort and
      // intentionally does not sign in, defeat restrictions, or access private Pins.
      await Future<void>.delayed(const Duration(seconds: 7));
      final current = await controller.currentUrl();
      if (current == null) throw Exception('The Pin page did not load.');

      final result = await controller.runJavaScriptReturningResult(r'''
        (() => {
          const candidates = [];
          document.querySelectorAll('video').forEach(v => {
            if (v.currentSrc) candidates.push(v.currentSrc);
            if (v.src) candidates.push(v.src);
            v.querySelectorAll('source').forEach(s => {
              if (s.src) candidates.push(s.src);
            });
          });
          ['og:video', 'og:video:url', 'twitter:player:stream'].forEach(key => {
            const el = document.querySelector('meta[property="' + key + '"], meta[name="' + key + '"]');
            if (el && el.content) candidates.push(el.content);
          });
          return JSON.stringify([...new Set(candidates)].filter(x => /^https?:/i.test(x)));
        })()
      ''');

      final candidate = _parseJsString(result);
      if (candidate != null && mounted) {
        _url.text = candidate;
        setState(() {
          _pageChecked = true;
          _status = 'Found a video URL exposed by the page. Try downloading it.';
        });
      } else if (mounted) {
        setState(() {
          _pageChecked = false;
          _status = 'No direct video URL was exposed. This Pin may need a supported local extractor; no server is configured.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = 'Could not inspect this Pin. Try a public Pin or paste a direct video URL.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _parseJsString(Object result) {
    // The JS returns a JSON string array. Pick the first exposed HTTP(S) URL.
    return _decodeCandidateArray(result.toString());
  }

  String? _decodeCandidateArray(String raw) {
    // Avoid depending on JS return wrapper details: pick the first URL in output.
    final match = RegExp(r'https?://[^"\s\\]+').firstMatch(raw);
    if (match == null) return null;
    final value = match.group(0)!;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    return value;
  }

  Future<void> _download() async {
    final value = _url.text.trim();
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      setState(() => _status = 'Find a direct HTTPS video URL before downloading.');
      return;
    }
    final extMatch = RegExp(r'\.(mp4|m4v|mov|webm)$', caseSensitive: false)
        .firstMatch(uri.path);
    if (extMatch == null) {
      setState(() => _status =
          'This link is not a direct video file. A Pin webpage URL cannot be downloaded as a video.');
      return;
    }

    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'Downloading video…';
    });

    String? path;
    try {
      final temp = await Directory.systemTemp.createTemp('pinvideo_');
      path = '${temp.path}/pinterest_video.${extMatch.group(1)!.toLowerCase()}';
      await _dio.download(
        value,
        path,
        options: Options(
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 3),
          sendTimeout: const Duration(seconds: 30),
          headers: const {'User-Agent': 'Mozilla/5.0'},
        ),
        onReceiveProgress: (received, total) {
          if (mounted && total > 0) {
            setState(() => _progress = received / total);
          }
        },
      );

      final file = File(path);
      if (!await file.exists() || await file.length() < 1024) {
        throw Exception('The downloaded file is empty or invalid.');
      }
      await Gal.putVideo(path);
      if (mounted) {
        setState(() {
          _progress = 1;
          _status = 'Saved to your Gallery.';
        });
      }
      await temp.delete(recursive: true);
    } on GalException catch (e) {
      if (mounted) setState(() => _status = 'Gallery save failed: ${e.type}. Check photo/video permissions.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Download failed. The media URL may require cookies or may have expired.');
    } finally {
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) await f.parent.delete(recursive: true);
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      setState(() {
        _url.text = data!.text!.trim();
        _pageChecked = false;
        _status = 'Link pasted. Tap “Find video”.';
      });
    }
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    _url.dispose();
    _dio.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFBD081C);
    return Scaffold(
      appBar: AppBar(
        title: const Text('PinVideo', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        actions: [
          IconButton(onPressed: _paste, tooltip: 'Paste link', icon: const Icon(Icons.content_paste)),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: red, borderRadius: BorderRadius.circular(24)),
              child: const Row(children: [
                CircleAvatar(backgroundColor: Colors.white, child: Icon(Icons.play_arrow_rounded, color: red, size: 30)),
                SizedBox(width: 14),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Save a video you love', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
                  SizedBox(height: 4),
                  Text('Share a public Pin into this app.', style: TextStyle(color: Colors.white70)),
                ])),
              ]),
            ),
            const SizedBox(height: 24),
            const Text('Pinterest link or direct video URL', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: 'https://pin.it/your-link',
                prefixIcon: const Icon(Icons.link),
                suffixIcon: IconButton(onPressed: _paste, icon: const Icon(Icons.content_paste)),
              ),
              onChanged: (_) => setState(() => _pageChecked = false),
            ),
            const SizedBox(height: 20),
            const Text('Preferred quality', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: '360', label: Text('360p')),
                ButtonSegment(value: '480', label: Text('480p')),
                ButtonSegment(value: '720', label: Text('720p')),
              ],
              selected: {_quality},
              onSelectionChanged: (s) => setState(() => _quality = s.first),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _busy ? null : _findVideo,
              icon: const Icon(Icons.search),
              label: const Text('Find video on Pin page'),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy ? null : _download,
              style: FilledButton.styleFrom(
                backgroundColor: red,
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download_rounded),
              label: Text(_busy ? 'Working…' : 'Download to Gallery', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (_busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
              child: Text(_status, style: const TextStyle(height: 1.4)),
            ),
            const SizedBox(height: 18),
            const Text(
              'Best effort only: the app does not sign in, bypass private content, or use a remote backend. Pinterest may not expose a direct video URL.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.5),
            ),
              ],
            ),
          ),
          // A WebViewController must be attached to a WebViewWidget before
          // loadRequest/runJavaScript can work. Keep it mounted at 1x1 pixels.
          if (_webController != null)
            Positioned(
              right: 0,
              bottom: 0,
              width: 1,
              height: 1,
              child: Opacity(
                opacity: 0.01,
                child: WebViewWidget(controller: _webController!),
              ),
            ),
        ],
      ),
    );
  }
}
