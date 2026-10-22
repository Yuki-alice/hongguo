import 'dart:ui';

import 'package:hoshi/data/video_enhancement/video_output_size.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test('优先使用显示尺寸', () {
    final size = videoDisplaySize(
      const VideoParams(dw: 1920, dh: 1080, w: 640, h: 360),
    );

    expect(size, const Size(1920, 1080));
  });

  test('没有显示尺寸时回退源尺寸', () {
    final size = videoDisplaySize(const VideoParams(w: 1280, h: 720));

    expect(size, const Size(1280, 720));
  });

  test('90 度旋转交换宽高', () {
    final size = videoDisplaySize(
      const VideoParams(w: 1920, h: 1080, rotate: 90),
    );

    expect(size, const Size(1080, 1920));
  });

  test('180 度旋转保持宽高', () {
    final size = videoDisplaySize(
      const VideoParams(w: 1920, h: 1080, rotate: 180),
    );

    expect(size, const Size(1920, 1080));
  });

  test('无效尺寸返回 null', () {
    expect(videoDisplaySize(const VideoParams()), isNull);
    expect(videoDisplaySize(const VideoParams(dw: 0, dh: 0)), isNull);
  });
}
