"""构建引擎动态库，并放到 flutter_rust_bridge 生成代码会查找的位置。

工作区拆分后 cargo 的产物在 `rust/target/`，而 FRB 按 `rust_root` 推出
`rust/bridge/target/`。两边不一致时，生成代码里写的 `ioDirectory` 与
真实产物必有一处对不上：手工改生成文件会在下次 codegen 后被冲掉。

本脚本只做一件事——构建后把产物同步到两侧目录，使
`flutter_rust_bridge_codegen generate` 无需任何手工修改，`flutter test`
也总能加载到库。

用法：
    python scripts/prepare_engine.py            # release
    python scripts/prepare_engine.py --debug    # debug
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


root = Path(__file__).resolve().parents[1]
engine = root / 'rust'
crate = 'guo_engine'


def library_name() -> str:
    if sys.platform == 'win32':
        return f'{crate}.dll'
    if sys.platform == 'darwin':
        return f'lib{crate}.dylib'
    return f'lib{crate}.so'


def build(profile: str) -> None:
    command = ['cargo', 'build', '--manifest-path', str(engine / 'Cargo.toml'), '-p', crate]
    if profile == 'release':
        command.append('--release')
    subprocess.run(command, cwd=root, check=True)


def synchronize(profile: str) -> list[Path]:
    name = library_name()
    source = engine / 'target' / profile / name
    if not source.is_file():
        raise SystemExit(f'构建产物缺失：{source}')
    targets = [engine / 'target' / profile / name]
    bridge = engine / 'bridge' / 'target' / profile / name
    bridge.parent.mkdir(parents=True, exist_ok=True)
    if bridge.resolve() != source.resolve():
        shutil.copy2(source, bridge)
        targets.append(bridge)
    return targets


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--debug', action='store_true', help='构建 debug 而非 release')
    parser.add_argument('--no-build', action='store_true', help='只同步，不重新构建')
    options = parser.parse_args()
    profile = 'debug' if options.debug else 'release'
    if not options.no_build:
        build(profile)
    for target in synchronize(profile):
        print(f'{profile}: {target.relative_to(root)}')


if __name__ == '__main__':
    main()
