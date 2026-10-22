"""Windows 构建冒烟：直接运行 `flutter build windows` 的产物，验证随包原生核心
（Rust 引擎动态库，由 native-assets 钩子打进包）与 ffmpeg / media_kit 链路。

用法：先 `flutter build windows --release`，再 `python scripts/smoke_windows.py`。
产物验收报告写到 build/windows-smoke.json。
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
bundle = root / 'build' / 'windows' / 'x64' / 'runner' / 'Release'
executable = bundle / 'zhenguojian.exe'


def main():
    if sys.platform != 'win32':
        raise SystemExit('此检查需要 Windows。')
    if not executable.is_file():
        raise SystemExit(f'未找到 {executable}，请先执行 flutter build windows --release。')
    with tempfile.TemporaryDirectory(prefix='zhenguojian-smoke-') as temporary:
        directory = Path(temporary)
        media = directory / 'fixture.mp4'
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'lavfi',
                        '-i', 'testsrc2=size=160x90:rate=12', '-t', '3',
                        '-c:v', 'libx264', '-threads', '1', str(media)], check=True)
        report = directory / 'result.json'
        subprocess.run([str(executable), '--package-smoke', str(report), str(media)],
                       cwd=bundle, check=True, timeout=90)
        evidence = json.loads(report.read_text())
        if evidence.get('ok') is not True:
            raise SystemExit('Windows 构建冒烟未通过：' + json.dumps(evidence, ensure_ascii=False))
        output = root / 'build' / 'windows-smoke.json'
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(evidence))


if __name__ == '__main__':
    main()
