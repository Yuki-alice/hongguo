import 'dart:io';

import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust/bridge',
      extraCargoEnvironmentVariables: await appleLinkerEnvironment(),
    ).run(input: input, output: output);
  });
}

/// Apple 移动端目标需要显式注入 iOS SDK 的 clang。
///
/// 钩子底层的 native_toolchain_rust 只为 Android 拼交叉编译环境，iOS 没有
/// 对应分支：rustc 会退回宿主 `cc`（macOS 自带 clang），链接 device 架构时
/// 报 `linking with 'cc' failed`。这里按目标三元组补上 iOS SDK 的 clang
/// 与 sysroot；其余平台返回空表，行为不变。
Future<Map<String, String>> appleLinkerEnvironment() async {
  if (!Platform.isMacOS) return const {};
  const targets = {
    'aarch64-apple-ios': 'iphoneos',
    'aarch64-apple-ios-sim': 'iphonesimulator',
    'x86_64-apple-ios': 'iphonesimulator',
  };
  final environment = <String, String>{};
  for (final MapEntry(key: triple, value: sdk) in targets.entries) {
    final clang = await _xcrun(['--sdk', sdk, '--find', 'clang']);
    final sysroot = await _xcrun(['--sdk', sdk, '--show-sdk-path']);
    if (clang == null || sysroot == null) continue;
    final key = triple.replaceAll('-', '_').toUpperCase();
    environment['CARGO_TARGET_${key}_LINKER'] = clang;
    environment['CARGO_TARGET_${key}_RUSTFLAGS'] =
        '-Clink-arg=-isysroot -Clink-arg=$sysroot';
  }
  return environment;
}

Future<String?> _xcrun(List<String> arguments) async {
  try {
    final result = await Process.run('xcrun', arguments);
    if (result.exitCode != 0) return null;
    final output = result.stdout.toString().trim();
    return output.isEmpty ? null : output;
  } on ProcessException {
    return null;
  }
}
