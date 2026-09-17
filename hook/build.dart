import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

import 'prebuilt.dart';

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
