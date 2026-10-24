# 性能与包体基线

> 建立：2026-10-23 · 对应 PLAN §4 Core-4 的「性能 / 包体基线」验收项
> 测量环境：Windows 11 / x86_64，Rust 1.99.1 release（`opt-level = "z"` + LTO）

基线的作用是**发现劣化**，不是追求绝对数字。不同机器的绝对值不可比，
因此门槛写在 CI 里（见 `scripts/check_perf_budget.py`），比较的是「同一台
CI runner 上本次与上次的差异」。

## 1. 引擎热路径（解析）

命令：`cargo run --release -p guo-bench`

| 用例 | 迭代 | P50 | P95 | 说明 |
| --- | --- | --- | --- | --- |
| `rule_load(4 rules)` | 200 | 49.9 µs | 70.7 µs | 冷启动解析 4 条随包规则 |
| `catalog_html/wuguo` | 200 | 2435.7 µs | 2879.3 µs | 51.2 KB HTML 目录 |
| `catalog_html/huaguo` | 200 | 1328.2 µs | 1723.5 µs | 41.5 KB HTML 目录 |
| `catalog_html/wangguo` | 200 | 2397.5 µs | 2874.0 µs | 44.5 KB HTML 目录 |
| `catalog_html/faguo` | 200 | 113.1 µs | 142.4 µs | 2.4 KB HTML 目录 |
| `catalog_html/dsd` | 200 | 53.2 µs | 87.7 µs | 0.7 KB HTML 目录 |
| `detail_html/wuguo` | 200 | 23.3 µs | 23.6 µs | 分集解析 |
| `detail_html/wangguo` | 200 | 1219.0 µs | 1537.5 µs | 分集解析 |
| `detail_html/faguo` | 200 | 70.7 µs | 75.7 µs | 分集解析 |
| `embedded_json/heguo` | 200 | 147.2 µs | 220.1 µs | `__NEXT_DATA__` 内嵌 JSON |
| `engine_open` | 50 | 585.6 µs | 928.7 µs | 引擎装配（开目录 / 恢复索引 / 建客户端） |

### 怎么读这些数字

**单位成本**：HTML 目录解析约 33–72 µs/KB。差异来自 DOM 结构复杂度
（嵌套深度、卡片字段数），不是选择器写法的优劣。这条区间可作为新站源的
参考：明显超出说明规则里有回溯或重复遍历。

**首屏解析链路**（不含网络与 Flutter 启动）：

```
engine_open 586 µs + rule_load 50 µs + catalog 2436 µs ≈ 3.1 ms
```

也就是说，**解析不是首屏瓶颈**。真实首屏时间由网络请求主导，因此
「首屏目录 P95」这类指标必须在在线用例里测，本基线不覆盖。

**`engine_open` 的构成**：打开数据目录、恢复会话与下载索引、建 HTTP 客户端。
586 µs 意味着即使数据目录里有历史任务，启动也是毫秒级。

## 2. 包体

命令：`python scripts/measure_size.py`

### Android APK（arm64-v8a，split-per-abi）

| 项 | 体积 |
| --- | --- |
| **APK 总计** | **32.4 MiB** |
| `libflutter.so` | 11.2 MiB |
| `libmpv.so` | 11.8 MiB |
| `libapp.so`（AOT Dart） | 8.4 MiB |
| `libguo_engine.so` | 5.1 MiB |
| `libffmpegkit.so` | 453 KiB |

引擎库在 APK 里是 **5.1 MiB**（磁盘上 9.8 MiB，构建时已 strip）。占 APK 约 16%，
低于播放器链路（mpv + flutter engine 合计 23 MiB）。

### Windows 运行目录

| 项 | 体积 |
| --- | --- |
| **整目录** | **237.2 MiB** |
| `libmpv-2.dll` | 116 MiB |
| `libx265-216.dll` | 22 MiB |
| `flutter_windows.dll` | 21 MiB |
| `guo_engine.dll` | 14.7 MiB |
| `avcodec-62.dll` | 11 MiB |
| `data/`（资源 + AOT） | 13 MiB |

`libmpv-2.dll` 单独占近一半。这是本地播放（含画质增强）的代价，
要减只能换播放后端或提供精简版，属于产品取舍而非缺陷。

### 内置字体（2026-10-23 新增）

视觉复刻引入内置中文字体 `MiSans-Regular.ttf`（单一字重，w500 以上由
Flutter 合成）。

| 项 | 体积 |
| --- | --- |
| 字体文件（磁盘） | **7.75 MiB** |
| 折合 APK 增量（deflate 后） | **约 5.18 MiB**（压缩率 67%） |
| 折合 Windows 目录增量 | 7.75 MiB（`data/flutter_assets` 不压缩） |

**这是基线变更，不是劣化。** 上面两张表是引入字体**之前**的数字；重新
构建后预计 APK 约 37.6 MiB、Windows 目录约 245 MiB。CI 里没有包体护栏
（`scripts/check_perf_budget.py` 只查解析 P95，见 `.github/workflows/build.yml`），
因此这一步不会被阻断。

若要回收这部分体积，唯一手段是子集化（只保留 GB2312 常用字 + 拉丁），
通常能压到 1.5–2.5 MiB。当前选择不子集化：字形完整性与参照应用一致，
且子集化会让生僻字回退到系统字体、在一行标题里出现两种字形。

### 引擎库对比

| 平台 | 体积 | 备注 |
| --- | --- | --- |
| Android arm64（APK 内） | 5.1 MiB | 已 strip |
| Android arm64（磁盘） | 9.8 MiB | 未 strip，含调试符号 |
| Windows x64 | 14.7 MiB | 未 strip |

## 3. 内存

引擎侧目前**没有**常驻内存的自动测量。原因：可用手段都要么依赖平台工具
（`tasklist` / `dumpsys`），要么需要在应用内埋点并暴露出来，两者都跨平台不一致。

已知的结构性事实（来自代码，非实测）：

- 目录缓存与封面缓存都有容量上限（封面 8 MiB），不会无限增长；
- 下载任务表只存元数据，实际数据落盘；
- 插件宿主（wasmtime）按需实例化，停用插件后实例释放。

**待办**：如需内存基线，建议在诊断页加一个「引擎堆占用」字段（用
`std::alloc` 计数包装器），比外部工具更可复现。已记入 PLAN §10 未决问题。

## 4. 复现方式

```bash
# 解析基线（约 1 分钟）
cargo run --release -p guo-bench

# 机器可读，便于对比
cargo run --release -p guo-bench -- --iterations 500 --json

# 包体（需先构建对应平台）
flutter build apk --release --split-per-abi
python scripts/measure_size.py
```

## 5. 门槛

CI 的 `rust` job 会跑 `guo-bench` 并把结果写入 job summary；
`scripts/check_perf_budget.py` 对**单次运行**做粗粒度护栏（例如单条用例
超过 100 ms 视为异常），不做跨版本比较——runner 型号会变，跨版本比较的
噪声大于真实劣化。
