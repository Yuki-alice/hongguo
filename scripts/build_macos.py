import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from app_build import BuildVariant, add_variant_argument

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
add_variant_argument(parser)
options = parser.parse_args()
variant = BuildVariant(options.all_sources)
environment = os.environ.copy()
flutter = shutil.which('flutter')
if not flutter:
    raise SystemExit('请先将 Flutter SDK 的 bin 目录加入 PATH。')
subprocess.run([flutter, 'pub', 'get', '--enforce-lockfile'], cwd=root, env=environment, check=True)
subprocess.run([flutter, 'build', 'macos', '--release', '--no-pub', *variant.flutter_arguments],
               cwd=root, env=environment, check=True)
subprocess.run([sys.executable, str(root / 'scripts' / 'package_release.py'), '--platform', 'macos', *variant.arguments],
               cwd=root, env=environment, check=True)
