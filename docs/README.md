# Type4Me 文档中心

> 文档状态：当前有效
> 最后整理：2026-08-30

这里是仓库文档的唯一入口。功能设计、开发设计和历史材料不再平铺在 `docs/` 根目录。

## 1. 如何判断文档是否仍然有效

| 标记 | 含义 | 是否可作为当前实现依据 |
|---|---|---:|
| `当前有效（已实现，持续验证）` | 功能已进入代码，文档用于维护与回归 | 是，但代码优先 |
| `当前有效（设计完成，待实现）` | 已确认的下一阶段设计 | 是，作为待实现规范 |
| `归档文档` | 历史计划、评审、报告、测试或草稿 | 否，只用于追溯 |

每份当前文档页首必须包含文档类型、状态、设计日期、最后校验日期和实现基线（如适用）。正文里的“当前实现”可能描述设计形成时的基线，阅读时以页首状态为准。

## 2. 当前功能文档

按最后校验日期从新到旧排列。

| 功能 | 文档 | 类型 | 状态 | 设计日期 | 实现基线 |
|---|---|---|---|---:|---|
| Gemini 实时 ASR | [产品设计](features/gemini-transcribe-asr/product-design.md) | 产品设计 | 当前有效（已实现，持续验证） | 2026-08-27 | `c82aa2b` |
| Gemini 实时 ASR | [开发设计](features/gemini-transcribe-asr/development-design.md) | 开发设计 | 当前有效（已实现，持续验证） | 2026-08-27 | `c82aa2b` |
| Compact 实时识别文本 | [产品设计](features/compact-live-transcript/product-design.md) | 产品设计 | 当前有效（已实现，持续验证） | 2026-08-27 | `a90f8d2` |
| Compact 实时识别文本 | [开发设计](features/compact-live-transcript/development-design.md) | 开发设计 | 当前有效（已实现，持续验证） | 2026-08-27 | `a90f8d2` |
| 液态玻璃录音指示条 | [产品设计](features/liquid-glass-recording-indicator/product-design.md) | 产品设计 | 当前有效（已实现，持续验证） | 2026-09-01 | `b67ee103`（PR #279） |
| 液态玻璃录音指示条 | [开发设计](features/liquid-glass-recording-indicator/development-design.md) | 开发设计 | 当前有效（已实现，持续验证） | 2026-09-01 | `b67ee103`（PR #279） |
| 录音外观增强 | [产品设计](features/appearance-settings-enhancements/product-design.md) | 产品设计 | 当前有效（已实现，持续验证） | 2026-08-25 | `06c06a0` |
| 录音外观增强 | [开发设计](features/appearance-settings-enhancements/development-design.md) | 开发设计 | 当前有效（已实现，持续验证） | 2026-08-25 | `06c06a0` |
| 改口 | [产品设计](features/revise/product-design.md) | 产品设计 | 设计完成，待实现 | 2026-08-18 | — |
| 改口 | [开发设计](features/revise/development-design.md) | 开发设计 | 设计完成，待实现 | 2026-08-18 | 当前工作树（待实现） |
| 运行时性能 | [运行时内存优化二期](features/runtime/runtime-memory-optimization-v2-design.md) | 专项开发设计 | 设计完成，待评审与实现 | 2026-08-15 | 当前工作树（待合并） |
| Intelli Sense | [用户纠正文本识别](features/intelli-sense/user-correction-text-recognition-design.md) | 专项开发设计 | 已实现，待 Beta 验证 | 2026-08-12 | 当前工作树（待合并） |
| 翻译模式 | [产品设计](features/translation/product-design.md) | 产品设计 | 已实现，持续验证 | 2026-08-11 | `5076296`，修订至 `0bc9bf8` |
| 翻译模式 | [开发设计](features/translation/development-design.md) | 开发设计 | 已实现，持续验证 | 2026-08-11 | `5076296`，修订至 `0bc9bf8` |
| Ask Anything | [历史会话产品设计](features/ask-anything/conversation-history-product-design.md) | 产品设计 | 已实现，持续验证 | 2026-08-10 | `3f4212a` |
| Ask Anything | [历史会话开发设计](features/ask-anything/conversation-history-development-design.md) | 开发设计 | 已实现，持续验证 | 2026-08-10 | `3f4212a` |
| Intelli Sense | [产品设计](features/intelli-sense/product-design.md) | 产品设计 | 首版已实现，持续校准 | 2026-08-09 | `302e9b4`，修订至 `9d91b92` |
| Intelli Sense | [开发设计](features/intelli-sense/development-design.md) | 开发设计 | 首版已实现，持续校准 | 2026-08-09 | `302e9b4`，修订至 `9d91b92` |

### 推荐阅读顺序

1. 先读功能目录下的产品设计，确认目标、边界和用户体验；
2. 再读开发设计，确认数据模型、并发、迁移和测试；
3. 最后读专项设计；专项文档对明确标注的章节具有更高优先级；
4. 需要了解旧方案或审查过程时再进入 `archive/`。

## 3. 当前维护指南

- [本地 Fork 维护](guides/local-fork-maintenance.md)：本地补丁、上游同步和运行时维护说明。
- [运行时内存优化与验收](guides/runtime-memory-optimization.md)：设置页、Ask 面板和 CppJieba 的生命周期、预算与实机测量方法。

## 4. 历史归档

[归档索引](archive/README.md)按日期和材料类型列出历史计划、评审、实施报告、测试计划与草稿。

归档文档有两个硬规则：

- 不作为当前实现要求；
- 不因内容过时而改写历史结论，只修复链接或补充归档说明。

## 5. 目录结构

```text
docs/
├── README.md                         # 当前入口与规范
├── features/                         # 当前功能设计
│   ├── ask-anything/
│   ├── appearance-settings-enhancements/
│   ├── compact-live-transcript/
│   ├── gemini-transcribe-asr/
│   ├── intelli-sense/
│   ├── liquid-glass-recording-indicator/
│   ├── revise/
│   └── translation/
├── guides/                           # 当前维护与操作指南
├── archive/                          # 不再生效的历史材料
│   ├── drafts/
│   ├── assets/
│   ├── plans/
│   ├── reports/
│   ├── reviews/
│   └── test-plans/
├── images/                           # 当前 README 营销素材
└── screenshots/                      # 当前产品界面截图
```

以下文档与产物按代码职责留在原目录，不搬入 `docs/`：

- `README.md`、`CHANGELOG.md`、`AGENTS.md`（及其 `CLAUDE.md` 符号链接）：仓库入口、版本记录和代理说明；
- `Evaluation/IntelliSenseEval/README.md`：独立评测包使用说明；
- `tests/*.md`、`tests/*.html`：Prompt 实验和测试报告；
- `scripts/*.html`：脚本生成的本地质量报告；
- `website-demos/*.html`：网站视觉实验，不是产品规范。

## 6. 命名规范

### 当前文档

路径格式：

```text
docs/features/<feature>/<scope>-<document-type>.md
```

约定：

- 功能目录使用稳定产品名，如 `intelli-sense`、`ask-anything`；
- 通用文件名优先使用 `product-design.md`、`development-design.md`；
- 子功能需要保留范围，如 `conversation-history-product-design.md`；
- 专项设计使用清晰主题，如 `user-correction-text-recognition-design.md`；
- 当前文件名不使用分支名、`draft`、版本号或日期；状态和日期放在页首元数据中；
- 文件名统一小写 kebab-case。

### 归档文档

路径格式：

```text
docs/archive/<category>/YYYY-MM-DD-<topic>-<document-type>.md
```

归档文件必须保留日期前缀，并在标题下方说明“归档原因”和“是否被替代”。

## 7. 页首元数据模板

```markdown
# 文档标题

> 文档类型：产品设计 / 开发设计 / 专项设计 / 维护指南
> 文档状态：当前有效（已实现，持续验证）
> 设计日期：YYYY-MM-DD
> 最后校验：YYYY-MM-DD
> 实现基线：commit（待实现时省略）
> 上游文档：相对仓库路径（如适用）
```

状态发生变化时更新“最后校验”和实现基线，不用重命名当前文件。文档失效时整体移入 `archive/`，补日期前缀与归档说明，并同步本索引。

## 8. 维护检查表

新增或更新文档时：

1. 确认它属于当前规范还是历史记录；
2. 当前功能文档放入对应 `features/<feature>/`；
3. 补齐统一元数据；
4. 在本索引登记；
5. 使用仓库相对链接并检查目标存在；
6. 新专项设计明确说明覆盖哪份上游文档的哪些章节；
7. 功能实现后，把状态从“待实现”更新为“已实现，持续验证”；
8. 文档被替代后移入归档，不让新旧方案同时留在当前目录。
