import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../api_client.dart';
import '../languages.dart';
import '../youtube_client.dart';
import 'lang_picker.dart';

/// Video + transcript view — same UX pattern as the original app's video
/// screen: embedded YouTube player with the selected subtitle rendered as a
/// synced overlay (translated line big, original line small), sticky video
/// header, language switch, tap-a-line → seek, copy & share.
class VideoScreen extends StatefulWidget {
  final TranscriptResult result;
  const VideoScreen({super.key, required this.result});
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late TranscriptResult _result;
  bool _showSource = true;
  bool _showSubtitles = true;
  bool _switching = false;
  int _activeIdx = -1;
  int _activeHint = 0;
  YoutubeError _playerError = YoutubeError.none;

  YoutubePlayerController? _player;

  @override
  void initState() {
    super.initState();
    _result = widget.result;
    _initPlayer();
  }

  void _initPlayer() {
    final c = YoutubePlayerController(
      params: const YoutubePlayerParams(
        showControls: true,
        showFullscreenButton: true,
        enableCaption: false, // we render our own translated subtitles
        mute: false,
        strictRelatedVideos: true,
      ),
    );
    c.cueVideoById(videoId: _result.videoId);
    // surface player errors (non-embeddable, not-found, html5) so we can
    // swap in our own error card instead of YouTube's "Watch on YouTube" UI
    c.listen((value) {
      if (!mounted) return;
      if (value.hasError && _playerError == YoutubeError.none) {
        setState(() => _playerError = value.error);
      }
    });
    c.videoStateStream.listen((state) {
      if (!mounted) return;
      final posMs = state.position.inMilliseconds;
      final idx = activeSegmentIndex(_result.segments, posMs, _activeHint);
      if (idx != _activeIdx) {
        setState(() {
          _activeIdx = idx;
          _activeHint = idx >= 0 ? idx : _activeHint;
        });
      }
    });
    _player = c;
  }

  @override
  void dispose() {
    _player?.close();
    super.dispose();
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
      setState(() {
        _result = fresh;
        _activeIdx = -1;
        _activeHint = 0;
      });
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } on YtFetchException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e.code))));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تغییر زبان ناموفق بود؛ دوباره تلاش کن.')),
        );
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
    Share.share(buf.toString());
  }

  void _seekTo(Segment s) {
    if (_playerError != YoutubeError.none) return;
    final seconds = s.start / 1000.0;
    _player?.seekTo(seconds: seconds, allowSeekAhead: true);
    _player?.playVideo();
  }

  Future<void> _openInYouTube() async {
    final uri = Uri.parse('https://www.youtube.com/watch?v=${_result.videoId}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('برنامه یوتیوب یا مرورگر پیدا نشد.')),
        );
      }
    }
  }

  String get _playerErrorMessage {
    switch (_playerError) {
      case YoutubeError.notEmbeddable:
      case YoutubeError.sameAsNotEmbeddable:
        return 'سازنده این ویدئو اجازه پخش داخل اپ را نداده است.';
      case YoutubeError.videoNotFound:
      case YoutubeError.cannotFindVideo:
        return 'ویدئو پیدا نشد یا حذف شده است.';
      case YoutubeError.invalidParam:
        return 'ویدئوی موردنظر معتبر نیست.';
      case YoutubeError.html5Error:
        return 'پخش‌کننده ویدئو خطا داد؛ دوباره تلاش کن.';
      default:
        return 'پخش این ویدئو در اپ ممکن نیست؛ زیرنویس همچنان کار می‌کند.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final srcLang = langByCode(_result.sourceLang);
    final player = _player;
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
                // --- embedded player with synced subtitle overlay ---
                if (player != null && _playerError == YoutubeError.none)
                  Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      YoutubePlayer(controller: player),
                      if (_showSubtitles && _activeIdx >= 0)
                        _SubtitleOverlay(
                          segment: _result.segments[_activeIdx],
                          showSource: _showSource,
                        ),
                    ],
                  )
                else if (_playerError != YoutubeError.none)
                  _PlayerErrorCard(
                    videoId: _result.videoId,
                    message: _playerErrorMessage,
                    onOpenYouTube: _openInYouTube,
                  )
                else
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(
                      color: Colors.black,
                      child: const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    ),
                  ),
                // sticky header — meta + language switch
                Container(
                  color: cs.surfaceContainerHighest.withAlpha(60),
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          'https://i.ytimg.com/vi/${_result.videoId}/mqdefault.jpg',
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
                        onPressed: () => setState(() => _showSubtitles = !_showSubtitles),
                        icon: Icon(_showSubtitles ? Icons.subtitles : Icons.subtitles_off, size: 18),
                        label: const Text('زیرنویس'),
                      ),
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
                      final isActive = i == _activeIdx;
                      return InkWell(
                        onTap: () => _seekTo(s),
                        child: Container(
                          color: isActive
                              ? cs.primary.withAlpha(30)
                              : Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                Icon(Icons.play_circle_outline, size: 14, color: cs.primary),
                                const SizedBox(width: 4),
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
                                  style: TextStyle(fontSize: 15, height: 1.7,
                                      fontWeight: FontWeight.w600,
                                      color: isActive ? cs.primary : null)),
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

/// Burned-in style overlay — translated line prominent, original above it.
class _SubtitleOverlay extends StatelessWidget {
  final Segment segment;
  final bool showSource;
  const _SubtitleOverlay({
    required this.segment,
    required this.showSource,
  });

  @override
  Widget build(BuildContext context) {
    final translated = segment.tr.isEmpty ? segment.text : segment.tr;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(170),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSource && segment.tr.isNotEmpty)
            Text(
              segment.text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          Text(
            translated,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              height: 1.4,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(blurRadius: 4, color: Colors.black)],
            ),
          ),
        ],
      ),
    );
  }
}

/// Replaces the broken iframe (embedding disabled / playback error) so users
/// never see YouTube's own error card or its black "Watch on YouTube" screen.
class _PlayerErrorCard extends StatelessWidget {
  final String videoId;
  final String message;
  final Future<void> Function() onOpenYouTube;
  const _PlayerErrorCard({
    required this.videoId,
    required this.message,
    required this.onOpenYouTube,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.network(
            'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(color: Colors.black),
          ),
          Container(color: Colors.black.withAlpha(140)),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam_off, color: Colors.white70, size: 34),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: () => onOpenYouTube(),
                  icon: const Icon(Icons.open_in_new, size: 17),
                  label: const Text('باز کردن در یوتیوب'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white.withAlpha(230),
                    foregroundColor: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 6,
            left: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: cs.surface.withAlpha(200),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('زیرنویس فعال است', style: TextStyle(fontSize: 10.5, color: cs.onSurface)),
            ),
          ),
        ],
      ),
    );
  }
}
