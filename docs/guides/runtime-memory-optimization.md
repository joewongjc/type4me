# Type4Me 运行时内存优化与验收

> 文档类型：开发设计 / 维护指南
> 文档状态：当前有效（已实现，待实机验收）
> 设计日期：2026-08-12
> 最后校验：2026-08-13
> 实现基线：当前工作树（待合并）
> 关联设计：`docs/features/intelli-sense/user-correction-text-recognition-design.md`

## 1. 结论

主进程高内存的主要来源是设置窗口以透明层同时挂载全部页面，以及 Ask Anything 的 `NSPanel`/`NSHostingView` 被普通启动路径提前创建。历史数据库体积不是主要原因，现有样本中也没有足以解释占用的传统泄漏。

当前实现采用以下边界：

- 设置窗口任意时刻只挂载当前标签；关闭或最小化窗口后卸载内容页；
- 模式、ASR 和 LLM 草稿在卸载前统一确认；
- Ask Anything 业务状态常驻共享 Coordinator，浮动面板按需创建并在空闲后释放；
- LLM client 与 `URLSession` 按 provider、凭据、模型、端点和代理配置复用，配置变化时显式失效旧 session；
- ASR 继续复用共享 `URLSession`，但 WebSocket 接收改为回调驱动并在结算后强制取消，避免滞留 task 同时挂住长期 Swift async continuation；
- 录音浮条与音频链路继续预创建，保证首次录音延迟；
- CppJieba 延迟到首次中文边界分析时加载，空闲 10 分钟后销毁 C++ handle；当前 vendored `DictTrie::GetDictCache` 仍会让基础词典静态缓存常驻到进程退出。

## 2. CppJieba 资源与生命周期

CppJieba 使用 `dict.txt.small`、HMM 和持久化用户 overlay。仓库资源约 2.0 MB，当前压缩结果约 0.92 MB，不得加入标准 `jieba.dict.utf8`。

编译、打包和运行时开关分别是：

- `Sources/CppJiebaBridge/marker`：启用 Swift Package C++ target 和 `HAS_CPPJIEBA`；
- `ENABLE_CPPJIEBA=1`：发布脚本包含桥接与词典资源；
- `tf_cppJiebaExperimentEnabled`：运行时是否创建 handle，默认开启。

关闭运行时开关、资源加载失败或词典损坏时使用 `NLTokenizer` 降级。空闲释放会销毁 handle、运行时 Trie 和 HMM；用户确认词仍保存在 `jieba-user-dictionary-v1.utf8`，重载后继续生效。但 CppJieba 的 `GetDictCache` 使用进程级静态 map 持有基础词典，当前版本不会在 handle 销毁时释放这部分内存。实测一次智能感知会产生约 6 MB 的连续词典分配和大量小对象，使纯快速模式约 37 MB 的 footprint 上升到约 52 MB。后续必须移除该静态缓存或提供最后实例销毁后的安全清理接口，才能宣称词典完整空闲释放。

## 3. 测量矩阵

所有对比必须使用同一个 Release 构建、相同用户数据和同一台机器，每个检查点运行三次取中位数。UI 优化前后使用相同 Jieba 构建，Jieba 增量另做 A/B。

| 检查点 | 操作 | 目标 |
|---|---|---:|
| 冷启动 | 不打开设置、不触发中文纠正，静置 60 秒 | ≤125 MB，且较旧实现降低 ≥45% |
| 设置关闭 | 依次打开页面后关闭，静置 60 秒 | 不高于对应冷启动基线 20 MB |
| 设置循环 | 全标签切换并关闭 20 次 | 总净增 ≤15 MB，预热后 ≤1 MB/轮 |
| Jieba 首次加载 | 触发中文单字纠正分析 | 增量 ≤45 MB，P95 ≤500 ms |
| Jieba 预热 | 重复局部窗口分词 | P50 ≤2 ms，P95 ≤10 ms |
| Jieba 空闲 | 停止使用 10 分钟 | handle/运行时 Trie/HMM 已销毁；基础词典静态缓存仍是已知未达标项 |
| LLM 连续使用 | 同一配置连续完成 30 次请求 | 只创建一个 client/session，不随请求数线性增长 |
| ASR 连续使用 | 连续完成录音并分阶段采样 | 记录 WebSocket task 增长斜率和 physical footprint；当前 URLSession task 计数仍随录音线性增长 |
| 闲置 CPU | 无窗口、无录音 | <0.5% |

主进程不包含 SenseVoice、Qwen3-ASR 或 Ollama 子进程。物理内存使用 Activity Monitor 的 Memory 或 `footprint`，不要用 `ps RSS` 代替。

记录检查点：

```bash
bash scripts/measure-runtime-memory.sh <pid> cold /tmp/type4me-memory.csv
bash scripts/measure-runtime-memory.sh <pid> settings-closed /tmp/type4me-memory.csv
bash scripts/measure-runtime-memory.sh <pid> jieba-loaded /tmp/type4me-memory.csv
```

检查资源预算：

```bash
bash scripts/check-jieba-budget.sh
```

物理内存可能因系统分配器缓存而不会立即完全回落，因此空闲验收同时检查 live heap 中旧设置页、`NSHostingView`、CppJieba Trie 和 HMM 对象是否归零，以及重复循环是否继续单调增长。禁止调用内存压力或强制分配器清理制造下降。

## 4. 发布门槛

- 设置导航、关闭窗口和外部通知跳转不得绕过草稿确认；
- 普通录音、快捷键注册与提示更新不得创建 Ask 面板；
- 相同 LLM 配置不得为每次推测、最终处理、翻译重试或 Ask Anything 请求新建 `URLSession`；
- LLM provider、凭据、模型、端点或代理配置变化后，旧 client 必须调用 `invalidate()`；
- ASR 后台清理任务即使因下一次录音而取消，也必须执行 client disconnect；
- WebSocket disconnect 必须强制取消底层 task，回调必须使用 generation 和对象身份隔离旧连接；
- CppJieba UTF-8 offset、overlay 重载、缺失资源降级和 handle 空闲释放测试必须通过；基础词典静态缓存问题解决前不得宣称完整词典回收；
- Jieba 原始资源 ≤2.5 MiB，压缩资源 ≤1.2 MiB；
- 若 Jieba 增量超过 45 MB 或无法稳定空闲释放，发布版本保留能力但将运行时默认开关改为关闭。

## 5. 2026-08-12 初步烟雾结果

使用独立 bundle ID、云端 Release/Debug 构建和默认空数据完成一次非正式烟雾测量：

| 检查点 | 物理内存 | 峰值 |
|---|---:|---:|
| Release 冷启动，Jieba 已编译但未触发 | 37.3 MB | 37.3 MB |
| Debug 设置首页打开并稳定约 25 秒 | 63.4 MB | 159.7 MB |
| Debug 设置窗口关闭 5 秒后 | 65.9 MB | 159.7 MB |
| Dev Build 42 冷启动，三次采样中位数 | 25.9 MB | 26.5 MB |

结果证明冷启动和单页设置场景已低于绝对目标，但它不替代三次中位数、真实用户数据、全标签 20 轮和 Jieba 加载前后 A/B 的正式发布验收。

Build 42 同时修复了 LLM 生命周期：此前 `LLMRuntime.resolve()` 会为每次请求创建新的 client 和 `URLSession`，现由 `RecognitionSession` actor 持有 `LLMClientCache`。同一配置复用现有连接；缓存键变化或配置不可用时显式失效并移除旧 client。

2026-08-13 连续录音诊断发现：60 次录音后 live heap 中恰有 60 个 `__NSURLSessionWebSocketTask`、60 个 `URLProtocol` 和 60 个 `NWIOConnection`。这些对象由进程级共享 ASR `URLSession` 合法持有，因此传统 `leaks` 仅报告 80 bytes，不能反映该问题。

Build 43 的首轮 34 次实机录音显示物理内存为 62–64 MB，但第一次换代后旧代 WebSocket 对象仍被 CFNetwork continuation 保留。Build 44 的 65 次快速模式录音进一步确认：两次换代都在 1 ms 内收到 `didBecomeInvalidWithError`，但 heap 仍恰有 65 个 WebSocket task，说明 Session 逻辑失效不等于对象析构。Build 47 将 Dev 换代阈值缩短为 5 后，12 次录音跨越两次换代仍保留 12 个 WebSocket task，最终否定了分代池能够限制对象数量的假设。

分代池、lease、预热切换和 `[TEMP-ASR-POOL]` 日志随后全部撤回。保留的有效改动是 completion-handler 驱动的 receive、弱引用回调、generation 隔离、强制 task 取消，以及即使后台等待被取消也必须执行 disconnect。回调化降低了每个滞留 task 所附带的 Swift 并发状态；近期快速模式样本的 physical footprint 约为 37–40 MB，但 task 数量仍线性增长，长期边界尚未解决。
