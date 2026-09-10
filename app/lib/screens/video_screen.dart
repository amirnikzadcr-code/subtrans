import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../api_client.dart';
import '../languages.dart';
import '../youtube_client.dart';
import 'lang_picker.dart';

/// Transcript view — dual-line (original + translated), same UX pattern as
/// the original app's transcript screen: sticky video header, language switch,
/// tap-to-copy a line, share/copy the whole translation.
class VideoScreen extends StatefulWidget {
  final TranscriptResult result;
  const VideoScreen({super.key, required this.result});
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late TranscriptResult _result;
  bool _showSource = true;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _result = widget.result;
  }

  Lang get _current => langByCode(_result.targetLang ?? 'fa');

  Future<void> _changeLanguage() async {
    final picked = await showLanguagePicker(context, _current);
    if (picked == null || picked.code == _current.code) return;
    setState(() => _switching = true);
    try {
      final fresh = await fetchTranscriptWithTranslation(
        videoId: _result.videoId,
        target: picked.code,
      );
      setState(() => _result = fresh);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } on YtFetchException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e.code))));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _copyAll() {
    final buf = StringBuffer();
    for (final s in _result.segments) {
      buf.writeln(s.tr.isEmpty ? s.text : s.tr);
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('کل ترجمه کپی شد.')),
    );
  }

  void _shareAll() {
    final buf = StringBuffer();
    buf.writeln(_result.title);
    for (final s in _result.segments) {
      buf.writeln('${s.tc}  ${s.tr.isEmpty ? s.text : s.tr}');
    }
    SharePlus.instance.share(ShareParams(text: buf.toString()));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final srcLang = langByCode(_result.sourceLang);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _result.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(onPressed: _copyAll, icon: const Icon(Icons.copy_all)),
          IconButton(onPressed: _shareAll, icon: const Icon(Icons.share)),
        ],
      ),
      body: _switching
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // sticky header — thumbnail + meta + language switch
                Container(
                  color: cs.surfaceContainerHighest.withAlpha(60),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          'https://i.ytimg.com/vi/${_result.videoId}/mqdefault.jpg',
                          width: 110, height: 62, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 110, height: 62, color: Colors.black26,
                            child: const Icon(Icons.videocam_off),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_result.author,
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text(
                              '${_result.segments.length} خط'
                              ' · ${srcLang.flag} ${srcLang.fa}'
                              '${_result.isAsr ? ' · خودکار (ASR)' : ' · دستی'}'
                              '${_result.engine != null ? ' · ${_result.engine == "gemini" ? "Gemini" : "Google"}' : ''}',
                              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // language switch row
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Row(
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: _changeLanguage,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('${_current.flag} ${_current.fa}',
                                  style: TextStyle(color: cs.onPrimaryContainer,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(width: 6),
                              Icon(Icons.swap_horiz, size: 18, color: cs.onPrimaryContainer),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => setState(() => _showSource = !_showSource),
                        icon: Icon(_showSource ? Icons.visibility : Icons.visibility_off, size: 18),
                        label: const Text('متن اصلی'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
                    itemCount: _result.segments.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
                    itemBuilder: (context, i) {
                      final s = _result.segments[i];
                      return InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: s.tr.isEmpty ? s.text : s.tr));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('کپی شد: ${s.tc}')),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Text(s.tc, style: TextStyle(
                                    fontSize: 11, fontWeight: FontWeight.w700,
                                    color: cs.primary, letterSpacing: 0.5)),
                              ]),
                              const SizedBox(height: 4),
                              if (_showSource)
                                Text(s.text,
                                    style: TextStyle(fontSize: 12.5,
                                        color: cs.onSurfaceVariant, height: 1.5)),
                              Text(s.tr.isEmpty ? '—' : s.tr,
                                  style: const TextStyle(fontSize: 15, height: 1.7,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
