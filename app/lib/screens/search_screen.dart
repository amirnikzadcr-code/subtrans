import 'dart:async';

import 'package:flutter/material.dart';

import '../languages.dart';
import '../youtube_client.dart';
import 'home_screen.dart';
import 'lang_picker.dart';

/// YouTube search screen (device-side innertube search — same capability as
/// the original app's youtube_search_screen). Tap a result → subtitle flow.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<YtSearchResult> _results = [];
  bool _searching = false;
  String? _error;
  Lang _target = const Lang('fa', 'فارسی', 'فارسی', '🇮🇷');

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _results = [];
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 700), () => _search(q));
  }

  Future<void> _search(String q) async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final r = await searchYouTube(q.trim());
      if (!mounted) return;
      setState(() {
        _results = r;
        _searching = false;
      });
    } on YtFetchException {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'جستجو ناموفق بود؛ دوباره تلاش کن.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'اتصال برقرار نشد؛ اینترنت را بررسی کن.';
      });
    }
  }

  Future<void> _open(YtSearchResult r) async {
    await openTranscriptFlow(context, r.videoId, _target);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focus,
                      onChanged: _onChanged,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (q) => _search(q),
                      decoration: InputDecoration(
                        hintText: 'جستجوی ویدئو در یوتیوب…',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _ctrl.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _ctrl.clear();
                                  setState(() => _results = []);
                                },
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () async {
                      final picked = await showLanguagePicker(context, _target);
                      if (picked != null) setState(() => _target = picked);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.primary.withAlpha(28),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: cs.primary.withAlpha(90)),
                      ),
                      child: Text(_target.flag, style: const TextStyle(fontSize: 18)),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 20),
                Text(
                  'زیرنویس نتایج به: ${_target.fa}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: _searching
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFE62117)))
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed: () => _search(_ctrl.text),
                                icon: const Icon(Icons.refresh),
                                label: const Text('تلاش دوباره'),
                              ),
                            ],
                          ),
                        )
                      : _results.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.travel_explore,
                                      size: 54, color: cs.onSurfaceVariant.withAlpha(120)),
                                  const SizedBox(height: 10),
                                  Text(
                                    _ctrl.text.isEmpty
                                        ? 'یک موضوع را جستجو کن'
                                        : 'نتیجه‌ای پیدا نشد',
                                    style: TextStyle(color: cs.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                              itemCount: _results.length,
                              itemBuilder: (ctx, i) {
                                final r = _results[i];
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 10),
                                  clipBehavior: Clip.antiAlias,
                                  child: InkWell(
                                    onTap: () => _open(r),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Stack(
                                          children: [
                                            Image.network(
                                              r.thumbUrl,
                                              width: 140,
                                              height: 79,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) => Container(
                                                width: 140,
                                                height: 79,
                                                color: Colors.black26,
                                                child: const Icon(Icons.videocam_off),
                                              ),
                                            ),
                                            if (r.duration.isNotEmpty)
                                              Positioned(
                                                bottom: 4,
                                                right: 4,
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(
                                                      horizontal: 5, vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black87,
                                                    borderRadius: BorderRadius.circular(5),
                                                  ),
                                                  child: Text(
                                                    r.duration == 'LIVE'
                                                        ? 'زنده'
                                                        : r.duration,
                                                    style: const TextStyle(
                                                        color: Colors.white, fontSize: 10),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        Expanded(
                                          child: Padding(
                                            padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  r.title,
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      fontWeight: FontWeight.w700,
                                                      fontSize: 13.5,
                                                      height: 1.5),
                                                ),
                                                const SizedBox(height: 5),
                                                Text(
                                                  r.channel,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      fontSize: 11.5,
                                                      color: cs.onSurfaceVariant),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
