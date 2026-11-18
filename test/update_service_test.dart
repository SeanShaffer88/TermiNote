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
        'tag_name': 'v0.7.0',
        'assets': <Object?>[
          <String, Object?>{
            'name': 'TermiNote-Portable-x64.zip',
            'browser_download_url': 'https://example.test/portable.zip',
          },
          <String, Object?>{
            'name': 'TermiNote-Setup-x64.exe',
            'browser_download_url':
                'https://github.com/SeanShaffer88/TermiNote/releases/'
                'download/v0.7.0/TermiNote-Setup-x64.exe',
            'digest': 'sha256:eaaf324da58af0ead976f1632eefc2732619a3d7307ab8dbe8b5b65f37ff1990',
          },
        ],
      };
      expect(releaseTag(release), 'v0.7.0');
      expect(
        setupDownloadUrl(release),
        'https://github.com/SeanShaffer88/TermiNote/releases/'
        'download/v0.7.0/TermiNote-Setup-x64.exe',
      );
      expect(
        setupDownloadSha256(release),
        'eaaf324da58af0ead976f1632eefc2732619a3d7307ab8dbe8b5b65f37ff1990',
      );
    });

    test('no installer asset means no update path', () {
      expect(setupDownloadUrl(<String, Object?>{'assets': <Object?>[]}), null);
      expect(
        setupDownloadSha256(<String, Object?>{'assets': <Object?>[]}),
        null,
      );
      expect(setupDownloadUrl(null), null);
      expect(releaseTag(null), '');
    });

    test('rejects untrusted installer URLs', () {
      for (final url in <String>[
        'http://github.com/SeanShaffer88/TermiNote/releases/download/'
            'v0.7.0/TermiNote-Setup-x64.exe',
        'https://github.com.attacker.test/SeanShaffer88/TermiNote/releases/'
            'download/v0.7.0/TermiNote-Setup-x64.exe',
        'https://example.test/TermiNote-Setup-x64.exe',
        'https://github.com/SeanShaffer88/Other/releases/download/'
            'v0.7.0/TermiNote-Setup-x64.exe',
        'https://github.com/SeanShaffer88/TermiNote/releases/download/'
            'v0.7.0/other.exe',
      ]) {
        expect(
          setupDownloadUrl(<String, Object?>{
            'assets': <Object?>[
              <String, Object?>{
                'name': 'TermiNote-Setup-x64.exe',
                'browser_download_url': url,
              },
            ],
          }),
          isNull,
          reason: url,
        );
      }
    });

    test('rejects missing or malformed installer digests', () {
      for (final digest in <Object?>[
        null,
        'sha1:${'a' * 40}',
        'sha256:too-short',
        'sha256:${'g' * 64}',
      ]) {
        expect(
          setupDownloadSha256(<String, Object?>{
            'assets': <Object?>[
              <String, Object?>{
                'name': 'TermiNote-Setup-x64.exe',
                'digest': digest,
              },
            ],
          }),
          isNull,
        );
      }
    });
  });
}
