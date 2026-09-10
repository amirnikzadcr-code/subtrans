import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

import '../api_client.dart';
import '../languages.dart';
import '../youtube_client.dart';
import 'lang_picker.dart';

/// Video + transcript view — same playback mechanism as the ORIGINAL app
/// (verified from its APK): the `youtube_player_flutter` WebView player whose
/// page is served with a youtube-nocookie.com base origin, so YouTube's
/// IFrame player treats the embed as coming from YouTube's own domain and
/// NEVER shows "Watch on YouTube" / "embedding disabled" errors. Every video
/// plays in-app, with the selected subtitle rendered as a synced overlay
/// (translated line big, original line small), sticky header, language
/// switch, tap-a-line → seek, copy & share.
class VideoScreen extends StatefulWidget {
  final TranscriptResult result;
  const VideoScreen({super.key, required this.result});
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late TranscriptResult _result;
  late YoutubePlayerController _player;
  bool _showSource = true;
  bool _showSubtitles = true;
  bool _switching = false;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  bool _muted = false;
  int _activeIdx = -1;
  int _activeHint = 0;
  int _playError = 0;
  bool _wasPlaying = false;
  Timer? _hideTimer;
  final GlobalKey _playerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _result = widget.result;
    _createPlayer();
  }

  // ---- player (exact stack of the original app) -----------------------------
  void _createPlayer() {
    _player = YoutubePlayerController(
      initialVideoId: _result.videoId,
      flags: const YoutubePlayerFlags(
        autoPlay: true,
        mute: false,
        hideControls: true, // we render our own controls + subtitle overlay
        controlsVisibleAtStart: false,
        enableCaption: false, // we render our own translated subtitles
        disableDragSeek: false,
        forceHD: false,
        useHybridComposition: true,
      ),
    );
    _player.addListener(_onPlayerValue);
  }

  void _recreatePlayer() {
    _player.removeListener(_onPlayerValue);
    _player.dispose();
    setState(() {
      _playError = 0;
      _activeIdx = -1;
      _activeHint = 0;
      _controlsVisible = true;
    });
    _createPlayer();
  }

  /// controller ticks (every ~100ms) → subtitle sync, fullscreen transitions,
  /// error surfacing, control auto-hide. Only setState when something visible
  /// changed so the transcript list doesn't rebuild every tick.
  void _onPlayerValue() {
    if (!mounted) return;
    final v = _player.value;

    if (v.hasError && _playError == 0) {
      setState(() => _playError = v.errorCode);
      return;
    }

    if (v.isFullScreen != _fullscreen) {
      setState(() => _fullscreen = v.isFullScreen);
      SystemChrome.setEnabledSystemUIMode(
        _fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }

    final idx = activeSegmentIndex(_result.segments, v.position.inMilliseconds, _activeHint);
    if (idx != _activeIdx) {
      setState(() {
        _activeIdx = idx;
        if (idx >= 0) _activeHint = idx;
      });
    }

    if (v.isPlaying != _wasPlaying) {
      _wasPlaying = v.isPlaying;
      if (v.isPlaying) {
        _armControlsHide();
      } else if (!_controlsVisible) {
        setState(() => _controlsVisible = true);
      } else {
        setState(() {});
      }
    }
  }

  void _togglePlay() {
    if (_player.value.isPlaying) {
      _player.pause();
    } else {
      _player.play();
    }
    _armControlsHide();
  }

  void _toggleMute() {
    if (_muted) {
      _player.unMute();
    } else {
      _player.mute();
    }
    setState(() => _muted = !_muted);
    _armControlsHide();
  }

  void _armControlsHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _player.value.isPlaying && _controlsVisible) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _pokeControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _armControlsHide();
  }

  void _toggleFullscreen() {
    _pokeControls();
    _player.toggleFullScreenMode();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _player.removeListener(_onPlayerValue);
    _player.dispose();
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
    _player.seekTo(Duration(milliseconds: s.start));
    _player.play();
    _pokeControls();
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
    switch (_playError) {
      case 2:
        return 'ویدئوی موردنظر معتبر نیست.';
      case 100:
        return 'ویدئو پیدا نشد یا حذف شده است.';
      case 101:
      case 150:
        return 'سازنده این ویدئو اجازه پخش داخل اپ را نداده است.';
      case 5:
        return 'پخش‌کننده ویدئو خطا داد؛ دوباره تلاش کن.';
      default:
        return 'پخش این ویدئو ممکن نشد؛ زیرنویس همچنان کار می‌کند.';
    }
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final srcLang = langByCode(_result.sourceLang);

    final playerBlock = SizedBox(
      key: _playerKey,
      child: _playerStack(),
    );

    final body = Column(
      children: [
        if (_fullscreen) Expanded(child: playerBlock) else playerBlock,
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
    );

    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _toggleFullscreen();
      },
      child: Scaffold(
        backgroundColor: _fullscreen ? Colors.black : null,
        appBar: _fullscreen
            ? null
            : AppBar(
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
        body: Stack(
          children: [
            body,
            if (_switching)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black38,
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// player surface: 16:9 video + translated subtitle overlay + own controls.
  /// The same keyed subtree is reparented (GlobalKey) between portrait block
  /// and fullscreen Expanded, so the WebView never restarts.
  Widget _playerStack() {
    Widget video;
    if (_playError != 0) {
      video = _PlayerErrorCard(
        videoId: _result.videoId,
        message: _playerErrorMessage,
        onOpenYouTube: _openInYouTube,
        onRetry: _recreatePlayer,
      );
    } else {
      video = GestureDetector(
        onTap: () {
          if (_controlsVisible) {
            _togglePlay();
          } else {
            _pokeControls();
          }
        },
        child: Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: YoutubePlayer(
              controller: _player,
              showVideoProgressIndicator: false,
              bufferIndicator: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
          ),
        ),
      );
    }

    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        ColoredBox(color: Colors.black, child: video),
        // translated subtitle overlay — sits on the video like burned-in subs
        if (_showSubtitles && _activeIdx >= 0 && _playError == 0)
          Padding(
            padding: EdgeInsets.only(bottom: _controlsVisible ? 52.0 : 10.0),
            child: _SubtitleOverlay(
              segment: _result.segments[_activeIdx],
              showSource: _showSource,
            ),
          ),
        // custom control bar
        if (_playError == 0 && (_controlsVisible || !_player.value.isPlaying))
          _ControlBar(state: this),
        if (_fullscreen)
          Positioned(
            top: 8, left: 8,
            child: IconButton(
              onPressed: _toggleFullscreen,
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
      ],
    );
  }
}

/// bottom control bar — play/pause, time, scrub slider, mute, fullscreen.
/// Rebuilds only via the controller's ValueNotifier (not whole-screen setState).
class _ControlBar extends StatelessWidget {
  final _VideoScreenState _state;
  const _ControlBar({required _VideoScreenState state}) : _state = state;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _state._pokeControls,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black54],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(4, 24, 4, 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<YoutubePlayerValue>(
              valueListenable: _state._player,
              builder: (context, v, _) {
                final durMs = v.metaData.duration.inMilliseconds;
                final posMs = v.position.inMilliseconds;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: _state._togglePlay,
                          icon: Icon(
                            v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                            color: Colors.white, size: 28,
                          ),
                        ),
                        Text(
                          '${_fmt(v.position)} / ${_fmt(v.metaData.duration)}',
                          style: const TextStyle(color: Colors.white, fontSize: 11.5),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: _state._toggleMute,
                          icon: Icon(
                            _state._muted ? Icons.volume_off : Icons.volume_up,
                            color: Colors.white, size: 20,
                          ),
                        ),
                        IconButton(
                          onPressed: _state._toggleFullscreen,
                          icon: const Icon(Icons.fullscreen, color: Colors.white, size: 24),
                        ),
                      ],
                    ),
                    SizedBox(
                      height: 22,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2.5,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                          padding: EdgeInsets.zero,
                        ),
                        child: Slider(
                          value: durMs > 0
                              ? posMs.clamp(0, durMs).toDouble()
                              : 0,
                          max: durMs > 0 ? durMs.toDouble() : 1,
                          activeColor: const Color(0xFFFF3D3D),
                          inactiveColor: Colors.white24,
                          onChanged: (val) {
                            _state._player.seekTo(Duration(milliseconds: val.round()));
                            _state._armControlsHide();
                          },
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
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
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
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

/// Only shown when the video genuinely can't play (deleted / html5 error).
/// With the original's youtube-nocookie origin, embed-block errors (101/150)
/// should never appear — every video plays in-app like the original.
class _PlayerErrorCard extends StatelessWidget {
  final String videoId;
  final String message;
  final Future<void> Function() onOpenYouTube;
  final VoidCallback onRetry;
  const _PlayerErrorCard({
    required this.videoId,
    required this.message,
    required this.onOpenYouTube,
    required this.onRetry,
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 17),
                      label: const Text('تلاش دوباره'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withAlpha(230),
                        foregroundColor: Colors.black87,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: () => onOpenYouTube(),
                      icon: const Icon(Icons.open_in_new, size: 17),
                      label: const Text('در یوتیوب'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withAlpha(230),
                        foregroundColor: Colors.black87,
                      ),
                    ),
                  ],
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
