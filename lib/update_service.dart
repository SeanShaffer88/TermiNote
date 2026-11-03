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

import 'version.dart';

/// The release feed this program updates from.
const String kLatestReleaseUrl =
    'https://api.github.com/repos/SeanShaffer88/TermiNote/releases/latest';

/// The installer asset each release carries (the portable zip is for
/// hand installs; the updater needs the installer).
const String kSetupAssetName = 'TermiNote-Setup-x64.exe';

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
String? setupDownloadUrl(Object? releaseJson) {
  if (releaseJson is! Map) return null;
  final assets = releaseJson['assets'];
  if (assets is! List) return null;
  for (final asset in assets) {
    if (asset is Map && asset['name'] == kSetupAssetName) {
      final url = asset['browser_download_url'];
      if (url is String && url.isNotEmpty) return url;
    }
  }
  return null;
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
    client.userAgent = 'TermiNote/$kAppVersion';
    final request = await client.getUrl(Uri.parse(kLatestReleaseUrl));
    final response = await request.close();
    if (response.statusCode != 200) return false;
    final body = await response.transform(utf8.decoder).join();
    final release = jsonDecode(body);
    if (!isUpdateAvailable(releaseTag(release), kAppVersion)) return false;
    final url = setupDownloadUrl(release);
    if (url == null) return false;

    final updatesDir = io.Directory(
      '$dataDir${io.Platform.pathSeparator}updates',
    );
    await updatesDir.create(recursive: true);
    final setupFile = io.File(
      '${updatesDir.path}${io.Platform.pathSeparator}$kSetupAssetName',
    );
    final download = await client.getUrl(Uri.parse(url));
    download.followRedirects = true;
    download.maxRedirects = 5;
    final downloadResponse = await download.close();
    if (downloadResponse.statusCode != 200) return false;
    await downloadResponse.pipe(setupFile.openWrite());

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
