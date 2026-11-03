import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/update_service.dart';

void main() {
  group('version compare', () {
    test('newer, older, and equal releases', () {
      expect(isUpdateAvailable('v0.5.1', '0.5.0'), isTrue);
      expect(isUpdateAvailable('v0.5.0', '0.5.0'), isFalse);
      expect(isUpdateAvailable('v0.4.9', '0.5.0'), isFalse);
      expect(isUpdateAvailable('1.0.0', '0.9.9'), isTrue);
      expect(isUpdateAvailable('v0.5', '0.5.0'), isFalse);
      expect(isUpdateAvailable('0.5.0+9', '0.5.0'), isFalse);
      expect(isUpdateAvailable('garbage', '0.5.0'), isFalse);
    });
  });

  group('release answer reading', () {
    test('finds the installer asset and the tag', () {
      final release = <String, Object?>{
        'tag_name': 'v0.6.0',
        'assets': <Object?>[
          <String, Object?>{
            'name': 'TermiNote-Portable-x64.zip',
            'browser_download_url': 'https://example.test/portable.zip',
          },
          <String, Object?>{
            'name': 'TermiNote-Setup-x64.exe',
            'browser_download_url': 'https://example.test/setup.exe',
          },
        ],
      };
      expect(releaseTag(release), 'v0.6.0');
      expect(setupDownloadUrl(release), 'https://example.test/setup.exe');
    });

    test('no installer asset means no update path', () {
      expect(setupDownloadUrl(<String, Object?>{'assets': <Object?>[]}), null);
      expect(setupDownloadUrl(null), null);
      expect(releaseTag(null), '');
    });
  });
}
