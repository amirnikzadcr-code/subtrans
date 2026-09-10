import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../languages.dart';
import '../youtube_client.dart';
import 'lang_picker.dart';
import 'search_screen.dart';
import 'video_screen.dart';

class HistoryItem {
  final String videoId;
  final String title;
  final String lang;
  HistoryItem({required this.videoId, required this.title, required this.lang});

  Map<String, dynamic> toMap() => {'v': videoId, 't': title, 'l': lang};
  factory HistoryItem.fromMap(Map<String, dynamic> m) =>
      HistoryItem(videoId: m['v'] ?? '', title: m['t'] ?? '', lang: m['l'] ?? 'fa');
}

/// shared flow: fetch transcript + translate (with cache), save history,
/// then push the video screen. Used by both the URL tab and the search tab.
Future<void> openTranscriptFlow(
  BuildContext context,
  String videoId,
  Lang target, {
  void Function(String message)? onError,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  // loading dialog
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator(color: Color(0xFFE62117))),
  );
  try {
    final result = await fetchTranscriptWithTranslation(videoId: videoId, target: target.code);
    // save history
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('history') ?? [];
      final list = raw
          .map((e) => HistoryItem.fromMap(Map<String, dynamic>.from(jsonDecode(e))))
          .toList();
      list.removeWhere((h) => h.videoId == videoId);
      list.insert(0, HistoryItem(videoId: videoId, title: result.title, lang: target.code));
      if (list.length > 12) list.removeRange(12, list.length);
      await prefs.setStringList('history', list.map((h) => jsonEncode(h.toMap())).toList());
    } catch (_) {}
    if (context.mounted) {
      Navigator.of(context).pop(); // close loading
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => VideoScreen(result: result)),
      );
    }
  } on ApiException catch (e) {
    if (context.mounted) Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    onError?.call(e.message);
  } on YtFetchException catch (e) {
    if (context.mounted) Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(e.code))));
    onError?.call(friendlyError(e.code));
  } catch (_) {
    if (context.mounted) Navigator.of(context).pop();
    messenger.showSnackBar(const SnackBar(content: Text('خطای غیرمنتظره؛ دوباره تلاش کن.')));
    onError?.call('unexpected');
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _tab == 0 ? const _TranslateTab() : const SearchScreen(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.translate_outlined),
            selectedIcon: Icon(Icons.translate),
            label: 'زیرنویس',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search),
            label: 'جستجو',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// translate tab — red brand header + URL field + language + recents
// ============================================================================

class _TranslateTab extends StatefulWidget {
  const _TranslateTab();
  @override
  State<_TranslateTab> createState() => _TranslateTabState();
}

class _TranslateTabState extends State<_TranslateTab> {
  final _controller = TextEditingController();
  Lang _target = const Lang('fa', 'فارسی', 'فارسی', '🇮🇷');
  List<HistoryItem> _history = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList('history') ?? [];
    if (!mounted) return;
    setState(() {
      _history = raw
          .map((e) => HistoryItem.fromMap(Map<String, dynamic>.from(jsonDecode(e))))
          .toList();
    });
  }

  void _refreshHistory() {
    // slight delay so the flow's own save lands first
    Future.delayed(const Duration(milliseconds: 300), _loadHistory);
  }

  Future<void> _pickLanguage() async {
    final picked = await showLanguagePicker(context, _target);
    if (picked != null) setState(() => _target = picked);
  }

  Future<void> _submit() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    final videoId = extractVideoId(input);
    if (videoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لینک معتبر یوتیوب نیست.')));
      return;
    }
    FocusScope.of(context).unfocus();
    await openTranscriptFlow(context, videoId, _target);
    _refreshHistory();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            const SizedBox(height: 30),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE62117),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.closed_caption, size: 30, color: Colors.white),
                ),
                const SizedBox(width: 10),
                const Text('SubTrans',
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFE62117))),
              ],
            ),
            const SizedBox(height: 8),
            Text('زیرنویس هر ویدئوی یوتیوب به ۱۳۰+ زبان',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 28),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.url,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.left,
              decoration: InputDecoration(
                hintText: 'https://youtube.com/watch?v=…',
                prefixIcon: const Icon(Icons.link),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste),
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    if (!mounted) return;
                    if (data?.text?.isNotEmpty == true) {
                      setState(() => _controller.text = data!.text!.trim());
                      _autoSubmitIfNeeded();
                    } else {
                      if (mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(content: Text('کلیپ‌بورد خالی است.')));
                      }
                    }
                  },
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 14),
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _pickLanguage,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withAlpha(80),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Text(_target.flag, style: const TextStyle(fontSize: 22)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('ترجمه به: ${_target.fa}',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    const Icon(Icons.expand_more),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.translate),
              label: const Text('زیرنویس کن'),
            ),
            const SizedBox(height: 30),
            if (_history.isNotEmpty) ...[
              Row(
                children: [
                  const Icon(Icons.history, size: 18),
                  const SizedBox(width: 6),
                  Text('ترجمه‌های اخیر',
                      style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final p = await SharedPreferences.getInstance();
                      await p.remove('history');
                      setState(() => _history = []);
                    },
                    child: const Text('پاک‌کردن'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ..._history.map(_historyTile),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// pasting a plain video id / link immediately starts the flow (like the
  /// original's clipboard detection)
  void _autoSubmitIfNeeded() {
    final v = extractVideoId(_controller.text.trim());
    if (v != null && RegExp(r'^[\w-]{11}$').hasMatch(_controller.text.trim())) {
      _submit();
    }
  }

  Widget _historyTile(HistoryItem h) {
    final lang = langByCode(h.lang);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await openTranscriptFlow(context, h.videoId, lang);
          _refreshHistory();
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  'https://i.ytimg.com/vi/${h.videoId}/mqdefault.jpg',
                  width: 96,
                  height: 54,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 96,
                    height: 54,
                    color: Colors.black26,
                    child: const Icon(Icons.videocam_off),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(h.title.isEmpty ? h.videoId : h.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('${lang.flag} ${lang.fa}',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
