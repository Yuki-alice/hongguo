import 'dart:ui';

import 'package:duanju_app/data/video_enhancement/video_enhancement_policy.dart';
import 'package:duanju_app/domain/video_enhancement_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

VideoParams safeParams({
  String format = 'yuv420p',
  String primaries = 'bt.709',
  String gamma = 'bt.1886',
}) => VideoParams(
  pixelformat: format,
  primaries: primaries,
  gamma: gamma,
  w: 1280,
  h: 720,
  dw: 1280,
  dh: 720,
  par: 1,
  rotate: 0,
);

void main() {
  test('动漫标签覆盖分类与标签', () {
    expect(videoHasAnimationTags('漫剧', const []), isTrue);
    expect(videoHasAnimationTags('真人剧', const ['anime']), isTrue);
    expect(videoHasAnimationTags('真人剧', const ['都市']), isFalse);
  });

  test('色彩与位深不安全时保持原画', () {
    expect(videoHasSafeEnhancementColor(safeParams()), isTrue);
    expect(videoHasSafeEnhancementColor(safeParams(format: 'p010le')), isFalse);
    expect(
      videoHasSafeEnhancementColor(safeParams(gamma: 'smpte2084')),
      isFalse,
    );
  });

  test('关闭增强直接返回原画', () {
    final decision = chooseVideoEnhancement(
      preferences: const VideoEnhancementPreferences(),
      parameters: safeParams(),
      viewport: const Size(1920, 1080),
      ready: true,
      android: false,
      television: false,
      gpu: true,
      luma: true,
      hardware: false,
      animation: false,
      power: const VideoEnhancementPower(),
      rate: 1,
      costLimit: 4,
      rejected: const {},
    );

    expect(decision.backend, VideoEnhancementBackend.original);
    expect(decision.reason, '画质增强已关闭');
  });

  test('不安全色彩即使开启增强也保持原画', () {
    final decision = chooseVideoEnhancement(
      preferences: const VideoEnhancementPreferences(
        mode: VideoEnhancementMode.quality,
      ),
      parameters: safeParams(primaries: 'bt2020'),
      viewport: const Size(1920, 1080),
      ready: true,
      android: false,
      television: false,
      gpu: true,
      luma: true,
      hardware: false,
      animation: false,
      power: const VideoEnhancementPower(),
      rate: 1,
      costLimit: 4,
      rejected: const {},
    );

    expect(decision.backend, VideoEnhancementBackend.original);
    expect(decision.reason, '当前色彩或位深保持原画');
  });
}
