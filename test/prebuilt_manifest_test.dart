@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The target keys the release workflow, the manifest generator and the build
/// hook each name independently. A silent drift between them would disable
/// prebuilt artifacts for a platform and nobody would notice until someone
/// without rustup tried to build.
void main() {
  final workflowKeys = RegExp(r'\bkey:\s*([a-z0-9_]+)')
      .allMatches(File('.github/workflows/release.yml').readAsStringSync())
      .map((m) => m.group(1)!)
      .toSet();

  final generator = File('tool/update_prebuilt.dart').readAsStringSync();
  final generatorKeys = RegExp(r"^\s*'([a-z0-9_]+)',", multiLine: true)
      .allMatches(
        generator.substring(
          generator.indexOf('const _keys = ['),
          generator.indexOf('];', generator.indexOf('const _keys = [')),
        ),
      )
      .map((m) => m.group(1)!)
      .toSet();

  test(
    'the release workflow builds exactly the keys the generator expects',
    () {
      expect(workflowKeys, isNotEmpty);
      expect(generatorKeys, workflowKeys);
    },
  );

  test('every rust-toolchain target has a release key', () {
    final targets = RegExp(r'^\s*"([a-z0-9_]+-[a-z0-9-]+)",', multiLine: true)
        .allMatches(File('rust/rust-toolchain.toml').readAsStringSync())
        .map((m) => m.group(1)!)
        .toSet();
    expect(
      targets,
      hasLength(workflowKeys.length),
      reason: 'rust-toolchain.toml and release.yml cover different targets',
    );
  });

  test('the shipped manifest is well formed', () {
    final manifest =
        jsonDecode(File('hook/prebuilt.json').readAsStringSync())
            as Map<String, Object?>;
    expect(manifest['url_template'], contains('{version}'));
    expect(manifest['url_template'], contains('{file}'));

    final version = manifest['version'];
    final artifacts = manifest['artifacts'] as Map<String, Object?>;
    if (version == null) {
      expect(
        artifacts,
        isEmpty,
        reason: 'artifacts without a version would never be used',
      );
      return;
    }
    expect(
      version,
      RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1),
      reason: 'run tool/update_prebuilt.dart, or the hook builds from source',
    );
    expect(artifacts.keys.toSet(), generatorKeys);
    for (final entry in artifacts.entries) {
      final artifact = entry.value as Map<String, Object?>;
      expect(artifact['file'], isA<String>(), reason: entry.key);
      expect(
        artifact['sha256'],
        matches(RegExp(r'^[0-9a-f]{64}$')),
        reason: entry.key,
      );
    }
  });
}
