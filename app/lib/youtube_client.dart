import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client-side YouTube transcript fetch — runs from the device (residential
/// IP), exactly like YouTube's own "Show transcript" panel:
///   1. POST /youtubei/v1/next          → minted getTranscriptEndpoint.params
///   2. POST /youtubei/v1/get_transcript → transcript segments
/// (Server-side fetching from datacenter IPs is bot-gated by YouTube —
///  the Cloudflare Worker keeps doing all translation instead.)
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
  final List<YtSegment> segments;
  YtVideo({required this.videoId, required this.title, required this.author, required this.segments});
}

class YouTubeClient {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  Future<YtVideo> fetchTranscript(String videoId) async {
    // metadata via oEmbed (public, reliable)
    var title = '';
    var author = '';
    try {
      final meta = await http.get(
        Uri.parse('https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$videoId&format=json'),
        headers: {'User-Agent': _ua},
      ).timeout(const Duration(seconds: 15));
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

    // 1) /next → minted params
    final nextRes = await http.post(
      Uri.parse('https://www.youtube.com/youtubei/v1/next?prettyPrint=false'),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': _ua,
        'X-Goog-Api-Format-Version': '2',
      },
      body: jsonEncode({
        'context': {
          'client': {'clientName': 'WEB', 'clientVersion': '2.20240401.00.00', 'hl': 'en', 'gl': 'US'},
        },
        'videoId': videoId,
      }),
    ).timeout(const Duration(seconds: 20));

    if (nextRes.statusCode != 200) {
      throw YtFetchException('transcript_fetch_failed');
    }
    final nextJson = jsonDecode(nextRes.body);
    String? params;
    String? visitorData;
    void walk(dynamic n) {
      if (n is Map) {
        final ep = n['getTranscriptEndpoint'];
        if (ep is Map && ep['params'] is String) params = ep['params'] as String;
        final rc = n['responseContext'];
        if (rc is Map && rc['visitorData'] is String && visitorData == null) {
          visitorData = rc['visitorData'] as String;
        }
        n.values.forEach(walk);
      } else if (n is List) {
        for (final x in n) {
          walk(x);
        }
      }
    }

    walk(nextJson);
    if (params == null) {
      throw YtFetchException('no_speech');
    }

    // 2) get_transcript with minted params
    final clientCtx = <String, dynamic>{
      'clientName': 'WEB',
      'clientVersion': '2.20240401.00.00',
      'hl': 'en',
      'gl': 'US',
    };
    if (visitorData != null) clientCtx['visitorData'] = visitorData;

    final trRes = await http.post(
      Uri.parse('https://www.youtube.com/youtubei/v1/get_transcript?prettyPrint=false'),
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': _ua,
        'X-Goog-Api-Format-Version': '2',
      },
      body: jsonEncode({
        'context': {'client': clientCtx},
        'params': params,
      }),
    ).timeout(const Duration(seconds: 25));

    if (trRes.statusCode != 200) {
      throw YtFetchException('transcript_fetch_failed');
    }

    final segs = <YtSegment>[];
    void walkSegs(dynamic n) {
      if (n is Map) {
        final t = n['transcriptSegmentRenderer'];
        if (t is Map) {
          final runs = (t['snippet']?['runs'] as List?) ?? const [];
          final text = runs.map((r) => (r['text'] ?? '').toString()).join().replaceAll(RegExp(r'\s+'), ' ').trim();
          if (text.isNotEmpty) {
            final start = int.tryParse((t['startMs'] ?? '0').toString()) ?? 0;
            final end = int.tryParse((t['endMs'] ?? '0').toString()) ?? start + 3000;
            segs.add(YtSegment(start: start, dur: end - start, text: text));
          }
        }
        for (final v in n.values) {
          walkSegs(v);
        }
      } else if (n is List) {
        for (final x in n) {
          walkSegs(x);
        }
      }
    }

    walkSegs(jsonDecode(trRes.body));
    if (segs.isEmpty) {
      throw YtFetchException('transcript_fetch_failed');
    }
    return YtVideo(videoId: videoId, title: title, author: author, segments: segs);
  }
}
