import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../languages.dart';
import '../youtube_client.dart';
import 'lang_picker.dart';
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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _controller = TextEditingController();
  Lang _target = const Lang('fa', 'فارسی', 'فارسی', '🇮🇷');
  List<HistoryItem> _history = [];
  bool _busy = false;

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

  Future<void> _saveHistory(HistoryItem item) async {
    setState(() {
      _history.removeWhere((h) => h.videoId == item.videoId);
      _history.insert(0, item);
      if (_history.length > 10) _history = _history.sublist(0, 10);
    });
    final p = await SharedPreferences.getInstance();
    await p.setStringList('history', _history.map((h) => jsonEncode(h.toMap())).toList());
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
      _toast('لینک معتبر یوتیوب نیست.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final result = await fetchTranscriptWithTranslation(videoId: videoId, target: _target.code);
      await _saveHistory(HistoryItem(videoId: videoId, title: result.title, lang: _target.code));
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => VideoScreen(result: result)));
      _controller.clear();
    } on ApiException catch (e) {
      _toast(e.message);
    } on YtFetchException catch (e) {
      _toast(friendlyError(e.code));
    } catch (_) {
      _toast('خطای غیرمنتظره؛ دوباره تلاش کن.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.closed_caption, size: 40, color: cs.primary),
                const SizedBox(width: 10),
                Text('SubTrans',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w900, color: cs.primary)),
              ],
            ),
            const SizedBox(height: 8),
            Text('زیرنویس هر ویدئوی یوتیوب به ۱۳۰+ زبان',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 32),
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
                    if (data?.text?.isNotEmpty == true) {
                      _controller.text = data!.text!.trim();
                    } else {
                      _toast('کلیپ‌بورد خالی است.');
                    }
                  },
                ),
              ),
              onSubmitted: (_) => _busy ? null : _submit(),
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
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4))
                  : const Icon(Icons.translate),
              label: Text(_busy ? 'در حال دریافت زیرنویس…' : 'زیرنویس کن'),
            ),
            const SizedBox(height: 34),
            if (_history.isNotEmpty) ...[
              Row(children: [
                const Icon(Icons.history, size: 18),
                const SizedBox(width: 6),
                Text('ترجمه‌های اخیر', style: Theme.of(context).textTheme.titleMedium),
              ]),
              const SizedBox(height: 10),
              ..._history.map(_historyTile),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _historyTile(HistoryItem h) {
    final lang = langByCode(h.lang);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          _controller.text = 'https://youtu.be/${h.videoId}';
          _target = langByCode(h.lang);
          _submit();
        },
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  'https://i.ytimg.com/vi/${h.videoId}/mqdefault.jpg',
                  width: 96, height: 54, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 96, height: 54, color: Colors.black26,
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
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text('${lang.flag} ${lang.fa}',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
