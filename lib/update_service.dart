/// Silent auto-update: at launch, ask GitHub for the newest release;
/// when it is newer than this build, download its installer, run it
/// silently, and step aside so it can replace the program and reopen
/// it (the installer's side of that handshake lives in
/// installer/TermiNote.iss). The Settings switch (AppState.autoUpdate)
/// turns the whole thing off.
///
/// Everything here fails quietly: no network, a moved release page, or
/// a failed download simply means the program opens as it always did.
/// An update must never block, nag, or break a launch.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';

import 'version.dart';

/// The release feed this program updates from.
const String kLatestReleaseUrl =
    'https://api.github.com/repos/SeanShaffer88/TermiNote/releases/latest';

/// The installer asset each release carries (the portable zip is for
/// hand installs; the updater needs the installer).
const String kSetupAssetName = 'TermiNote-Setup-x64.exe';
const int kMaxInstallerBytes = 50 * 1024 * 1024;

const Duration _requestTimeout = Duration(seconds: 20);
const Duration _downloadIdleTimeout = Duration(minutes: 2);

/// Splits a version like "v0.5.0" or "0.5.0+8" into its numbers.
/// Anything unparseable counts as 0, so odd input compares low rather
/// than crashing the check.
List<int> versionParts(String version) {
  var text = version.trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  text = text.split('+').first.split('-').first;
  return text.split('.').map((part) => int.tryParse(part) ?? 0).toList();
}

/// True when [latest] is a newer version than [current].
bool isUpdateAvailable(String latest, String current) {
  final a = versionParts(latest);
  final b = versionParts(current);
  final length = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Finds the installer download address in a decoded GitHub release
/// (the JSON of the "latest release" answer). Null when the release
/// has no installer asset — nothing to update with.
Map? _setupAsset(Object? releaseJson) {
  if (releaseJson is! Map) return null;
  final assets = releaseJson['assets'];
  if (assets is! List) return null;
  for (final asset in assets) {
    if (asset is Map && asset['name'] == kSetupAssetName) {
      return asset;
    }
  }
  return null;
}

bool _isTrustedSetupUri(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.host.toLowerCase() != 'github.com' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      uri.hasFragment) {
    return false;
  }
  final segments = uri.pathSegments;
  return segments.length == 6 &&
      segments[0] == 'SeanShaffer88' &&
      segments[1] == 'TermiNote' &&
      segments[2] == 'releases' &&
      segments[3] == 'download' &&
      segments[4].isNotEmpty &&
      segments[5] == kSetupAssetName;
}

bool _isTrustedDownloadHop(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      uri.hasFragment) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'github.com') return _isTrustedSetupUri(uri);
  return host == 'release-assets.githubusercontent.com' ||
      host == 'objects.githubusercontent.com' ||
      host.endsWith('.githubusercontent.com');
}

/// The exact installer asset URL from TermiNote's HTTPS GitHub release.
/// Other hosts, schemes, repositories, and asset paths are refused.
String? setupDownloadUrl(Object? releaseJson) {
  final raw = _setupAsset(releaseJson)?['browser_download_url'];
  if (raw is! String) return null;
  final uri = Uri.tryParse(raw);
  return uri != null && _isTrustedSetupUri(uri) ? uri.toString() : null;
}

/// GitHub's SHA-256 digest for the exact installer asset, or null when
/// the release does not provide a well-formed digest.
String? setupDownloadSha256(Object? releaseJson) {
  final raw = _setupAsset(releaseJson)?['digest'];
  if (raw is! String) return null;
  final match = RegExp(r'^sha256:([a-fA-F0-9]{64})$').firstMatch(raw);
  return match?.group(1)?.toLowerCase();
}

Future<io.HttpClientResponse?> _openInstallerResponse(
  io.HttpClient client,
  Uri initialUri,
) async {
  var uri = initialUri;
  for (var redirects = 0; redirects <= 5; redirects++) {
    if (!_isTrustedDownloadHop(uri)) return null;
    final request = await client.getUrl(uri).timeout(_requestTimeout);
    request.followRedirects = false;
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = response.headers.value(io.HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null || redirects == 5) return null;
      uri = uri.resolve(location);
      continue;
    }
    if (response.statusCode != io.HttpStatus.ok) {
      await response.drain<void>();
      return null;
    }
    return response;
  }
  return null;
}

Future<bool> _downloadAndVerifyInstaller({
  required io.HttpClient client,
  required String url,
  required String expectedSha256,
  required io.File destination,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !_isTrustedSetupUri(uri)) return false;
  final response = await _openInstallerResponse(client, uri);
  if (response == null) return false;
  if (response.contentLength > kMaxInstallerBytes) {
    await response.drain<void>();
    return false;
  }

  final partial = io.File('${destination.path}.part');
  var ready = false;
  try {
    var length = 0;
    final sink = partial.openWrite();
    try {
      await for (final chunk in response.timeout(_downloadIdleTimeout)) {
        length += chunk.length;
        if (length > kMaxInstallerBytes) {
          throw const FormatException('Installer exceeds size limit');
        }
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (length == 0) return false;

    final actual = await sha256.bind(partial.openRead()).first;
    if (actual.toString().toLowerCase() != expectedSha256.toLowerCase()) {
      return false;
    }

    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
    ready = true;
    return true;
  } finally {
    if (!ready) {
      try {
        if (await partial.exists()) await partial.delete();
      } on io.FileSystemException {
        // A leftover partial file is never launched; the next attempt
        // truncates it before writing.
      }
    }
  }
}

/// The tag (version) a decoded GitHub release is for; '' when absent.
String releaseTag(Object? releaseJson) =>
    releaseJson is Map ? releaseJson['tag_name']?.toString() ?? '' : '';

/// Runs the launch update check. When a newer release is installed,
/// this never returns: [prepareExit] flushes the app's work, the
/// installer starts, and the process exits so the installer can swap
/// the files. Returns whether an update was found and started.
Future<bool> maybeRunAutoUpdate({
  required bool enabled,
  required String dataDir,
  required Future<void> Function() prepareExit,
  void Function(int code)? exitProcess,
  Future<void> Function(String path)? startInstaller,
}) async {
  if (!enabled || !io.Platform.isWindows) return false;
  final exit = exitProcess ?? io.exit;
  final start =
      startInstaller ??
      (path) async {
        await io.Process.start(path, const <String>[
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
        ], mode: io.ProcessStartMode.detached);
      };
  io.HttpClient? client;
  try {
    client = io.HttpClient();
    client.connectionTimeout = _requestTimeout;
    client.userAgent = 'TermiNote/$kAppVersion';
    final request = await client.getUrl(Uri.parse(kLatestReleaseUrl));
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode != io.HttpStatus.ok) {
      await response.drain<void>();
      return false;
    }
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(_downloadIdleTimeout);
    final release = jsonDecode(body);
    if (!isUpdateAvailable(releaseTag(release), kAppVersion)) return false;
    final url = setupDownloadUrl(release);
    final digest = setupDownloadSha256(release);
    if (url == null || digest == null) return false;

    final updatesDir = io.Directory(
      '$dataDir${io.Platform.pathSeparator}updates',
    );
    await updatesDir.create(recursive: true);
    final setupFile = io.File(
      '${updatesDir.path}${io.Platform.pathSeparator}$kSetupAssetName',
    );
    if (!await _downloadAndVerifyInstaller(
      client: client,
      url: url,
      expectedSha256: digest,
      destination: setupFile,
    )) {
      return false;
    }

    // Everything is downloaded: flush the app's work, hand over to
    // the installer, and step aside. The installer waits for this
    // process to be gone, replaces the files, and reopens the app.
    await prepareExit();
    await start(setupFile.path);
    exit(0);
    return true;
  } on Exception {
    return false;
  } finally {
    client?.close(force: true);
  }
}
