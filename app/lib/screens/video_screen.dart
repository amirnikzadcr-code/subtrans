import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../api_client.dart';
import '../languages.dart';
import '../youtube_client.dart';
import 'lang_picker.dart';

/// Video + transcript screen — NATIVE playback (ExoPlayer via video_player)
/// fed with direct stream URLs extracted device-side from YouTube's innertube
/// player endpoint (IOS/ANDROID clients — the NewPipe approach). Because no
/// iframe/webview is involved, EVERY video plays in-app: embed-restricted,
/// music, everything. "Watch on YouTube" / embedding errors are impossible.
///
/// Features (mirroring the original app):
///  - synced translated subtitle overlay (translated big + original small)
///  - custom controls: play/pause, ±10s, scrub, speed, mute, fullscreen
///  - transcript list with tap-line-to-seek, auto-scroll, copy & share
///  - working language switch (re-translates in place) + AI summary sheet
class VideoScreen extends StatefulWidget {
  final TranscriptResult result;
  const VideoScreen({super.key, required this.result});
  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  late TranscriptResult _result;
  VideoPlayerController? _player;

  bool _loadingStream = true;
  String? _streamError;
  String _qualityLabel = '';

  int _activeIdx = -1;
  int _activeHint = 0;
  Timer? _syncTimer;

  bool _showSource = true;
  bool _showSubtitles = true;
  bool _switching = false;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  bool _wasPlaying = false;
  bool _finished = false;
  bool _autoScroll = true;
  Timer? _hideTimer;
  double _speed = 1.0;
  bool _muted = false;
  final GlobalKey _activeRowKey = GlobalKey();
  final ScrollController _listCtrl = ScrollController();

  static const _rtlLangs = ['fa', 'ar', 'ur', 'he', 'ps', 'ckb'];

  @override
  void initState() {
    super.initState();
    _result = widget.result;
    _initPlayer();
    _syncTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _hideTimer?.cancel();
    _listCtrl.dispose();
    _player?.removeListener(_onPlayerEvent);
    _player?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    super.dispose();
  }

  // ================= player bootstrap ========================================

  Future<void> _initPlayer() async {
    setState(() {
      _loadingStream = true;
      _streamError = null;
      _finished = false;
    });
    VideoPlayerController? ctrl;
    try {
      final stream = await YouTubeClient().fetchStreamInfo(_result.videoId);
      _qualityLabel = stream.label;
      ctrl = VideoPlayerController.networkUrl(Uri.parse(stream.url));
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      final old = _player;
      _player = ctrl;
      ctrl.addListener(_onPlayerEvent);
      ctrl.setVolume(_muted ? 0 : 1);
      ctrl.setPlaybackSpeed(_speed);
      setState(() => _loadingStream = false);
      if (old != null) {
        old.removeListener(_onPlayerEvent);
        await old.dispose();
      }
      await ctrl.play();
      _armControlsHide();
    } on YtFetchException catch (e) {
      await ctrl?.dispose();
      if (!mounted) return;
      setState(() {
        _loadingStream = false;
        _streamError = e.code;
      });
    } catch (_) {
      await ctrl?.dispose();
      if (!mounted) return;
      setState(() {
        _loadingStream = false;
        _streamError = 'playback_failed';
      });
    }
  }

  void _onPlayerEvent() {
    if (!mounted) return;
    final v = _player?.value;
    if (v == null) return;
    if (v.hasError && _streamError == null && !_loadingStream) {
      setState(() {
        _streamError = 'playback_failed';
        _loadingStream = false;
      });
      return;
    }
    final ended = v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 400) &&
        !v.isPlaying &&
        v.isInitialized;
    if (ended != _finished) setState(() => _finished = ended);
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

  /// subtitle sync tick — same 100ms cadence as the original app's player JS
  void _tick() {
    if (!mounted) return;
    final v = _player?.value;
    if (v == null || !v.isInitialized) return;
    final idx = activeSegmentIndex(_result.segments, v.position.inMilliseconds, _activeHint);
    if (idx != _activeIdx) {
      setState(() {
        _activeIdx = idx;
        if (idx >= 0) _activeHint = idx;
      });
      if (_autoScroll && idx >= 0 && !_fullscreen) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _ensureActiveVisible());
      }
    }
  }

  void _ensureActiveVisible() {
    final ctx = _activeRowKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 220),
        alignment: 0.3,
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _seekTo(int ms) {
    final p = _player;
    if (p == null) return;
    p.seekTo(Duration(milliseconds: ms));
    if (_finished) setState(() => _finished = false);
    if (!p.value.isPlaying) p.play();
  }

  void _togglePlay() {
    final p = _player;
    if (p == null) return;
    if (p.value.isPlaying) {
      p.pause();
      setState(() => _controlsVisible = true);
      _hideTimer?.cancel();
    } else {
      if (_finished) {
        p.seekTo(Duration.zero);
        setState(() => _finished = false);
      }
      p.play();
      _armControlsHide();
    }
  }

  void _seekRel(int s) {
    final p = _player;
    if (p == null) return;
    final target = p.value.position + Duration(seconds: s);
    final d = p.value.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (d > Duration.zero && target > d ? d : target);
    p.seekTo(clamped);
    if (_finished && clamped < d) setState(() => _finished = false);
    _armControlsHide();
  }

  // ================= language switch =========================================

  Future<void> _switchLanguage(Lang lang) async {
    if (_switching || lang.code == _result.targetLang) return;
    setState(() => _switching = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final texts = _result.segments.map((s) => s.text).toList();
      final trs = await Api().translateTexts(texts, lang.code);
      final newSegments = List<Segment>.generate(
        _result.segments.length,
        (i) => Segment(
          start: _result.segments[i].start,
          dur: _result.segments[i].dur,
          text: _result.segments[i].text,
          tr: i < trs.length ? trs[i] : _result.segments[i].tr,
        ),
      );
      final updated = TranscriptResult(
        videoId: _result.videoId,
        title: _result.title,
        author: _result.author,
        lengthSeconds: _result.lengthSeconds,
        sourceLang: _result.sourceLang,
        targetLang: lang.code,
        isAsr: _result.isAsr,
        engine: _result.engine,
        segments: newSegments,
      );
      if (!mounted) return;
      setState(() {
        _result = updated;
        _activeHint = 0;
        _activeIdx = -1;
      });
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'tr:${updated.videoId}:${lang.code}', jsonEncode(updated.toJson()));
      } catch (_) {}
      messenger.showSnackBar(
          SnackBar(content: Text('زیرنویس به ${lang.fa} ترجمه شد.')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('ترجمه ناموفق بود؛ دوباره تلاش کن.')));
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  // ================= summary =================================================

  void _openSummary() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SummarySheet(result: _result),
    );
  }

  // ================= fullscreen / misc =======================================

  void _toggleFullscreen() {
    setState(() {
      _fullscreen = !_fullscreen;
      if (_fullscreen) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      }
      _controlsVisible = true;
    });
    _armControlsHide();
  }

  void _armControlsHide() {
    _hideTimer?.cancel();
    if (!(_player?.value.isPlaying ?? false)) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_player?.value.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _tapPlayerArea() {
    setState(() => _controlsVisible = !_controlsVisible);
    _armControlsHide();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  bool get _rtlSub => _rtlLangs.contains(langByCode(_result.targetLang ?? 'fa').code);

  // ================= build ===================================================

  @override
  Widget build(BuildContext context) {
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: _videoBox()),
            if (_showSubtitles &&
                _activeIdx >= 0 &&
                _player?.value.isInitialized == true &&
                !_controlsVisible)
              _subtitleOverlay(),
            if (_controlsVisible || _streamError != null || !(_player?.value.isInitialized ?? false))
              _controls(
                pad: MediaQuery.of(context).padding,
                inFullscreen: true,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _videoBox(),
            _header(),
            const SizedBox(height: 6),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n is ScrollUpdateNotification && n.dragDetails != null) {
                    if (_autoScroll) setState(() => _autoScroll = false);
                  }
                  return false;
                },
                child: ListView.builder(
                  controller: _listCtrl,
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: _result.segments.length,
                  itemBuilder: (ctx, i) => _row(i),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 16:9 (portrait) or full-bleed (fullscreen) player box with overlays
  Widget _videoBox() {
    final p = _player;
    final initialized = p?.value.isInitialized ?? false;
    final ratio = _fullscreen
        ? MediaQuery.of(context).size.aspectRatio
        : 16 / 9;
    return AspectRatio(
      aspectRatio: ratio,
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (initialized)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tapPlayerArea,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: p!.value.size.width,
                    height: p.value.size.height,
                    child: VideoPlayer(p),
                  ),
                ),
              )
            else
              GestureDetector(
                onTap: _tapPlayerArea,
                child: Center(
                  child: _loadingStream
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.network(
                                'https://i.ytimg.com/vi/${_result.videoId}/mqdefault.jpg',
                                width: 210,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const SizedBox(width: 210, height: 20),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const CircularProgressIndicator(color: Color(0xFFE62117)),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
              ),

            // buffering spinner
            if (initialized &&
                p!.value.isBuffering &&
                !_finished &&
                _streamError == null)
              const Center(
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: CircularProgressIndicator(
                      color: Color(0xFFE62117), strokeWidth: 3),
                ),
              ),

            // subtitle overlay
            if (_showSubtitles &&
                initialized &&
                _activeIdx >= 0 &&
                !_controlsVisible)
              _subtitleOverlay(),

            // controls / errors
            if (_controlsVisible || !initialized || _streamError != null)
              _controls(pad: EdgeInsets.zero, inFullscreen: false),
          ],
        ),
      ),
    );
  }

  Widget _subtitleOverlay() {
    final s = _result.segments[_activeIdx];
    return Positioned(
      left: 16,
      right: 16,
      bottom: 18,
      child: IgnorePointer(
        child: Column(
          children: [
            if (s.tr.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(168),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  s.tr,
                  textDirection: _rtlSub ? TextDirection.rtl : TextDirection.ltr,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    height: 1.65,
                    shadows: [
                      Shadow(blurRadius: 6, color: Colors.black, offset: Offset(0, 1)),
                    ],
                  ),
                ),
              ),
            if (_showSource && s.text.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                s.text,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withAlpha(222),
                  fontSize: 12.5,
                  height: 1.5,
                  shadows: const [Shadow(blurRadius: 5, color: Colors.black)],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _controls({required EdgeInsets pad, required bool inFullscreen}) {
    final p = _player;
    final initialized = p?.value.isInitialized ?? false;
    final v = p?.value;
    final pos = v?.position ?? Duration.zero;
    final dur = v?.duration ?? Duration.zero;

    if (_streamError != null) {
      return Container(
        padding: pad,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black54, Colors.black26, Colors.black54],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 44, color: Colors.white70),
                const SizedBox(height: 10),
                Text(
                  friendlyError(_streamError!),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.7),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _initPlayer,
                  icon: const Icon(Icons.refresh),
                  label: const Text('تلاش دوباره'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: pad,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent, Colors.transparent, Colors.black54],
          stops: [0, 0.16, 0.8, 1],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // ---- top row ----
          Row(
            children: [
              BackButton(
                color: Colors.white,
                onPressed: () {
                  if (inFullscreen && _fullscreen) {
                    _toggleFullscreen();
                  } else if (!inFullscreen) {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
              Expanded(
                child: Text(
                  _result.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              if (inFullscreen && _qualityLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(_qualityLabel,
                      style: const TextStyle(color: Colors.white60, fontSize: 12)),
                ),
            ],
          ),
          // ---- center ----
          if (initialized && !_loadingStream)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 38,
                  color: Colors.white,
                  onPressed: () => _seekRel(-10),
                  icon: const Icon(Icons.replay_10),
                ),
                const SizedBox(width: 20),
                IconButton(
                  iconSize: 60,
                  color: Colors.white,
                  onPressed: _togglePlay,
                  icon: Icon(
                    _finished
                        ? Icons.replay_circle_filled
                        : (v?.isPlaying ?? false)
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                  ),
                ),
                const SizedBox(width: 20),
                IconButton(
                  iconSize: 38,
                  color: Colors.white,
                  onPressed: () => _seekRel(10),
                  icon: const Icon(Icons.forward_10),
                ),
              ],
            )
          else
            const SizedBox(height: 12),
          // ---- bottom bar ----
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: initialized
                ? Row(
                    children: [
                      Text(_fmt(pos),
                          style: const TextStyle(color: Colors.white, fontSize: 12)),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape:
                                const RoundSliderThumbShape(enabledThumbRadius: 6),
                            overlayShape:
                                const RoundSliderOverlayShape(overlayRadius: 12),
                            activeTrackColor: const Color(0xFFE62117),
                            inactiveTrackColor: Colors.white24,
                            thumbColor: const Color(0xFFE62117),
                          ),
                          child: Slider(
                            value: dur > Duration.zero
                                ? pos.inMilliseconds
                                    .clamp(0, dur.inMilliseconds)
                                    .toDouble()
                                : 0,
                            max: dur > Duration.zero
                                ? dur.inMilliseconds.toDouble()
                                : 1,
                            onChanged: dur > Duration.zero
                                ? (val) {
                                    p!.seekTo(Duration(milliseconds: val.round()));
                                    if (_finished) setState(() => _finished = false);
                                  }
                                : null,
                          ),
                        ),
                      ),
                      Text(_fmt(dur),
                          style: const TextStyle(color: Colors.white, fontSize: 12)),
                      IconButton(
                        color: Colors.white,
                        onPressed: () {
                          setState(() => _muted = !_muted);
                          p!.setVolume(_muted ? 0 : 1);
                        },
                        icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                      ),
                      PopupMenuButton<double>(
                        color: const Color(0xFF242327),
                        onSelected: (s) {
                          setState(() => _speed = s);
                          p!.setPlaybackSpeed(s);
                        },
                        itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                            .map((s) => PopupMenuItem<double>(
                                  value: s,
                                  child: Text(
                                    '$s×',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight:
                                          _speed == s ? FontWeight.w800 : FontWeight.w400,
                                    ),
                                  ),
                                ))
                            .toList(),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 8),
                          child: Text(
                            '$_speed×',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      IconButton(
                        color: Colors.white,
                        onPressed: _toggleFullscreen,
                        icon: Icon(
                            _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                      ),
                    ],
                  )
                : const SizedBox(height: 48),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final cs = Theme.of(context).colorScheme;
    final target = langByCode(_result.targetLang ?? 'fa');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _result.title.isEmpty ? _result.videoId : _result.title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, height: 1.4),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  _result.author,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_qualityLabel.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_qualityLabel,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _switching
                    ? null
                    : () async {
                        final picked = await showLanguagePicker(context, target);
                        if (picked != null) await _switchLanguage(picked);
                      },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: cs.primary.withAlpha(28),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: cs.primary.withAlpha(90)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_switching)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Text(target.flag, style: const TextStyle(fontSize: 15)),
                      const SizedBox(width: 7),
                      Text(
                        _switching ? 'در حال ترجمه…' : target.fa,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: cs.primary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.expand_more, size: 17, color: cs.primary),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: _openSummary,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 15),
                      SizedBox(width: 6),
                      Text('خلاصه هوشمند',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'نمایش زیرنویس',
                onPressed: () => setState(() => _showSubtitles = !_showSubtitles),
                icon: Icon(
                  _showSubtitles ? Icons.subtitles : Icons.subtitles_off_outlined,
                  color: _showSubtitles ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
              IconButton(
                tooltip: 'متن اصلی',
                onPressed: () => setState(() => _showSource = !_showSource),
                icon: Icon(
                  Icons.translate,
                  color: _showSource ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(int i) {
    final s = _result.segments[i];
    final active = i == _activeIdx;
    final cs = Theme.of(context).colorScheme;
    final inner = InkWell(
      onTap: () {
        setState(() => _autoScroll = true);
        _seekTo(s.start);
      },
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: s.tr.isNotEmpty ? s.tr : s.text));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('متن کپی شد.'),
          duration: Duration(milliseconds: 900),
        ));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: active ? cs.primary.withAlpha(26) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? cs.primary.withAlpha(110) : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 44,
              child: Text(
                s.tc,
                style: TextStyle(
                  fontSize: 11,
                  color: active ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.tr.isNotEmpty)
                    Text(
                      s.tr,
                      textDirection: _rtlSub ? TextDirection.rtl : TextDirection.ltr,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                        height: 1.8,
                        color: active ? cs.primary : cs.onSurface,
                      ),
                    ),
                  if (_showSource && s.text.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      s.text,
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.55,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (active) {
      return Row(
        key: _activeRowKey,
        children: [Expanded(child: inner)],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: inner,
    );
  }
}

// ================= AI summary sheet ===========================================

class _SummarySheet extends StatefulWidget {
  final TranscriptResult result;
  const _SummarySheet({required this.result});
  @override
  State<_SummarySheet> createState() => _SummarySheetState();
}

class _SummarySheetState extends State<_SummarySheet> {
  String? _summary;
  String? _error;
  bool _loading = true;
  bool _isAi = false; // true = Gemini, false = keyless extractive fallback

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // 1) server-side Gemini summary (when GEMINI_API_KEY is set)
    try {
      final s = await Api().summarize(
        title: widget.result.title,
        segments: widget.result.segments,
        target: widget.result.targetLang ?? 'fa',
      );
      if (mounted) {
        setState(() {
          _summary = s;
          _isAi = true;
          _loading = false;
        });
      }
      return;
    } on ApiException catch (e) {
      if (e.code != 'summarize_failed') {
        if (mounted) {
          setState(() {
            _error = e.message;
            _loading = false;
          });
        }
        return;
      }
      // no key on server → keyless local fallback
    } catch (_) {
      // network/other → try local anyway
    }
    // 2) keyless extractive summary, translated to the target language
    try {
      final bullets = await Api().localSummaryTranslated(
        segments: widget.result.segments,
        target: widget.result.targetLang ?? 'fa',
      );
      if (mounted) {
        setState(() {
          _summary = bullets.map((b) => '• $b').join('\n\n');
          _isAi = false;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError('summarize_failed');
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      maxChildSize: 0.9,
      builder: (ctx, scrollCtrl) => Container(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withAlpha(90),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.auto_awesome, size: 20, color: Color(0xFFE62117)),
                const SizedBox(width: 8),
                const Text('خلاصه هوشمند',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                if (!_loading && _error == null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: (_isAi ? const Color(0xFFE62117) : Colors.blueGrey)
                          .withAlpha(36),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _isAi ? 'Gemini AI' : 'استخراجی',
                      style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                const Spacer(),
                if (_summary != null) ...[
                  IconButton(
                    tooltip: 'کپی',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _summary!));
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('خلاصه کپی شد.')));
                    },
                    icon: const Icon(Icons.copy, size: 19),
                  ),
                  IconButton(
                    tooltip: 'اشتراک‌گذاری',
                    onPressed: () {
                      Share.share(_summary!);
                    },
                    icon: const Icon(Icons.share, size: 19),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: Color(0xFFE62117)))
                  : _error != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(height: 1.7)),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: () {
                                  setState(() {
                                    _loading = true;
                                    _error = null;
                                  });
                                  _load();
                                },
                                icon: const Icon(Icons.refresh),
                                label: const Text('تلاش دوباره'),
                              ),
                            ],
                          ),
                        )
                      : SingleChildScrollView(
                          controller: scrollCtrl,
                          child: Text(
                            _summary!,
                            style: const TextStyle(fontSize: 14.5, height: 1.95),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
