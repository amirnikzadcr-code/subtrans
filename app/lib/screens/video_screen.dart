import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../api_client.dart';
import '../languages.dart';
import '../youtube_client.dart';
import 'lang_picker.dart';

/// Video + transcript view — native playback, same UX pattern as the original
/// app: the video plays INSIDE the app (direct stream URLs minted from
/// innertube, like YouTube's own mobile apps — works for every video,
/// including ones that forbid embedding), with the selected subtitle rendered
/// as a synced overlay (translated line big, original line small), sticky
/// video header, language switch, tap-a-line → seek, copy & share.
class VideoScreen extends StatefulWidget {
  final TranscriptResult result;
  const VideoScreen({super.key, required this.result});
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

enum _PlayState { loading, ready, failed }

class _VideoScreenState extends State<VideoScreen> {
  late TranscriptResult _result;
  _PlayState _playState = _PlayState.loading;
  String _failCode = '';
  bool _showSource = true;
  bool _showSubtitles = true;
  bool _switching = false;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  bool _muted = false;
  int _activeIdx = -1;
  int _activeHint = 0;
  Timer? _hideTimer;

  VideoPlayerController? _vc;

  @override
  void initState() {
    super.initState();
    _result = widget.result;
    _openPlayer();
  }

  // ---- native playback: innertube stream URLs → ExoPlayer -------------------
  Future<void> _openPlayer() async {
    setState(() {
      _playState = _PlayState.loading;
      _failCode = '';
    });
    await _disposePlayer();
    try {
      // 1) mint direct stream URLs from the device (residential IP) — this is
      //    what makes playback work for videos that block embedding.
      final stream = await YouTubeClient().fetchStreamInfo(_result.videoId);
      // 2) native player (ExoPlayer) — HLS adaptive or progressive mp4
      final vc = VideoPlayerController.networkUrl(
        Uri.parse(stream.url),
        httpHeaders: {'User-Agent': YouTubeClient.playbackUa},
      );
      _vc = vc;
      vc.addListener(_onTick);
      await vc.initialize();
      if (!mounted) {
        await vc.dispose();
        return;
      }
      setState(() => _playState = _PlayState.ready);
      await vc.play();
      _armControlsHide();
    } on YtFetchException catch (e) {
      if (mounted) {
        setState(() {
          _playState = _PlayState.failed;
          _failCode = e.code;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _playState = _PlayState.failed;
          _failCode = 'playback_failed';
        });
      }
    }
  }

  Future<void> _disposePlayer() async {
    _vc?.removeListener(_onTick);
    final old = _vc;
    _vc = null;
    await old?.dispose();
  }

  bool _lastPlaying = false;
  bool _lastBuffering = false;

  /// position ticks → subtitle sync + control-state refresh (only setState
  /// when something visible actually changed, so the transcript list doesn't
  /// rebuild on every frame)
  void _onTick() {
    final vc = _vc;
    if (vc == null || !mounted) return;
    final v = vc.value;
    if (v.hasError && _playState == _PlayState.ready) {
      setState(() {
        _playState = _PlayState.failed;
        _failCode = 'playback_failed';
      });
      return;
    }
    final idx = activeSegmentIndex(_result.segments, v.position.inMilliseconds, _activeHint);
    final playing = v.isPlaying;
    final buffering = v.isBuffering;
    if (idx != _activeIdx || playing != _lastPlaying || buffering != _lastBuffering) {
      setState(() {
        _activeIdx = idx;
        if (idx >= 0) _activeHint = idx;
        _lastPlaying = playing;
        _lastBuffering = buffering;
      });
    }
  }

  bool get _isPlaying => _vc?.value.isPlaying ?? false;
  bool get _isBuffering => _vc?.value.isBuffering ?? false;

  void _toggleMute() {
    final vc = _vc;
    if (vc == null) return;
    _muted = !_muted;
    vc.setVolume(_muted ? 0 : 1);
    setState(() {});
    _armControlsHide();
  }

  void _togglePlay() {
    final vc = _vc;
    if (vc == null) return;
    if (vc.value.isPlaying) {
      vc.pause();
    } else {
      vc.play();
    }
    _armControlsHide();
  }

  void _armControlsHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_vc?.value.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _pokeControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _armControlsHide();
  }

  Future<void> _toggleFullscreen() async {
    final vc = _vc;
    if (vc == null) return;
    if (!_fullscreen) {
      await SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      setState(() => _fullscreen = true);
    } else {
      await _exitFullscreen();
    }
    _pokeControls();
  }

  Future<void> _exitFullscreen() async {
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (mounted) setState(() => _fullscreen = false);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _vc?.removeListener(_onTick);
    _vc?.dispose();
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
    final vc = _vc;
    if (vc == null) return;
    vc.seekTo(Duration(milliseconds: s.start));
    vc.play();
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

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final srcLang = langByCode(_result.sourceLang);

    if (_fullscreen) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _exitFullscreen();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: _playerArea(fullscreen: true),
        ),
      );
    }

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
                _playerArea(),
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

  /// player surface — portrait: 16:9 block at top; fullscreen: whole body.
  Widget _playerArea({bool fullscreen = false}) {
    final vc = _vc;
    Widget surface;
    if (_playState == _PlayState.ready && vc != null && vc.value.isInitialized) {
      final ar = vc.value.aspectRatio <= 0 ? 16 / 9 : vc.value.aspectRatio;
      surface = GestureDetector(
        onTap: () {
          if (_controlsVisible) {
            _togglePlay();
          } else {
            _pokeControls();
          }
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(child: AspectRatio(aspectRatio: ar, child: VideoPlayer(vc))),
            if (_isBuffering)
              const CircularProgressIndicator(color: Colors.white),
            if (!_controlsVisible)
              const SizedBox.expand(),
          ],
        ),
      );
    } else if (_playState == _PlayState.failed) {
      surface = _PlayerErrorCard(
        videoId: _result.videoId,
        message: friendlyError(_failCode),
        onOpenYouTube: _openInYouTube,
        onRetry: _openPlayer,
      );
    } else {
      surface = Stack(
        alignment: Alignment.center,
        children: [
          Image.network(
            'https://i.ytimg.com/vi/${_result.videoId}/hqdefault.jpg',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(color: Colors.black),
          ),
          Container(color: Colors.black.withAlpha(110)),
          const CircularProgressIndicator(color: Colors.white),
        ],
      );
    }

    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        if (fullscreen)
          SizedBox.expand(child: ColoredBox(color: Colors.black, child: surface))
        else
          AspectRatio(aspectRatio: 16 / 9, child: ColoredBox(color: Colors.black, child: surface)),
        // translated subtitle overlay — sits on the video like burned-in subs
        if (_showSubtitles && _activeIdx >= 0 && _playState == _PlayState.ready)
          Padding(
            padding: EdgeInsets.only(bottom: fullscreen ? 56.0 : 44.0),
            child: _SubtitleOverlay(
              segment: _result.segments[_activeIdx],
              showSource: _showSource,
            ),
          ),
        // controls
        if (_playState == _PlayState.ready && (_controlsVisible || !_isPlaying))
          _ControlBar(state: this, fullscreen: fullscreen),
        if (fullscreen)
          Positioned(
            top: 8, left: 8,
            child: IconButton(
              onPressed: _exitFullscreen,
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ),
      ],
    );
  }
}

/// bottom control bar — play/pause, time, scrub bar, mute, fullscreen
class _ControlBar extends StatelessWidget {
  final _VideoScreenState _state;
  final bool fullscreen;
  const _ControlBar({required _VideoScreenState state, this.fullscreen = false})
      : _state = state;

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final vc = _state._vc;
    if (vc == null) return const SizedBox.shrink();
    final v = vc.value;
    return GestureDetector(
      onTap: _state._pokeControls,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black54],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(8, 24, 8, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: _state._togglePlay,
                  icon: Icon(
                    _state._isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                    color: Colors.white, size: fullscreen ? 34 : 28,
                  ),
                ),
                Text('${_fmt(v.position)} / ${_fmt(v.duration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 11.5)),
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
                  icon: Icon(
                    fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    color: Colors.white, size: 24,
                  ),
                ),
              ],
            ),
            SizedBox(
              height: 22,
              child: VideoProgressIndicator(
                vc,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                colors: const VideoProgressColors(
                  playedColor: Color(0xFFFF3D3D),
                  bufferedColor: Color(0x55FFFFFF),
                  backgroundColor: Color(0x22FFFFFF),
                ),
              ),
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

/// Shown only when the video genuinely can't play (deleted / age-gated /
/// copyright) — with retry. Subtitles still work; playback failure is no
/// longer tied to the iframe's embed permission.
class _PlayerErrorCard extends StatelessWidget {
  final String videoId;
  final String message;
  final Future<void> Function() onOpenYouTube;
  final Future<void> Function() onRetry;
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
                      onPressed: () => onRetry(),
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
