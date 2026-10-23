#!/usr/bin/env python3
"""测量安装包与引擎动态库的体积基线。

产物由各自的构建流程生成，这个脚本只做「读取并报告」，不触发构建：
构建耗时且平台相关，混进来会让基线不可重复。用法：

    python scripts/measure_size.py                 # 报告已有产物
    python scripts/measure_size.py --json          # 机器可读

缺失的产物会跳过并在末尾说明，而不是报错——本地通常只构建了某一个平台。
"""

import argparse
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (标签, 相对路径, 说明)
TARGETS = [
    ('android-apk-arm64', 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk', 'Android APK（arm64-v8a）'),
    ('android-apk-armv7', 'build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk', 'Android APK（armeabi-v7a）'),
    ('android-apk-x64', 'build/app/outputs/flutter-apk/app-x86_64-release.apk', 'Android APK（x86_64）'),
    ('windows-bundle', 'build/windows/x64/runner/Release', 'Windows 运行目录（整目录）'),
    ('macos-app', 'build/macos/Build/Products/Release/duanju_app.app', 'macOS 应用包'),
    ('engine-windows', 'rust/target/release/guo_engine.dll', '引擎动态库（Windows）'),
    ('engine-android-arm64', 'rust/target/aarch64-linux-android/release/libguo_engine.so', '引擎动态库（Android arm64）'),
    ('engine-android-armv7', 'rust/target/armv7-linux-androideabi/release/libguo_engine.so', '引擎动态库（Android armv7）'),
]

# APK 里值得单独看的条目：引擎库与播放器链路通常占大头。
APK_ENTRIES = ['lib/arm64-v8a/libguo_engine.so', 'lib/arm64-v8a/libflutter.so',
               'lib/arm64-v8a/libapp.so', 'lib/arm64-v8a/libmpv.so',
               'lib/arm64-v8a/libffmpegkit.so']


def directory_size(path):
    return sum(item.stat().st_size for item in path.rglob('*') if item.is_file())


def measure():
    rows = []
    missing = []
    for label, relative, description in TARGETS:
        path = ROOT / relative
        if not path.exists():
            missing.append(f'{label}（{relative}）')
            continue
        size = directory_size(path) if path.is_dir() else path.stat().st_size
        rows.append({
            'label': label,
            'description': description,
            'path': relative,
            'bytes': size,
            'kind': 'directory' if path.is_dir() else 'file',
        })
        # APK 额外拆出关键条目，便于看引擎占比。
        if label.startswith('android-apk') and path.is_file():
            try:
                with zipfile.ZipFile(path) as archive:
                    for entry in APK_ENTRIES:
                        try:
                            info = archive.getinfo(entry)
                        except KeyError:
                            continue
                        rows.append({
                            'label': f'{label}:{Path(entry).name}',
                            'description': f'APK 内条目 {entry}',
                            'path': relative,
                            'bytes': info.file_size,
                            'kind': 'apk-entry',
                        })
            except zipfile.BadZipFile:
                missing.append(f'{label}（不是合法 zip，跳过条目拆分）')
    return rows, missing


def human(size):
    for unit in ('B', 'KiB', 'MiB', 'GiB'):
        if size < 1024 or unit == 'GiB':
            return f'{size:.1f} {unit}' if unit != 'B' else f'{size} B'
        size /= 1024
    return f'{size:.1f} GiB'


def main():
    parser = argparse.ArgumentParser(description='测量安装包与引擎库体积')
    parser.add_argument('--json', action='store_true', help='输出 JSON')
    options = parser.parse_args()

    rows, missing = measure()

    if options.json:
        print(json.dumps({'measurements': rows, 'missing': missing}, ensure_ascii=False, indent=2))
        return 0

    if not rows:
        print('没有找到任何可测量的产物。先运行一次构建，例如：', file=sys.stderr)
        print('  flutter build apk --release --split-per-abi', file=sys.stderr)
        print('  cargo build --release -p guo_engine --target x86_64-pc-windows-msvc',
              file=sys.stderr)
        return 1

    width = max(len(row['label']) for row in rows)
    print(f"{'target'.ljust(width)}  {'size':>10}  description")
    print('-' * (width + 40))
    for row in rows:
        print(f"{row['label'].ljust(width)}  {human(row['bytes']):>10}  {row['description']}")

    if missing:
        print('\n未找到（已跳过）：')
        for item in missing:
            print(f'  - {item}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
