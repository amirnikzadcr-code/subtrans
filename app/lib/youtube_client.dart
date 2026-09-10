import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Client-side YouTube transcript fetch — runs from the device (residential
/// IP), exactly like YouTube's own "Show transcript" panel and the
/// youtube-transcript-api approach:
///
///   1. GET  /watch?v=ID            → ytInitialPlayerResponse.captionTracks
///   2. GET  timedtext baseUrl&fmt=json3 → segments
///   (fallback) /youtubei/v1/player with current IOS/ANDROID clients → timedtext
///
/// NOTE (2026-09): the old /next + get_transcript two-step now returns
/// "Precondition check failed" (YouTube tightened it) — do not use.
class YtSegment {
  final int start;
  final int dur;
  final String text;
  YtSegment({required this.start, required this.dur, required this.text});
}

class YtFetchException implements Exception {
  final String code; // same taxonomy as the original app
  YtFetchException(this.code);
}

class YtVideo {
  final String videoId;
  final String title;
  final String author;
  final String sourceLang;
  final bool isAsr;
  final List<YtSegment> segments;
  YtVideo({
    required this.videoId,
    required this.title,
    required this.author,
    required this.segments,
    this.sourceLang = '',
    this.isAsr = false,
  });
}

/// Direct playback info — this is how the app plays ALL videos (including
/// ones whose embedding is disabled, where the old iframe player showed
/// "Watch on YouTube"): we mint the same stream URLs YouTube's own mobile
/// apps get from innertube and feed them to a native player (ExoPlayer).
class YtStream {
  final String url;
  final bool isHls; // true → HLS master playlist, false → progressive mp4
  final int expiresInSeconds;
  YtStream({required this.url, required this.isHls, this.expiresInSeconds = 21540});
}

class YouTubeClient {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const _iosUa =
      'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)';

  /// UA to use when downloading the streams themselves (must look like the
  /// client that minted them, same trick as the timedtext fetch).
  static const playbackUa = _iosUa;
  static const _androidUa =
      'com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip';

  Map<String, String> get _browserHeaders => {
        'User-Agent': _ua,
        'Accept-Language': 'en-US,en;q=0.9',
        'Cookie': 'CONSENT=YES+cb; SOCS=CAI',
      };

  Future<YtVideo> fetchTranscript(String videoId) async {
    // metadata via oEmbed (public, reliable)
    var title = '';
    var author = '';
    try {
      final meta = await http.get(
        Uri.parse('https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$videoId&format=json'),
        headers: {'User-Agent': _ua},
      ).timeout(const Duration(seconds: 8));
      if (meta.statusCode == 200) {
        final m = jsonDecode(meta.body) as Map<String, dynamic>;
        title = (m['title'] ?? '').toString();
        author = (m['author_name'] ?? '').toString();
      } else if (meta.statusCode == 401 || meta.statusCode == 404) {
        throw YtFetchException('video_not_found');
      }
    } on YtFetchException {
      rethrow;
    } catch (_) {/* metadata is best-effort */}

    // 1) watch page → captionTracks (residential-IP method)
    try {
      final v = await _viaWatchPage(videoId, title, author);
      return v;
    } on YtFetchException catch (e) {
      if (e.code == 'video_not_found' ||
          e.code == 'video_is_live' ||
          e.code == 'age_restricted' ||
          e.code == 'copyright_blocked') {
        rethrow; // definitive errors — no point retrying another method
      }
      // fall through to innertube
    }

    // 2) innertube player (IOS → ANDROID) with current client versions
    final innertube = await _viaInnertube(videoId, title, author);
    if (innertube != null) return innertube;

    throw YtFetchException('transcript_fetch_failed');
  }

  /// Direct stream playback info — device-side, exactly like YouTube's own
  /// mobile apps. This is the "plays every video" mechanism:
  ///
  ///   1. innertube /player with the IOS client → streamingData.hlsManifestUrl
  ///      (adaptive HLS up to 4K — this is what the iOS app streams)
  ///   2. ANDROID_VR client → muxed progressive itag (360p) fallback
  ///
  /// Because the request comes from the device's own IP, the minted URLs are
  /// valid for this device — no embed/iframe involved, so "embedding disabled"
  /// videos play fine too.
  Future<YtStream> fetchStreamInfo(String videoId) async {
    final clients = [
      {
        'ctx': {
          'clientName': 'IOS',
          'clientVersion': '20.10.4',
          'deviceMake': 'Apple',
          'deviceModel': 'iPhone16,2',
          'osName': 'iPhone',
          'osVersion': '18.1.0.22B83',
          'hl': 'en',
          'gl': 'US',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
        },
        'headers': const {
          'User-Agent': _iosUa,
          'X-YouTube-Client-Name': '5',
          'X-YouTube-Client-Version': '20.10.4',
        },
      },
      {
        'ctx': {
          'clientName': 'ANDROID_VR',
          'clientVersion': '1.60.19',
          'deviceMake': 'Oculus',
          'deviceModel': 'Quest 3',
          'osName': 'Android',
          'osVersion': '12',
          'androidSdkVersion': 31,
          'hl': 'en',
          'gl': 'US',
        },
        'headers': const {
          'User-Agent':
              'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12; eureka-user Build/SQ3A.220605.009.A1) gzip',
          'X-YouTube-Client-Name': '28',
          'X-YouTube-Client-Version': '1.60.19',
        },
      },
    ];

    for (final c in clients) {
      try {
        final res = await http.post(
          Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
          headers: {'Content-Type': 'application/json', ...(c['headers'] as Map<String, String>)},
          body: jsonEncode({
            'context': {'client': c['ctx']},
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
          }),
        ).timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) continue;
        final pr = jsonDecode(res.body) as Map<String, dynamic>;

        final ps = (pr['playabilityStatus'] ?? {}) as Map<String, dynamic>;
        final status = (ps['status'] ?? '').toString();
        if (status == 'LIVE_STREAM_OFFLINE') throw YtFetchException('video_is_live');
        if (status == 'LOGIN_REQUIRED') {
          final reason = (ps['reason'] ?? '').toString().toLowerCase();
          if (reason.contains('age')) throw YtFetchException('age_restricted');
          continue; // bot-gate on this client → try next client
        }
        if (status == 'ERROR') {
          final reason = (ps['reason'] ?? '').toString().toLowerCase();
          if (reason.contains('copyright')) throw YtFetchException('copyright_blocked');
          if (reason.contains('unavailable') ||
              reason.contains('not found') ||
              reason.contains('removed')) {
            throw YtFetchException('video_not_found');
          }
          throw YtFetchException('video_unavailable');
        }
        if (status != 'OK') continue;

        final sd = (pr['streamingData'] ?? {}) as Map<String, dynamic>;
        final hls = (sd['hlsManifestUrl'] ?? '').toString();
        if (hls.isNotEmpty) {
          return YtStream(url: hls, isHls: true);
        }
        // progressive muxed fallback (ANDROID_VR/ANDROID give itag 18/22)
        final formats = (sd['formats'] as List?) ?? const [];
        String? best;
        int bestItag = 0;
        for (final f in formats) {
          final fm = f as Map<String, dynamic>;
          final url = (fm['url'] ?? '').toString();
          final itag = (fm['itag'] ?? 0) as int;
          if (url.isEmpty) continue;
          if (itag == 22 || itag == 18) {
            if (itag > bestItag) {
              best = url;
              bestItag = itag;
            }
          }
        }
        if (best != null) return YtStream(url: best, isHls: false);
      } on YtFetchException {
        rethrow;
      } catch (_) {
        continue;
      }
    }
    throw YtFetchException('playback_failed');
  }

  // ---- method 1: watch page -------------------------------------------------
  Future<YtVideo> _viaWatchPage(String videoId, String title, String author) async {
    final res = await http.get(
      Uri.parse('https://www.youtube.com/watch?v=$videoId&hl=en&has_verified=1'),
      headers: _browserHeaders,
    ).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw YtFetchException('transcript_fetch_failed');

    final body = res.body;
    final m = RegExp(r'ytInitialPlayerResponse\s*=\s*(\{.+?\})\s*;\s*(?:var|const|</script>)', dotAll: true)
        .firstMatch(body) ??
        RegExp(r'ytInitialPlayerResponse\s*=\s*(\{.+?\});', dotAll: true).firstMatch(body);
    if (m == null) throw YtFetchException('transcript_fetch_failed');

    Map<String, dynamic> pr;
    try {
      pr = jsonDecode(m.group(1)!) as Map<String, dynamic>;
    } catch (_) {
      throw YtFetchException('transcript_fetch_failed');
    }

    final status = (((pr['playabilityStatus'] ?? {}) as Map)['status'] ?? '').toString();
    if (status == 'LIVE_STREAM_OFFLINE') throw YtFetchException('video_is_live');
    if (status == 'LOGIN_REQUIRED') {
      final reason = (((pr['playabilityStatus'] ?? {}) as Map)['reason'] ?? '').toString().toLowerCase();
      if (reason.contains('age')) throw YtFetchException('age_restricted');
      // bot-check on the device is rare; treat as generic failure
      throw YtFetchException('transcript_fetch_failed');
    }
    if (status == 'ERROR') {
      final reason = (((pr['playabilityStatus'] ?? {}) as Map)['reason'] ?? '').toString().toLowerCase();
      if (reason.contains('copyright')) throw YtFetchException('copyright_blocked');
      if (reason.contains('unavailable') || reason.contains('not found') || reason.contains('removed')) {
        throw YtFetchException('video_not_found');
      }
      throw YtFetchException('video_unavailable');
    }

    final tracks = (((pr['captions'] ?? {}) as Map)['playerCaptionsTracklistRenderer'] ?? {})
    as Map<String, dynamic>;
    final list = ((tracks['captionTracks'] ?? []) as List).cast<Map<String, dynamic>>();
    if (list.isEmpty) throw YtFetchException('no_speech');

    // captions-first: manual of any lang → first manual → ASR (original logic)
    final manual = list.where((t) => t['kind'] != 'asr').toList();
    final asr = list.where((t) => t['kind'] == 'asr').toList();
    final track = (manual.isNotEmpty ? manual.first : asr.first);

    final segs = await _downloadTimedtext(track['baseUrl'] as String, _ua, _browserHeaders);
    return YtVideo(
      videoId: videoId,
      title: title,
      author: author,
      sourceLang: (track['languageCode'] ?? '').toString(),
      isAsr: track['kind'] == 'asr',
      segments: segs,
    );
  }

  // ---- method 2: innertube player (IOS/ANDROID, current versions) -----------
  Future<YtVideo?> _viaInnertube(String videoId, String title, String author) async {
    final clients = [
      {
        'ctx': {
          'clientName': 'IOS',
          'clientVersion': '20.10.4',
          'deviceMake': 'Apple',
          'deviceModel': 'iPhone16,2',
          'osName': 'iPhone',
          'osVersion': '18.1.0.22B83',
          'hl': 'en',
          'gl': 'US',
        },
        'headers': {'User-Agent': _iosUa, 'X-YouTube-Client-Name': '5', 'X-YouTube-Client-Version': '20.10.4'},
      },
      {
        'ctx': {
          'clientName': 'ANDROID',
          'clientVersion': '20.10.38',
          'androidSdkVersion': 34,
          'hl': 'en',
          'gl': 'US',
        },
        'headers': {'User-Agent': _androidUa, 'X-YouTube-Client-Name': '3', 'X-YouTube-Client-Version': '20.10.38'},
      },
    ];

    for (final c in clients) {
      try {
        final res = await http.post(
          Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
          headers: {'Content-Type': 'application/json', ...(c['headers'] as Map<String, String>)},
          body: jsonEncode({
            'context': {'client': c['ctx']},
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
          }),
        ).timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) continue;
        final pr = jsonDecode(res.body) as Map<String, dynamic>;
        final tracks = (((pr['captions'] ?? {}) as Map)['playerCaptionsTracklistRenderer'] ?? {})
        as Map<String, dynamic>;
        final list = ((tracks['captionTracks'] ?? []) as List).cast<Map<String, dynamic>>();
        if (list.isEmpty) continue;

        final manual = list.where((t) => t['kind'] != 'asr').toList();
        final asr = list.where((t) => t['kind'] == 'asr').toList();
        final track = (manual.isNotEmpty ? manual.first : asr.first);
        final ua = (c['headers'] as Map<String, String>)['User-Agent']!;
        final segs = await _downloadTimedtext(track['baseUrl'] as String, ua, null);
        if (segs.isEmpty) continue;
        return YtVideo(
          videoId: videoId,
          title: title,
          author: author,
          sourceLang: (track['languageCode'] ?? '').toString(),
          isAsr: track['kind'] == 'asr',
          segments: segs,
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  // ---- timedtext download: json3 → srv3 → legacy xml ------------------------
  Future<List<YtSegment>> _downloadTimedtext(
      String baseUrl, String ua, Map<String, String>? extraHeaders) async {
    final urls = [
      '$baseUrl${baseUrl.contains('?') ? '&' : '?'}fmt=json3',
      baseUrl,
    ];
    for (final u in urls) {
      try {
        final res = await http.get(
          Uri.parse(u),
          headers: {'User-Agent': ua, 'Referer': 'https://www.youtube.com/', ...?extraHeaders},
        ).timeout(const Duration(seconds: 10));
        if (res.statusCode != 200) continue;
        final body = res.body.trim();
        if (body.isEmpty) continue;
        final segs = _parseCaptionBody(body);
        if (segs.isNotEmpty) return _merge(segs);
      } catch (_) {
        continue;
      }
    }
    return const <YtSegment>[];
  }

  List<YtSegment> _parseCaptionBody(String body) {
    final out = <YtSegment>[];
    if (body.startsWith('{')) {
      try {
        final j = jsonDecode(body) as Map<String, dynamic>;
        for (final e in (j['events'] as List?) ?? []) {
          final ev = e as Map<String, dynamic>;
          final segs = ev['segs'] as List?;
          if (segs == null) continue;
          final text = segs.map((s) => ((s as Map)['utf8'] ?? '').toString()).join();
          final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (t.isEmpty) continue;
          out.add(YtSegment(
            start: (ev['tStartMs'] ?? 0) as int,
            dur: (ev['dDurationMs'] ?? 0) as int,
            text: t,
          ));
        }
      } catch (_) {}
      return out;
    }
    if (body.startsWith('<')) {
      // srv3: <p t="1200" d="3400"><s>word</s>…</p>
      final reSrv3 = RegExp(r'<p t="(\d+)"(?: d="(\d+)")?[^>]*>([\s\S]*?)</p>');
      for (final m in reSrv3.allMatches(body)) {
        final text = _decodeEntities(m.group(3)!.replaceAll(RegExp(r'<[^>]+>'), ''))
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (text.isEmpty) continue;
        out.add(YtSegment(
          start: int.tryParse(m.group(1)!) ?? 0,
          dur: int.tryParse(m.group(2) ?? '3000') ?? 3000,
          text: text,
        ));
      }
      if (out.isNotEmpty) return out;
      // legacy: <text start="1.2" dur="3.4">…</text>
      final reLegacy = RegExp(r'<text start="([\d.]+)"(?: dur="([\d.]+)")?[^>]*>([\s\S]*?)</text>');
      for (final m in reLegacy.allMatches(body)) {
        final text = _decodeEntities(m.group(3)!.replaceAll(RegExp(r'<[^>]+>'), ''))
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (text.isEmpty) continue;
        out.add(YtSegment(
          start: ((double.tryParse(m.group(1)!) ?? 0) * 1000).round(),
          dur: ((double.tryParse(m.group(2) ?? '3') ?? 3) * 1000).round(),
          text: text,
        ));
      }
    }
    return out;
  }

  String _decodeEntities(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
  }

  List<YtSegment> _merge(List<YtSegment> segs) {
    final out = <YtSegment>[];
    YtSegment? buf;
    for (final s in segs) {
      if (buf != null && s.start - buf.start < 4200 && buf.text.length < 90) {
        buf = YtSegment(
          start: buf.start,
          dur: s.start + s.dur - buf.start,
          text: '${buf.text} ${s.text}',
        );
      } else {
        if (buf != null) out.add(buf);
        buf = s;
      }
    }
    if (buf != null) out.add(buf);
    return out.take(1200).toList(growable: false);
  }
}

/// index of the active segment for a playback position (ms) — linear pointer
/// is enough (position advances monotonically in practice).
int activeSegmentIndex(List<dynamic> segments, int positionMs, [int hint = 0]) {
  var i = math.min(hint, segments.length - 1);
  if (i < 0) return 0;
  int startOf(dynamic s) => (s.start as num).toInt();
  int endOf(dynamic s) => (s.start as num).toInt() + (s.dur as num).toInt();
  if (positionMs < startOf(segments.first)) return -1;
  while (i > 0 && positionMs < startOf(segments[i])) {
    i--;
  }
  while (i < segments.length - 1 && positionMs >= endOf(segments[i])) {
    i++;
  }
  return positionMs >= startOf(segments[i]) && positionMs < endOf(segments[i]) ? i : -1;
}
