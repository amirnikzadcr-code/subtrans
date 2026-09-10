import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'youtube_client.dart';

/// API client — mirrors the original app's thin-client pattern:
/// action-based requests against the Cloudflare Worker backend.
class ApiException implements Exception {
  final String code;
  final String message;
  ApiException(this.code, this.message);
  @override
  String toString() => message;
}

class Segment {
  final int start;
  final int dur;
  final String text;
  final String tr;
  Segment({required this.start, required this.dur, required this.text, required this.tr});

  String get tc {
    final d = Duration(milliseconds: start);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Map<String, dynamic> toJson() => {'start': start, 'dur': dur, 'text': text, 'tr': tr};
  factory Segment.fromJson(Map<String, dynamic> m) => Segment(
        start: (m['start'] ?? 0) as int,
        dur: (m['dur'] ?? 0) as int,
        text: (m['text'] ?? '').toString(),
        tr: (m['tr'] ?? '').toString(),
      );
}

class TranscriptResult {
  final String videoId;
  final String title;
  final String author;
  final int lengthSeconds;
  final String sourceLang;
  final String? targetLang;
  final bool isAsr;
  final String? engine;
  final List<Segment> segments;
  TranscriptResult({
    required this.videoId,
    required this.title,
    required this.author,
    required this.lengthSeconds,
    required this.sourceLang,
    required this.segments,
    this.targetLang,
    this.isAsr = false,
    this.engine,
  });

  Map<String, dynamic> toJson() => {
        'videoId': videoId,
        'title': title,
        'author': author,
        'lengthSeconds': lengthSeconds,
        'sourceLang': sourceLang,
        'targetLang': targetLang,
        'isAsr': isAsr,
        'segments': segments.map((s) => s.toJson()).toList(),
      };

  factory TranscriptResult.fromJson(Map<String, dynamic> m) => TranscriptResult(
        videoId: (m['videoId'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        author: (m['author'] ?? '').toString(),
        lengthSeconds: (m['lengthSeconds'] ?? 0) as int,
        sourceLang: (m['sourceLang'] ?? '').toString(),
        targetLang: m['targetLang']?.toString(),
        isAsr: m['isAsr'] == true,
        segments: ((m['segments'] as List?) ?? [])
            .map((s) => Segment.fromJson(Map<String, dynamic>.from(s)))
            .toList(),
      );
}

class Api {
  /// Cloudflare Worker base URL — same role as the original's API_BASE_URL/.env
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://subtrans-api.amirnft191.workers.dev',
  );

  /// word-boundary-safe clip so we never split surrogate pairs / words
  static String _clipForSummary(String s, int max) {
    if (s.length <= max) return s;
    var cut = s.substring(0, max);
    final sp = cut.lastIndexOf(' ');
    if (sp > max * 0.6) cut = cut.substring(0, sp);
    return cut;
  }

  /// Translate a batch of segment texts via the Worker
  /// (Gemini primary → gtx fallback, same engine chain as the original).
  Future<List<String>> translateTexts(List<String> texts, String target) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      try {
        final res = await http.post(
          Uri.parse('$baseUrl/?action=translate'),
          headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
          body: jsonEncode({'texts': texts, 'target': target}),
        ).timeout(const Duration(seconds: 90));
        final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        if (j.containsKey('error')) {
          final e = j['error'] as Map<String, dynamic>;
          final code = (e['code'] ?? '').toString();
          if (code == 'translation_failed' && attempt < 1) {
            lastError = ApiException(code, friendlyError(code));
            continue;
          }
          throw ApiException(code, friendlyError(code));
        }
        return ((j['segments'] as List?) ?? []).map((s) => s.toString()).toList();
      } on ApiException {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? ApiException('translation_failed', friendlyError('translation_failed'));
  }

  /// AI summary of the whole transcript via the Worker (Gemini), in the
  /// target language — mirrors the original app's summarize feature.
  Future<String> summarize({
    required String title,
    required List<Segment> segments,
    required String target,
  }) async {
    final text = segments.map((s) => s.text).join(' ');
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(milliseconds: 800));
      try {
        final res = await http
            .post(
              Uri.parse('$baseUrl/?action=summarize'),
              headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: jsonEncode({
                'title': title,
                'text': _clipForSummary(text, 14000),
                'target': target,
              }),
            )
            .timeout(const Duration(seconds: 120));
        final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        if (j.containsKey('error')) {
          final e = j['error'] as Map<String, dynamic>;
          final code = (e['code'] ?? '').toString();
          if (attempt < 1) {
            lastError = ApiException(code, friendlyError(code));
            continue;
          }
          throw ApiException(code, friendlyError(code));
        }
        final sum = (j['summary'] ?? '').toString();
        if (sum.isEmpty) throw ApiException('summarize_failed', friendlyError('summarize_failed'));
        return sum;
      } on ApiException {
        rethrow;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? ApiException('summarize_failed', friendlyError('summarize_failed'));
  }

  // ---- keyless AI summary fallback -----------------------------------------
  // Extractive summarization (frequency-scored sentence selection) + machine
  // translation via the Worker. Works with zero API keys, so the "خلاصه
  // هوشمند" feature is always available, even before a Gemini key is set.

  static const _stopWords = {
    'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all', 'any', 'can', 'her',
    'was', 'one', 'our', 'out', 'day', 'get', 'has', 'him', 'his', 'how', 'man',
    'new', 'now', 'old', 'see', 'two', 'way', 'who', 'its', 'did', 'that', 'this',
    'with', 'have', 'from', 'they', 'will', 'would', 'there', 'their', 'what',
    'about', 'which', 'when', 'make', 'like', 'time', 'just', 'know', 'take',
    'into', 'year', 'your', 'good', 'some', 'them', 'other', 'than', 'then',
    'look', 'only', 'come', 'over', 'also', 'back', 'after', 'use',
    'work', 'first', 'well', 'even', 'want', 'because', 'these', 'going',
  };

  /// pick the most informative sentences of the transcript
  static List<String> extractiveSentences(List<Segment> segments, int maxSentences) {
    final text = segments.map((s) => s.text).join(' ').replaceAll(RegExp(r'\s+'), ' ');
    final sentenceRe = RegExp(r'[^.!?؟。\n]{25,400}[.!?؟。]+|[^.!?؟。\n]{40,}$');
    final sentences =
        sentenceRe.allMatches(text).map((m) => m.group(0)!.trim()).toList();
    if (sentences.length <= maxSentences) return sentences;

    final freq = <String, int>{};
    void countWords(String s) {
      for (final w in s
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z\u0600-\u06FF\s]'), ' ')
          .split(RegExp(r'\s+'))) {
        if (w.length < 3 || _stopWords.contains(w)) continue;
        freq[w] = (freq[w] ?? 0) + 1;
      }
    }

    for (final s in sentences) {
      countWords(s);
    }

    double score(int i) {
      final s = sentences[i];
      var sc = 0.0;
      for (final w in s
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z\u0600-\u06FF\s]'), ' ')
          .split(RegExp(r'\s+'))) {
        sc += freq[w] ?? 0;
      }
      sc /= (s.length + 1);
      // early sentences carry definitions/intros → small position bonus
      sc *= 1 + 0.2 * (1 - i / sentences.length);
      // spread bonus: prefer sentences spread across the video
      final pos = i / sentences.length;
      sc *= 1 + 0.35 * (1 - (pos - 0.5).abs() * 2).clamp(0.0, 1.0);
      return sc;
    }

    final ranked = List<int>.generate(sentences.length, (i) => i)
      ..sort((a, b) => score(b).compareTo(score(a)));
    final picked = ranked.take(maxSentences).toList()..sort();
    return picked.map((i) => sentences[i]).toList();
  }

  /// local (keyless) summary: extract + translate each bullet
  Future<List<String>> localSummaryTranslated({
    required List<Segment> segments,
    required String target,
    int maxSentences = 7,
  }) async {
    final picked = extractiveSentences(segments, maxSentences);
    if (picked.isEmpty) return const [];
    try {
      return await translateTexts(picked, target);
    } catch (_) {
      return picked;
    }
  }

  Future<Map<String, String>> availableLanguages(String videoId) async {
    final uri = Uri.parse('$baseUrl/?action=youtube_asr_languages&v=$videoId');
    final j = await _get(uri);
    final list = (j['languages'] as List?) ?? [];
    final map = <String, String>{};
    for (final e in list) {
      map[(e['code'] ?? '').toString()] = (e['name'] ?? '').toString();
    }
    return map;
  }

  /// Worker-side transcript fetch + translate (fallback path)
  Future<TranscriptResult> youtubeAsrRaw({
    required String videoId,
    required String target,
    String? lang,
  }) async {
    final q = <String, String>{
      'action': 'youtube_asr',
      'v': videoId,
      'target': target,
      if (lang != null && lang.isNotEmpty) 'lang': lang,
    };
    final j = await _get(Uri.parse(baseUrl).replace(queryParameters: q));
    final segs = (j['segments'] as List?) ?? [];
    return TranscriptResult(
      videoId: (j['video_id'] ?? videoId).toString(),
      title: (j['title'] ?? '').toString(),
      author: (j['author'] ?? '').toString(),
      lengthSeconds: (j['length_seconds'] ?? 0) is int ? j['length_seconds'] as int : 0,
      sourceLang: (j['source_lang'] ?? '').toString(),
      targetLang: j['target_lang']?.toString(),
      isAsr: j['is_asr'] == true,
      engine: j['engine']?.toString(),
      segments: segs
          .map((s) => Segment(
                start: (s['start'] ?? 0) is int ? s['start'] as int : 0,
                dur: (s['dur'] ?? 0) is int ? s['dur'] as int : 0,
                text: (s['text'] ?? '').toString(),
                tr: (s['tr'] ?? '').toString(),
              ))
          .toList(),
    );
  }

  Future<Map<String, dynamic>> _get(Uri uri) async {
    // YouTube bot-gates server IPs probabilistically — a 5xx often succeeds
    // on retry, so we retry twice with a short backoff before giving up.
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
      }
      try {
        final res = await http.get(uri, headers: {'Accept': 'application/json'}).timeout(
          const Duration(seconds: 75),
        );
        if (res.statusCode >= 500) {
          lastError = ApiException(
              'server_error', 'یوتیوب درخواست را محدود کرده؛ دوباره تلاش کن.');
          continue;
        }
        final j = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        if (j.containsKey('error')) {
          final e = j['error'] as Map<String, dynamic>;
          final code = (e['code'] ?? '').toString();
          // server-side transient failures are worth one more round
          if (code == 'transcript_fetch_failed' && attempt < 2) {
            lastError = ApiException(code, friendlyError(code));
            continue;
          }
          throw ApiException(code, friendlyError(code));
        }
        return j;
      } on ApiException {
        rethrow;
      } catch (_) {
        lastError = ApiException('network', 'اتصال به سرور برقرار نشد. اینترنت را بررسی کن.');
      }
    }
    throw lastError ?? ApiException('network', 'اتصال برقرار نشد.');
  }
}

/// Categorized error keys — same taxonomy as the original app.
String friendlyError(String code) {
  switch (code) {
    case 'server_error':
      return 'یوتیوب درخواست را محدود کرده؛ چند لحظه بعد دوباره تلاش کن.';
    case 'video_not_found':
      return 'ویدئو پیدا نشد یا حذف شده است.';
    case 'video_is_live':
      return 'این ویدئو پخش زنده است؛ بعد از پایان پخش امتحان کن.';
    case 'video_unavailable':
      return 'این ویدئو در دسترس نیست.';
    case 'age_restricted':
      return 'ویدئوی محدود سنی است و صدايش قابل دسترسی نیست.';
    case 'copyright_blocked':
      return 'این ویدئو دارای محتوای دارای حق نشر است و قابل تبدیل به متن نیست.';
    case 'no_speech':
      return 'زیرنویسی برای این ویدئو موجود نیست (فاقد گفتار).';
    case 'transcript_pick_required':
      return 'چند زبان زیرنویس وجود دارد؛ یک زبان را انتخاب کن.';
    case 'invalid_video_url':
      return 'لینک واردشده یک ویدئوی معتبر یوتیوب نیست.';
    case 'translation_failed':
      return 'ترجمه ناموفق بود؛ کمی بعد دوباره تلاش کن.';
    case 'transcript_fetch_failed':
      return 'دریافت زیرنویس ناموفق بود؛ چند لحظه بعد دوباره تلاش کن.';
    case 'playback_failed':
      return 'پخش این ویدئو ممکن نشد؛ چند لحظه بعد دوباره تلاش کن.';
    case 'summarize_failed':
      return 'ساخت خلاصه ناموفق بود؛ کمی بعد دوباره تلاش کن.';
    default:
      return 'خطای غیرمنتظره ($code). دوباره تلاش کن.';
  }
}

/// Local URL parser (same patterns as the original's url_submission screen)
String? extractVideoId(String input) {
  final s = input.trim();
  if (RegExp(r'^[\w-]{11}$').hasMatch(s)) return s;
  final patterns = [
    RegExp(r'youtube\.com/watch\?[^#]*?v=([\w-]{11})'),
    RegExp(r'youtu\.be/([\w-]{11})'),
    RegExp(r'youtube\.com/shorts/([\w-]{11})'),
    RegExp(r'youtube\.com/embed/([\w-]{11})'),
    RegExp(r'youtube\.com/live/([\w-]{11})'),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(s);
    if (m != null) return m.group(1);
  }
  return null;
}

/// Full pipeline (client-side transcript + server-side translation), with a
/// device cache and a Worker-side youtube_asr fallback — result identical to
/// the original app's flow.
Future<TranscriptResult> fetchTranscriptWithTranslation({
  required String videoId,
  required String target,
  bool useCache = true,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final cacheKey = 'tr:$videoId:$target';

  if (useCache) {
    final cached = prefs.getString(cacheKey);
    if (cached != null) {
      try {
        return TranscriptResult.fromJson(Map<String, dynamic>.from(jsonDecode(cached)));
      } catch (_) {/* corrupted cache → refetch */}
    }
  }

  final api = Api();

  // 1) device-side transcript fetch (residential IP)
  List<Segment> segments;
  String title = '';
  String author = '';
  String sourceLang = '';
  bool isAsr = false;
  try {
    final yt = await YouTubeClient().fetchTranscript(videoId);
    title = yt.title;
    author = yt.author;
    sourceLang = yt.sourceLang;
    isAsr = yt.isAsr;
    final tr = await api.translateTexts(yt.segments.map((s) => s.text).toList(), target);
    segments = List.generate(
      yt.segments.length,
      (i) => Segment(
        start: yt.segments[i].start,
        dur: yt.segments[i].dur,
        text: yt.segments[i].text,
        tr: i < tr.length ? tr[i] : '',
      ),
    );
  } on YtFetchException {
    // 2) Worker fallback (server-side captions fetch, may work per region/IP)
    final j = await api.youtubeAsrRaw(videoId: videoId, target: target);
    segments = j.segments;
    title = j.title;
    author = j.author;
    sourceLang = j.sourceLang;
    isAsr = j.isAsr;
  }

  final result = TranscriptResult(
    videoId: videoId,
    title: title,
    author: author,
    lengthSeconds: segments.isEmpty ? 0 : ((segments.last.start + segments.last.dur) ~/ 1000),
    sourceLang: sourceLang,
    targetLang: target,
    isAsr: isAsr,
    segments: segments,
  );
  try {
    await prefs.setString(cacheKey, jsonEncode(result.toJson()));
  } catch (_) {}
  return result;
}
