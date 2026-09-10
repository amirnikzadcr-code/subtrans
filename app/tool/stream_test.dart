// Runtime sanity test for the device-side extraction logic (pure Dart part).
// Run: cd app && dart run tool/stream_test.dart
import '../lib/youtube_client.dart';

Future<void> main() async {
  final ids = {
    'dQw4w9WgXcQ': 'embeddable classic',
    'kXYiU_JCYtU': 'historically embed-restricted music video',
    '9bZkp7q19f0': 'music video',
  };
  for (final e in ids.entries) {
    try {
      final s = await YouTubeClient().fetchStreamInfo(e.key);
      print('OK  ${e.key} (${e.value}) → ${s.isHls ? 'HLS' : 'muxed'} ${s.label}');
      print('    url: ${s.url.substring(0, 90)}...');
    } on YtFetchException catch (ex) {
      print('ERR ${e.key} (${e.value}) → ${ex.code}');
    } catch (ex) {
      print('ERR ${e.key} → $ex');
    }
  }

  try {
    final r = await searchYouTube('lofi study');
    print('SEARCH → ${r.length} results, first: "${r.first.title}" (${r.first.channel})');
  } catch (ex) {
    print('SEARCH ERR → $ex');
  }
}
