import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Reading input.config.code throws when buildCodeAssets is false.
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    // hooks run with an environment allowlist, so *_DEPLOYMENT_TARGET never
    // reaches them; without it rustc links against iOS 10.0 and fails on
    // ___chkstk_darwin with recent Xcode SDKs.
    final env = switch (code.targetOS) {
      OS.iOS => {'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}.0'},
      OS.macOS => {'MACOSX_DEPLOYMENT_TARGET': '${code.macOS.targetVersion}.0'},
      _ => const <String, String>{},
    };
    await RustBuilder(
      assetName: 'src/bindings.dart',
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
