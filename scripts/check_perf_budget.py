#!/usr/bin/env python3
"""性能护栏：对 guo-bench 的单次结果做粗粒度检查。

设计取舍：
- **不做跨版本比较**。CI runner 型号会变，跨版本数字的噪声大于真实劣化，
  那样的门禁只会产生假失败。
- **只拦「明显坏了」的情况**。阈值设得比实测高一个数量级左右，能抓住
  「某条路径突然退化成秒级」这类问题，同时不会因为 runner 波动而误报。

用法：
    cargo run --release -p guo-bench -- --json > bench.json
    python scripts/check_perf_budget.py bench.json
"""

import argparse
import json
import sys
from pathlib import Path

# 每个用例的 P95 上限（微秒）。设为实测值的 ~8-20 倍：
# 足以容忍慢一档的 runner，又能拦住真正的性能事故。
BUDGETS_US = {
    'rule_load(4 rules)': 2_000,
    'catalog_html/wuguo': 50_000,
    'catalog_html/huaguo': 50_000,
    'catalog_html/wangguo': 50_000,
    'catalog_html/faguo': 10_000,
    'catalog_html/dsd': 10_000,
    'detail_html/wuguo': 5_000,
    'detail_html/wangguo': 30_000,
    'detail_html/faguo': 5_000,
    'embedded_json/heguo': 10_000,
    'engine_open': 30_000,
}


def main():
    parser = argparse.ArgumentParser(description='检查 guo-bench 结果是否超出预算')
    parser.add_argument('report', type=Path, help='guo-bench --json 的输出文件')
    options = parser.parse_args()

    try:
        rows = json.loads(options.report.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError) as error:
        print(f'读取基准结果失败：{error}', file=sys.stderr)
        return 2

    failures = []
    unknown = []
    for row in rows:
        name = row.get('case', '')
        p95 = row.get('p95_us')
        if p95 is None:
            continue
        budget = BUDGETS_US.get(name)
        if budget is None:
            unknown.append(name)
            continue
        status = 'ok' if p95 <= budget else 'OVER'
        print(f'{name:<28} p95={p95:>10.1f}us  budget={budget:>8}us  {status}')
        if p95 > budget:
            failures.append((name, p95, budget))

    if unknown:
        # 新用例没有预算不代表失败，只是提醒补一条。
        print('\n未设置预算的用例（请在 check_perf_budget.py 里补上）：')
        for name in unknown:
            print(f'  - {name}')

    if failures:
        print('\n性能护栏未通过：', file=sys.stderr)
        for name, p95, budget in failures:
            print(f'  {name}: p95 {p95:.1f}us 超过预算 {budget}us', file=sys.stderr)
        return 1

    print('\n性能护栏通过。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
