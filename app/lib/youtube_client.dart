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

/// A directly playable stream for the native player:
///  - HLS manifest (adaptive, all qualities, works for EVERY video)
///  - or a progressive muxed mp4 (video+audio, itag 22=720p / 18=360p)
/// Direct URLs come from YouTube's own innertube player endpoint using the
/// same mobile clients YouTube's apps use — exactly how NewPipe-style apps
/// play videos whose owner disabled embedding. No iframe is involved, so
/// "Watch on YouTube / embedding disabled" can never appear.
class YtStream {
  final String url;
  final bool isHls;
  final String label; // quality hint for the UI
  YtStream({required this.url, required this.isHls, this.label = ''});
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

class YouTubeClient {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  // current client versions (parity with yt-dlp 2026.07 client matrix —
  // old versions get bot-gated much harder)
  static const _iosUa =
      'com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';
  static const _androidUa =
      'com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip';
  static const _visionOsUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
  static const _tvUa =
      'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)';

  String _visitorData = '';

  List<Map<String, dynamic>> get _streamClients => [
        {
          'ctx': {
            'clientName': 'IOS',
            'clientVersion': '21.26.4',
            'deviceMake': 'Apple',
            'deviceModel': 'iPhone16,2',
            'osName': 'iPhone',
            'osVersion': '18.3.2.22D82',
            'hl': 'en',
            'gl': 'US',
          },
          'headers': {
            'User-Agent': _iosUa,
            'X-YouTube-Client-Name': '5',
            'X-YouTube-Client-Version': '21.26.4',
          },
        },
        {
          'ctx': {
            'clientName': 'ANDROID',
            'clientVersion': '21.26.364',
            'androidSdkVersion': 30,
            'osName': 'Android',
            'osVersion': '11',
            'hl': 'en',
            'gl': 'US',
          },
          'headers': {
            'User-Agent': _androidUa,
            'X-YouTube-Client-Name': '3',
            'X-YouTube-Client-Version': '21.26.364',
          },
        },
        {
          'ctx': {
            'clientName': 'VISIONOS',
            'clientVersion': '1.02',
            'deviceMake': 'Apple',
            'deviceModel': 'RealityDevice17,1',
            'osName': 'visionOS',
            'osVersion': '26.5.23O471',
            'hl': 'en',
            'gl': 'US',
          },
          'headers': {
            'User-Agent': _visionOsUa,
            'X-YouTube-Client-Name': '101',
            'X-YouTube-Client-Version': '1.02',
          },
        },
        {
          'ctx': {
            'clientName': 'TVHTML5',
            'clientVersion': '7.20260707.07.00',
            'hl': 'en',
            'gl': 'US',
          },
          'headers': {
            'User-Agent': _tvUa,
            'X-YouTube-Client-Name': '7',
            'X-YouTube-Client-Version': '7.20260707.07.00',
          },
        },
      ];

  Future<Map<String, dynamic>> _playerCall(Map<String, dynamic> c, String videoId) async {
    final res = await http.post(
      Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
      headers: {
        'Content-Type': 'application/json',
        ...(c['headers'] as Map<String, String>),
        if (_visitorData.isNotEmpty) 'X-Goog-Visitor-Id': _visitorData,
      },
      body: jsonEncode({
        'context': {
          'client': {
            ...(c['ctx'] as Map<String, dynamic>),
            if (_visitorData.isNotEmpty) 'visitorData': _visitorData,
          },
        },
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      }),
    ).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw YtFetchException('playback_failed');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Resolve a playable stream for [videoId]. Device-side chain:
  ///  1. innertube clients raced in parallel (IOS 21.26.4, ANDROID 21.26.364,
  ///     VISIONOS 1.02, TVHTML5 7.x) — direct HLS/muxed URLs bound to the
  ///     DEVICE's IP; these clients never had embed restrictions, so every
  ///     video plays
  ///  2. on bot-gate: sw.js_data → visitorData → parallel retry
  ///  3. Piped proxy (IP-independent last net)
  Future<YtStream> fetchStreamInfo(String videoId) async {
    // ---- round 1: plain clients (parallel race) ----------------------------
    final r1 = await _raceClients(videoId);
    if (r1.stream != null) return r1.stream!;

    // ---- round 2: visitor-data retry (bot-gate softener) ------------------
    if (r1.gated && _visitorData.isEmpty) {
      await _loadVisitorData();
    }
    if (_visitorData.isNotEmpty) {
      final r2 = await _raceClients(videoId);
      if (r2.stream != null) return r2.stream!;
    }

    // ---- round 3: Piped proxy (IP-independent) ----------------------------
    final piped = await _viaPiped(videoId);
    if (piped != null) return piped;

    throw YtFetchException('playback_failed');
  }

  Future<({YtStream? stream, bool gated})> _raceClients(String videoId) async {
    final results = await Future.wait(
      _streamClients.map((c) async {
        try {
          final pr = await _playerCall(c, videoId);
          final s = _streamFromPlayerResponse(pr);
          if (s != null) return (stream: s, gated: false);
          final st =
              (((pr['playabilityStatus'] ?? {}) as Map)['status'] ?? '').toString();
          return (stream: null as YtStream?, gated: st == 'LOGIN_REQUIRED' || st == 'UNPLAYABLE');
        } on YtFetchException catch (e) {
          if (e.code != 'playback_failed') rethrow; // definitive
          return (stream: null as YtStream?, gated: false);
        } catch (_) {
          return (stream: null as YtStream?, gated: false);
        }
      }),
      eagerError: false,
    );
    for (final r in results) {
      if (r.stream != null) return (stream: r.stream, gated: false);
    }
    final gated = results.any((r) => r.gated);
    return (stream: null, gated: gated);
  }

  /// visitorData from sw.js_data — measurably reduces LOGIN_REQUIRED gates
  Future<bool> _loadVisitorData() async {
    try {
      final r = await http.get(
        Uri.parse('https://www.youtube.com/sw.js_data'),
        headers: {
          'User-Agent': _ua,
          'Accept-Language': 'en-US,en;q=0.9',
          'Cookie': 'CONSENT=YES+cb; SOCS=CAI',
        },
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return false;
      final m = RegExp(r'"(C[a-zA-Z0-9_%\-]{100,})"').allMatches(r.body);
      for (final mm in m) {
        final cand = mm.group(1)!;
        if (cand.contains('%3D')) {
          _visitorData = cand;
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  static const _pipedApis = [
    'https://pipedapi.adminforge.de',
    'https://pipedapi.kavin.rocks',
  ];

  /// Piped fallback — their stream URLs are proxied through their own domain,
  /// so they play regardless of which IP requests them.
  Future<YtStream?> _viaPiped(String videoId) async {
    for (final api in _pipedApis) {
      try {
        final res = await http.get(
          Uri.parse('$api/streams/$videoId'),
          headers: {'User-Agent': _ua, 'Accept': 'application/json'},
        ).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) continue;
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        if (j.containsKey('error') || j.containsKey('message')) continue;
        final hls = (j['hls'] ?? '').toString();
        if (hls.isNotEmpty) return YtStream(url: hls, isHls: true, label: 'HLS');
        // muxed (audio+video) streams: videoStreams with videoOnly=false
        final vs = ((j['videoStreams'] as List?) ?? [])
            .cast<Map<String, dynamic>>()
            .where((v) => v['videoOnly'] != true && (v['url'] ?? '').toString().isNotEmpty)
            .toList();
        Map<String, dynamic>? best;
        int bestH = 0;
        for (final v in vs) {
          final q = (v['quality'] ?? '').toString();
          final h = int.tryParse(q.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
          if (h > bestH) {
            best = v;
            bestH = h;
          }
        }
        if (best != null) {
          return YtStream(
            url: (best['url'] as String),
            isHls: false,
            label: '${best['quality'] ?? ''} (proxy)',
          );
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Extract a playable stream from an innertube/watch player response.
  YtStream? _streamFromPlayerResponse(Map<String, dynamic> pr) {
    final ps = (pr['playabilityStatus'] ?? {}) as Map<String, dynamic>;
    final status = (ps['status'] ?? '').toString();
    if (status == 'LIVE_STREAM_OFFLINE' || status == 'LIVE') {
      // live streams: HLS is still playable → let caller try hls below
    } else if (status == 'LOGIN_REQUIRED') {
      final reason = (ps['reason'] ?? '').toString().toLowerCase();
      if (reason.contains('age')) throw YtFetchException('age_restricted');
      return null; // bot-gate on this client → try next
    } else if (status == 'ERROR') {
      final reason = (ps['reason'] ?? '').toString().toLowerCase();
      if (reason.contains('copyright')) throw YtFetchException('copyright_blocked');
      if (reason.contains('unavailable') ||
          reason.contains('not found') ||
          reason.contains('removed') ||
          reason.contains('private')) {
        throw YtFetchException('video_not_found');
      }
      throw YtFetchException('video_unavailable');
    } else if (status != 'OK') {
      return null;
    }

    final sd = (pr['streamingData'] ?? {}) as Map<String, dynamic>;
    final hls = (sd['hlsManifestUrl'] ?? '').toString();
    if (hls.isNotEmpty) return YtStream(url: hls, isHls: true, label: 'HLS');

    // progressive muxed fallback (itag 22 = 720p, 18 = 360p)
    final formats = (sd['formats'] as List?) ?? const [];
    String? best;
    int bestItag = 0;
    for (final f in formats) {
      final fm = f as Map<String, dynamic>;
      final url = (fm['url'] ?? '').toString();
      final itag = (fm['itag'] ?? 0) as int;
      if (url.isEmpty) continue;
      if (fm['signatureCipher'] != null) continue; // ciphered → not directly playable
      if (itag == 22 || itag == 18) {
        if (itag > bestItag) {
          best = url;
          bestItag = itag;
        }
      }
    }
    if (best != null) {
      return YtStream(url: best, isHls: false, label: bestItag == 22 ? '720p' : '360p');
    }
    return null;
  }

  Future<String> _getWatchPage(String videoId) async {
    final res = await http.get(
      Uri.parse('https://www.youtube.com/watch?v=$videoId&hl=en&has_verified=1'),
      headers: _browserHeaders,
    ).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw YtFetchException('transcript_fetch_failed');
    return res.body;
  }

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

  // ---- method 1: watch page -------------------------------------------------
  Future<YtVideo> _viaWatchPage(String videoId, String title, String author) async {
    final body = await _getWatchPage(videoId);
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
          'clientVersion': '21.26.4',
          'deviceMake': 'Apple',
          'deviceModel': 'iPhone16,2',
          'osName': 'iPhone',
          'osVersion': '18.3.2.22D82',
          'hl': 'en',
          'gl': 'US',
        },
        'headers': {'User-Agent': _iosUa, 'X-YouTube-Client-Name': '5', 'X-YouTube-Client-Version': '21.26.4'},
      },
      {
        'ctx': {
          'clientName': 'ANDROID',
          'clientVersion': '21.26.364',
          'androidSdkVersion': 30,
          'hl': 'en',
          'gl': 'US',
        },
        'headers': {'User-Agent': _androidUa, 'X-YouTube-Client-Name': '3', 'X-YouTube-Client-Version': '21.26.364'},
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

/// A YouTube search result (same fields as the original app's
/// youtube_search_result model).
class YtSearchResult {
  final String videoId;
  final String title;
  final String channel;
  final String duration; // "12:34" or live/short hints
  final String thumbUrl;
  YtSearchResult({
    required this.videoId,
    required this.title,
    required this.channel,
    required this.duration,
    required this.thumbUrl,
  });
}

/// Device-side YouTube search through the public innertube search endpoint
/// (WEB client) — same capability as the original app's search screen.
Future<List<YtSearchResult>> searchYouTube(String query, {String? continuation}) async {
  final res = await http.post(
    Uri.parse('https://www.youtube.com/youtubei/v1/search?prettyPrint=false'),
    headers: {
      'Content-Type': 'application/json',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      'Accept-Language': 'en-US,en;q=0.9',
    },
    body: jsonEncode({
      'context': {'client': {'clientName': 'WEB', 'clientVersion': '2.20250312.04.00', 'hl': 'en', 'gl': 'US'}},
      'query': query,
    }),
  ).timeout(const Duration(seconds: 12));
  if (res.statusCode != 200) throw YtFetchException('search_failed');

  final results = <YtSearchResult>[];
  // walk the tree and collect every videoRenderer
  void walk(dynamic node) {
    if (node is List) {
      for (final n in node) {
        walk(n);
      }
      return;
    }
    if (node is Map<String, dynamic>) {
      final vr = node['videoRenderer'];
      if (vr is Map<String, dynamic>) {
        final id = (vr['videoId'] ?? '').toString();
        if (id.isEmpty) return;
        String title = '';
        final t = vr['title'];
        if (t is Map<String, dynamic>) {
          title = (((t['runs'] as List?) ?? []).cast<Map<String, dynamic>>()
                  .map((r) => (r['text'] ?? '').toString()).join())
              .trim();
        }
        String channel = '';
        final owner = vr['ownerText'] ?? vr['longBylineText'];
        if (owner is Map<String, dynamic>) {
          channel = (((owner['runs'] as List?) ?? []).cast<Map<String, dynamic>>()
                  .map((r) => (r['text'] ?? '').toString()).join())
              .trim();
        }
        String duration = '';
        final d = vr['lengthText'];
        if (d is Map<String, dynamic>) duration = (d['simpleText'] ?? '').toString();
        final badges = (vr['badges'] as List?) ?? const [];
        for (final b in badges) {
          final label = ((((b as Map)['metadataBadgeRenderer'] ?? {}) as Map)['label'] ?? '').toString();
          if (label.toUpperCase().contains('LIVE')) duration = 'LIVE';
        }
        String thumb = 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
        results.add(YtSearchResult(
          videoId: id,
          title: title.isEmpty ? id : title,
          channel: channel,
          duration: duration,
          thumbUrl: thumb,
        ));
        return;
      }
      for (final v in node.values) {
        walk(v);
      }
    }
  }

  walk(jsonDecode(res.body));
  return results.take(30).toList(growable: false);
}
