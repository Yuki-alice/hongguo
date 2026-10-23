#!/usr/bin/env python3
"""生成界面截图，供人工比对视觉改动。

调用 `flutter test` 里的截图用例（`CAPTURE_SCREENS=true`），输出到
`test/ui/shell/captures/`。这些用例只出图、不做断言，不进入 CI 阻断路径。

用法：

    python3 scripts/capture_screens.py             # 重新生成
    python3 scripts/capture_screens.py --open      # 生成后打开目录

需要先 `flutter pub get`；引擎动态库由 native-assets 钩子自动构建。
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEST_FILE = "test/ui/shell/capture_screens_test.dart"
OUTPUT = ROOT / "test/ui/shell/captures"


def run(open_after: bool) -> int:
    command = [
        "flutter",
        "test",
        TEST_FILE,
        "--dart-define=CAPTURE_SCREENS=true",
        "--update-goldens",
    ]
    print("$", " ".join(command))
    result = subprocess.run(command, cwd=ROOT)
    if result.returncode != 0:
        return result.returncode

    images = sorted(OUTPUT.glob("*.png")) if OUTPUT.exists() else []
    if not images:
        print("没有生成任何截图，检查用例是否被跳过。", file=sys.stderr)
        return 1

    print(f"\n生成 {len(images)} 张截图：{OUTPUT}")
    for image in images:
        print(f"  {image.name}  {image.stat().st_size // 1024} KB")

    if open_after:
        opener = "open" if sys.platform == "darwin" else "xdg-open"
        subprocess.run([opener, str(OUTPUT)], check=False)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--open",
        action="store_true",
        help="生成后打开输出目录",
    )
    args = parser.parse_args()
    if not (ROOT / "pubspec.yaml").exists():
        print("请在项目根目录运行。", file=sys.stderr)
        return 1
    return run(args.open)


if __name__ == "__main__":
    os.chdir(ROOT)
    raise SystemExit(main())
