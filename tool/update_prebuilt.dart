// Regenerates hook/prebuilt.json from a published GitHub release, so the build
// hook can download artifacts instead of compiling from source.
//
//   dart run tool/update_prebuilt.dart [version]
//
// Run it after the release workflow has finished and before `dart pub publish`;
// see RELEASING.md.
import 'dart:convert';
import 'dart:io';

/// Must match the deployment targets the release workflow builds with.
const _iosMinVersion = 12;
const _macosMinVersion = 10;
const _androidMinApi = 21;

/// Matches _targetKey() in hook/prebuilt.dart.
const _keys = [
  'android_arm',
  'android_arm64',
  'android_x64',
  'ios_arm64',
  'ios_sim_arm64',
  'ios_sim_x64',
  'linux_arm64',
  'linux_x64',
  'macos_arm64',
  'macos_x64',
  'windows_arm64',
  'windows_x64',
];

Future<void> main(List<String> args) async {
  final version = args.isNotEmpty ? args.single : _pubspecVersion();
  final manifestFile = File('hook/prebuilt.json');
  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
  final template = manifest['url_template'] as String;

  final sums = await _fetch(
    Uri.parse(
      template
          .replaceAll('{version}', version)
          .replaceAll('{file}', 'SHA256SUMS'),
    ),
  );

  final artifacts = <String, Object?>{};
  for (final line in const LineSplitter().convert(sums)) {
    if (line.trim().isEmpty) continue;
    final parts = line.trim().split(RegExp(r'\s+'));
    final sha = parts.first;
    final file = parts.last.replaceFirst(RegExp(r'^\*'), '');
    final key = _keyOf(file);
    if (key == null) {
      stderr.writeln('warning: ignoring unrecognised artifact $file');
      continue;
    }
    artifacts[key] = {
      'file': file,
      'sha256': sha,
      if (key.startsWith('ios')) 'min_os_version': _iosMinVersion,
      if (key.startsWith('macos')) 'min_os_version': _macosMinVersion,
      if (key.startsWith('android')) 'min_android_api': _androidMinApi,
    };
  }

  final missing = _keys.where((k) => !artifacts.containsKey(k)).toList();
  if (missing.isNotEmpty) {
    stderr.writeln('error: release v$version is missing ${missing.join(', ')}');
    exit(1);
  }

  manifest['version'] = version;
  manifest['artifacts'] = {for (final key in _keys) key: artifacts[key]};
  manifestFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
  );
  stdout.writeln(
    'hook/prebuilt.json now points at v$version '
    '(${artifacts.length} artifacts)',
  );
}

String? _keyOf(String file) {
  final match = RegExp(
    r'^sqlite3_jieba-(.+)\.(so|dylib|dll)$',
  ).firstMatch(file);
  final key = match?.group(1);
  return _keys.contains(key) ? key : null;
}

String _pubspecVersion() => RegExp(
  r'^version:\s*(\S+)',
  multiLine: true,
).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1)!;

Future<String> _fetch(Uri url) async {
  final client = HttpClient();
  try {
    var response = await (await client.getUrl(url)).close();
    var redirects = 0;
    while (response.isRedirect && redirects++ < 5) {
      final location = response.headers.value(HttpHeaders.locationHeader)!;
      await response.drain<void>();
      response = await (await client.getUrl(url.resolve(location))).close();
    }
    if (response.statusCode != HttpStatus.ok) {
      stderr.writeln('error: GET $url returned ${response.statusCode}');
      exit(1);
    }
    return await response.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}
