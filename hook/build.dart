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
/// 报 `linking with 'cc' failed`。这里按目标三元组补上 iOS SDK 的 clang、
/// sysroot 与部署目标；其余平台返回空表，行为不变。
///
/// 部署目标必须与 Podfile 一致：rustc 内置的 iOS 最低版本是 10.0，而依赖
/// 里的 C 代码按当前 SDK 编译，会引用 `__chkstk_darwin` 这类 iOS 13+ 才
/// 可见的 libSystem 符号，按 10.0 链接就是 `symbol(s) not found`。
Future<Map<String, String>> appleLinkerEnvironment() async {
  if (!Platform.isMacOS) return const {};
  final deploymentTarget = _iosDeploymentTarget();
  const targets = {
    'aarch64-apple-ios': ('iphoneos', false),
    'aarch64-apple-ios-sim': ('iphonesimulator', true),
    'x86_64-apple-ios': ('iphonesimulator', true),
  };
  final environment = <String, String>{
    if (deploymentTarget != null)
      'IPHONEOS_DEPLOYMENT_TARGET': deploymentTarget,
  };
  for (final MapEntry(key: triple, value: (sdk, simulator))
      in targets.entries) {
    final clang = await _xcrun(['--sdk', sdk, '--find', 'clang']);
    final sysroot = await _xcrun(['--sdk', sdk, '--show-sdk-path']);
    if (clang == null || sysroot == null) continue;
    final key = triple.replaceAll('-', '_').toUpperCase();
    final versionFlag = simulator
        ? '-mios-simulator-version-min'
        : '-miphoneos-version-min';
    environment['CARGO_TARGET_${key}_LINKER'] = clang;
    environment['CARGO_TARGET_${key}_RUSTFLAGS'] = [
      '-Clink-arg=-isysroot',
      '-Clink-arg=$sysroot',
      if (deploymentTarget != null) ...[
        '-Clink-arg=$versionFlag=$deploymentTarget',
      ],
    ].join(' ');
  }
  return environment;
}

/// 部署目标：优先用 Xcode 传下来的环境变量，否则读 Podfile，最后兜底。
String? _iosDeploymentTarget() {
  final fromEnvironment = Platform.environment['IPHONEOS_DEPLOYMENT_TARGET'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    return fromEnvironment;
  }
  final podfile = File('ios/Podfile');
  if (podfile.existsSync()) {
    final match = RegExp(
      r"platform :ios,\s*'([^']+)'",
    ).firstMatch(podfile.readAsStringSync());
    if (match != null) return match.group(1);
  }
  return null;
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
