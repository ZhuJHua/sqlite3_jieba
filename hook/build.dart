import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:crypto/crypto.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

/// The asset id the `@Native` annotations in lib/src/bindings.dart resolve to.
const _assetName = 'src/bindings.dart';
const _logPrefix = '[sqlite3_jieba]';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Reading input.config.code throws when buildCodeAssets is false.
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;

    // Changing this re-runs the hook, so a manifest edit is picked up.
    output.dependencies.add(input.packageRoot.resolve('hook/prebuilt.json'));

    if (input.userDefines['build_from_source'] == true) {
      stderr.writeln(
        '$_logPrefix building from source: asked to by a user-define',
      );
    } else {
      final library = await prebuiltLibrary(input, logPrefix: _logPrefix);
      if (library != null) {
        output.assets.code.add(
          CodeAsset(
            package: input.packageName,
            name: _assetName,
            linkMode: DynamicLoadingBundled(),
            file: library,
          ),
        );
        return;
      }
    }

    // hooks run with an environment allowlist, so *_DEPLOYMENT_TARGET never
    // reaches them; without it rustc links against iOS 10.0 and fails on
    // ___chkstk_darwin with recent Xcode SDKs.
    final env = switch (code.targetOS) {
      OS.iOS => {'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}.0'},
      OS.macOS => {'MACOSX_DEPLOYMENT_TARGET': '${code.macOS.targetVersion}.0'},
      _ => const <String, String>{},
    };
    await RustBuilder(
      assetName: _assetName,
      cratePath: 'rust',
      extraCargoEnvironmentVariables: env,
    ).run(input: input, output: output);
    // native_toolchain_rust does not track these, so the hook would otherwise
    // reuse a stale library.
    output.dependencies.addAll([
      input.packageRoot.resolve('rust/Cargo.toml'),
      input.packageRoot.resolve('rust/Cargo.lock'),
      input.packageRoot.resolve('rust/build.rs'),
      input.packageRoot.resolve('rust/c/shim.c'),
    ]);
  });
}

/// The library file the build hook bundles, downloaded from this package's
/// GitHub release instead of compiled locally.
///
/// Returns `null` whenever a verified artifact cannot be produced — there is no
/// manifest entry for the target, the manifest is for a different version, the
/// consumer targets an OS older than the artifact was built for, or the
/// download failed or did not match its recorded hash. The caller then falls
/// back to building from source, so this is an optimisation, never a
/// requirement.
Future<Uri?> prebuiltLibrary(
  BuildInput input, {
  required String logPrefix,
}) async {
  void skip(String reason) =>
      stderr.writeln('$logPrefix building from source: $reason');

  final manifestFile = File.fromUri(
    input.packageRoot.resolve('hook/prebuilt.json'),
  );
  if (!manifestFile.existsSync()) {
    skip('hook/prebuilt.json is missing');
    return null;
  }

  final Map<String, Object?> manifest;
  try {
    manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
  } on FormatException catch (e) {
    skip('hook/prebuilt.json is not valid JSON ($e)');
    return null;
  }

  // A manifest left over from an earlier version would hand out the wrong
  // binary, so it has to name the version being built.
  final packageVersion = _packageVersion(input);
  if (manifest['version'] != packageVersion) {
    skip(
      'no release artifacts recorded for $packageVersion '
      '(manifest has ${manifest['version']})',
    );
    return null;
  }

  final code = input.config.code;
  final key = _targetKey(code);
  final artifact = (manifest['artifacts'] as Map<String, Object?>?)?[key];
  if (artifact is! Map<String, Object?>) {
    skip('no artifact for $key');
    return null;
  }

  final unmet = _unmetRequirement(code, artifact);
  if (unmet != null) {
    skip('the $key artifact $unmet');
    return null;
  }

  final file = artifact['file'] as String;
  final sha256Hex = artifact['sha256'] as String;
  final url = Uri.parse(
    (manifest['url_template'] as String)
        .replaceAll('{version}', packageVersion)
        .replaceAll('{file}', file),
  );

  // Content-addressed, so a cache entry is either the right bytes or absent,
  // and parallel target builds can share it.
  final cached = File.fromUri(
    input.outputDirectoryShared.resolve('prebuilt/$sha256Hex-$file'),
  );
  if (cached.existsSync() && await _sha256(cached) == sha256Hex) {
    stderr.writeln('$logPrefix using the cached $key release artifact');
    return cached.uri;
  }

  try {
    await _download(url, cached, sha256Hex);
  } on Object catch (e) {
    skip('could not fetch $url ($e)');
    return null;
  }
  stderr.writeln('$logPrefix downloaded the $key release artifact');
  return cached.uri;
}

/// `<os>_<arch>`, with the two iOS SDKs kept apart because a simulator slice
/// and a device slice are not interchangeable.
String _targetKey(CodeConfig code) {
  final os = code.targetOS;
  final arch = code.targetArchitecture.name;
  if (os == OS.iOS && code.iOS.targetSdk == IOSSdk.iPhoneSimulator) {
    return 'ios_sim_$arch';
  }
  return '${os.name}_$arch';
}

/// A prebuilt binary carries a fixed minimum OS version. Linking it into an app
/// that targets something older is exactly the case to build from source for.
String? _unmetRequirement(CodeConfig code, Map<String, Object?> artifact) {
  int? required(String key) => artifact[key] as int?;
  switch (code.targetOS) {
    case OS.iOS:
      final min = required('min_os_version');
      if (min != null && code.iOS.targetVersion < min) {
        return 'needs iOS $min, the app targets ${code.iOS.targetVersion}';
      }
    case OS.macOS:
      final min = required('min_os_version');
      if (min != null && code.macOS.targetVersion < min) {
        return 'needs macOS $min, the app targets ${code.macOS.targetVersion}';
      }
    case OS.android:
      final min = required('min_android_api');
      if (min != null && code.android.targetNdkApi < min) {
        return 'needs API $min, the app targets ${code.android.targetNdkApi}';
      }
    default:
      break;
  }
  return null;
}

String _packageVersion(BuildInput input) {
  final pubspec = File.fromUri(
    input.packageRoot.resolve('pubspec.yaml'),
  ).readAsStringSync();
  return RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec)?.group(1) ??
      '';
}

Future<String> _sha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _download(Uri url, File target, String sha256Hex) async {
  final client = HttpClient();
  // Written under a unique name and renamed, so a half-written or mismatched
  // download can never be picked up as a cache hit.
  final temp = File(
    '${target.path}.${pid}_${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    var response = await (await client.getUrl(url)).close();
    var redirects = 0;
    while (response.isRedirect && redirects++ < 5) {
      final location = response.headers.value(HttpHeaders.locationHeader)!;
      await response.drain<void>();
      response = await (await client.getUrl(url.resolve(location))).close();
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    temp.parent.createSync(recursive: true);
    await response.pipe(temp.openWrite());

    final actual = await _sha256(temp);
    if (actual != sha256Hex) {
      throw StateError('sha256 mismatch: expected $sha256Hex, got $actual');
    }
    temp.renameSync(target.path);
  } finally {
    client.close(force: true);
    if (temp.existsSync()) temp.deleteSync();
  }
}
