# 设计：Autonomous Skill — 自驾项目 Agent

由 /office-hours 生成于 2026-04-02
分支: unknown
仓库: autonomous-skill (全新项目)
状态: APPROVED
模式: Builder

## 问题陈述

Jackson 在 /Volumes/ssd/i/ 下有 100+ 个项目，无法同时管理。项目在工作间隙停滞不前。他想要：cd 进入任意项目目录，启动 Claude Code，运行一个命令，agent 就自主运行 — 探索项目、发现问题、修复它们、迭代功能 — 在 session 预算内（默认 50 次迭代）或被中断之前持续运行。

Agent 扮演"项目负责人"的角色 — 不是等待指令的被动执行者，而是理解项目目标、主人品味、并自主决定下一步做什么的主动贡献者。

## 为什么这很酷

核心洞察：**技能约束 > 工具能力**。不是给 agent 一堆原始工具然后祈祷它做出好决策（Devin/OpenClaw 的路子），而是让 agent 组合经过实战检验的 gstack 工作流（/qa、/review、/investigate、/office-hours）作为它的决策菜单。每个工作流都编码了人类专家经验。Agent 不需要自己想怎么做 code review — 它调用 /review，而 /review 已经知道该怎么做了。

**术语约定**："agent" = 本 autonomous-skill 项目。"工作流" = gstack 的技能如 /qa 或 /review。"Skill" = Claude Code 的 SKILL.md 文件。

"卧槽"时刻：你睡觉去了，醒来发现项目被积极地工作了 8 小时。不是随机改动 — 而是反映你优先级和品味的有深度的迭代。

## 约束条件

1. **平台：Claude Code** — 所有逻辑以 CC skill（SKILL.md + bash 脚本）形式存在。不是独立 daemon，不是 Python 包装器。选择 CC 是因为它的 system prompt、权限模型和粒度控制优于替代方案。
2. **第一版：单 repo** — 在启动目录中运行。多 repo 协调是 Phase 2。
3. **禁止自动合并** — 第一版只创建带提案的 git 分支，不直接提交到 main。人类审查和合并。
4. **Context window 压力** — CC 会随时间压缩上下文。Skill 必须对此有弹性（用文件作为外部记忆，不依赖对话状态）。
5. **Fork gstack** — gstack 的 skill 用 AskUserQuestion 做人机交互。自主 agent 需要拦截并用自己的推理回答这些问题。需要修改 gstack 的 prompt 以支持"自主模式"。
6. **迭代上限** — 每 session 默认最多 50 次迭代（可配置）。达到上限时：写总结到日志，提交进行中的分支，优雅退出。防止一夜之间 API 费用失控。
7. **多 skill 提供者** — 推迟到 Phase 2。Phase 1 硬编码 gstack。抽象层等第二个 provider 出现时再加。

## 前提假设

1. Claude Code skill 系统是正确的平台（接受 CLI/context 限制）— 已确认
2. Skill 优先 + 原始推理兜底（混合模式）— 已确认
3. 混合任务源：用户方向 + agent 自主发现 — 已确认
4. Fork gstack，修改 prompt 适配自主模式 — 已确认
5. 主人画像从 git history + 项目文档自动学习 — 已确认
6. 支持多 skill 生态系统 — 已确认（推迟到 Phase 2；Phase 1 硬编码 gstack）

## 跨模型视角

Claude subagent 冷读分析：

- **Fleet + Memory Bus** 概念：当 agent 在一个 repo 修了 bug，写发现到 SQLite 账本。访问另一个有类似模式的 repo 时，复用修复方案。跨 100+ repo 的学习能力。（推迟到 Phase 2。）
- **核心情感驱动力**是"离线时的杠杆" — 醒来看到 8 小时进展的幻想。这应该是北极星指标。
- **SWE-agent 作为参考**：完成了 50%（自主探索、issue 识别、patch 生成）。缺少：主人画像、skill 路由、中断安全状态、多 repo。
- **周末原型建议**：loop harness + 主人画像过滤器。成功标准 = 醒来看到 3-5 个修复提案分支。

共识：第一版不应自动提交。Skills-as-constraint 论点成立。
分歧：subagent 建议 Python + subprocess。我们选了 Pure Skill（SKILL.md）因为要留在 CC 生态内 — 这是选择 CC 的全部意义。

## 考虑过的方案

### 方案 A：Pure Skill — "单文件流"（已选）

一个 SKILL.md + 配套 bash 脚本。所有编排逻辑在 system prompt 里。CC 原生执行 loop。

```
autonomous-skill/
├── SKILL.md          # 核心逻辑：loop、路由、persona
├── scripts/
│   ├── discover.sh   # 探索项目结构，发现问题
│   ├── persona.sh    # 从 git + 文档构建主人画像
│   └── loop.sh       # 主循环驱动
└── CLAUDE.md
```

**工作量：** S（CC: ~2 小时）
**风险：** 低
**优点：** 最小 diff，最快上线，100% 留在 CC 生态内
**缺点：** 跨 session 无持久状态，context 压缩可能丢进度，任务队列不够精密

### 方案 B：Skill + Runtime — "混合架构"

SKILL.md 作为入口，核心逻辑（任务队列、主人画像、skill 路由、状态持久化）用 TypeScript/Bun 实现。SQLite 做任务队列。

**工作量：** M（CC: ~4 小时）
**风险：** 中
**优点：** 状态持久化，可扩展的 provider 系统，正经的任务队列
**缺点：** 需要 build 步骤，组件更多，对 POC 来说过度

### 方案 C：Agent Daemon — "后台服务"

通过 Claude Code SDK/API 调用 Claude 的独立 daemon 进程，用 launchd 管理生命周期。

**工作量：** L（CC: ~8 小时）
**风险：** 高
**优点：** 真正后台运行，可靠的生命周期管理
**缺点：** 复杂度高，脱离 CC 生态，难分发

## 推荐方案

**方案 A：Pure Skill。** 目标是证明核心 loop 能跑通 — agent 能否对"下一步做什么"做出好的判断？能否有效组合 skill？主人画像能否产生有意义的优先级排序？

如果答案是 yes，方案 B 是自然进化（加持久化、正经任务队列）。如果答案是 no，我们用最低成本学到了这一点。

## 核心设计：自主循环

### 1. 启动阶段

Skill 被调用时：

1. **读取项目上下文**：CLAUDE.md、README.md、package.json、TODOS.md、最近 git log
2. **构建主人画像**：分析 git history（commit 风格、重点领域、代码模式）、项目文档和任何已有的 persona 文件
3. **初始评估**：运行 /health（如可用）获取基准质量分
4. **生成任务列表**：合并显式 todo（TODOS.md、代码中的 TODO 注释、GitHub issues）和发现的问题（/qa 发现、/review 发现、/investigate 发现）
5. **排序**：用主人画像按可能的主人优先级排列任务

### 2. 主循环

循环由 `loop.sh`（bash while-loop）驱动，不是 CC 的对话模型。每次迭代生成一次全新的 CC 调用。避免了 context window 耗尽 — 每次迭代从外部状态文件加载干净的上下文。

SLUG 推导规则：`basename $(git rev-parse --show-toplevel 2>/dev/null || pwd)`

```
# loop.sh 驱动 — bash while-loop，不是 CC 对话 loop
iteration=0
max_iterations=${MAX_ITERATIONS:-50}  # 可配置，默认 50

WHILE iteration < max_iterations AND 没收到 SIGINT:
  1. 从 ~/.gstack/projects/SLUG/autonomous-state.json 读取状态
     （任务列表、当前进度、主人画像路径）
  2. 选择最高优先级的任务
  3. 路由到对应的 gstack 工作流或直接操作：
     - 代码质量 → /review, /qa
     - Bug/错误 → /investigate
     - 缺少测试 → 直接操作（agent 写测试）
     - 功能设计 → /office-hours（仅设计，不实现）
     - 安全 → /cso
     - 文档 → /document-release
     注意：/ship 被排除在自主模式之外（违反禁止自动合并规则）
  4. 创建分支 auto/[task-slug]-[iteration]（时间戳避免冲突）
  5. 通过 claude -p "..." --output-format json > /tmp/auto-result-$iteration.json 启动 CC
     Prompt 包含：任务描述、主人画像、工作流名称、目标分支。
     CC 在签出的分支上写代码变更。退出后，loop.sh 读取 JSON 输出判断成功/失败。
     **状态交接协议**：CC 写入 git（分支提交）和 stdout（JSON 结果）。
     loop.sh 读取 JSON 结果和 git status 判断结果。执行期间无共享可变状态文件
     — 只有 loop.sh 写入 autonomous-state.json。
  6. 验证结果：loop.sh 运行 `git diff --stat`、测试命令（从 package.json）、构建检查
  7. 成功（测试通过，构建通过）：
     - 追加到 ~/.gstack/projects/SLUG/autonomous-log.jsonl
     - 在 autonomous-state.json 标记任务完成
  8. 失败：
     - git checkout main && git branch -D auto/[task-slug]-[iteration]（清理坏分支）
     - 在状态文件记录失败（增加 strike 计数）
     - 同一任务 3 次失败 → 永久跳过，记录原因
     - 注意：strike 计数在任务列表刷新后保留（按任务哈希存储）
  9. 每 5 次迭代刷新任务列表（重新扫描新问题）
  10. 迭代计数器 +1

退出时（达到上限、SIGINT 或错误）：
  - 等当前 CC 调用完成（不中途杀掉）
  - 如果当前分支有未提交变更且测试通过：
      git commit -m "WIP: autonomous partial — [任务描述]"
    否则如果测试失败：
      git stash（保留工作但不提交损坏状态）
  - 写最终总结到 autonomous-log.jsonl
  - 写退出原因到 autonomous-state.json
  - 返回 main 分支
  - 干净退出
```

**中断处理**：loop.sh 捕获 SIGINT。中断时：等当前 CC 调用完成（不中途杀掉），写状态，提交部分分支，退出。哨兵文件（`~/.gstack/projects/SLUG/.stop-autonomous`）也触发优雅关机 — 方便远程停止。

**"直接操作"兜底**：当没有匹配的 gstack 工作流时，agent 读取相关文件，用自己的判断写 patch，提交到 feature 分支。Prompt 包含主人画像用于风格指导。

### 3. 主人画像

**Phase 1（概念验证）：** 项目根目录的手动 `OWNER.md` 文件。简单模板：

```markdown
# 主人画像
## 优先级（最重要的事）
## 风格（代码规范、commit 风格）
## 避免（不要改的东西）
## 当前焦点（现在在做什么）
```

如果没有 `OWNER.md`，persona.sh 从以下自动生成草稿：
- `git log --oneline -50`（最近的重点领域、commit 风格）
- `CLAUDE.md`（显式偏好）
- `README.md`（项目目标）

自动生成的草稿写入 `OWNER.md` 供主人审查和编辑。Agent 使用 `OWNER.md` 中的内容 — 主人有最终决定权。

**Phase 2：** 自动学习，根据主人合并/拒绝的分支更新 OWNER.md。

用途：
- **任务优先级**："主人会在意这个吗？"
- **决策制定**：当 gstack 工作流问问题时，以主人的方式回答
- **风格匹配**：代码变更匹配主人的编码风格

### 4. 技能路由

路由器将任务类型映射到 gstack 工作流：

| 任务类型 | Gstack 工作流 | 兜底（直接操作） |
|---------|--------------|----------------|
| 代码质量 | /review | Agent 读文件，写 patch |
| Bug/错误 | /investigate | Agent 调试并修补 |
| 测试覆盖 | /qa | Agent 直接写测试 |
| 功能设计 | /office-hours | Agent 写设计文档 |
| 安全 | /cso | Agent 审查并修补 |
| 文档 | /document-release | Agent 写文档 |
| 发布/部署 | **排除** | **排除**（禁止自动合并）|

**排除**：/ship 在自主模式中不可用。Agent 可以准备用于发布的分支，但人类决定何时合并和部署。

当没有工作流匹配时，agent 直接操作：读取相关文件，推理修复方案，写 patch，提交到 `auto/` 分支。OWNER.md 画像指导风格和范围决策。

### 5. 安全防护

- **禁止自动合并**：所有变更去 `auto/` feature 分支。人类合并。
- **迭代上限**：每 session 默认 50 次。通过 `MAX_ITERATIONS` 环境变量配置。达到上限：优雅关机并输出总结。
- **三振出局**：同一任务失败 3 次 → 永久跳过，记录原因
- **范围边界**：只动项目目录内的文件
- **禁止破坏性操作**：不 rm -rf，不 force push，不 drop tables
- **进度日志**：每个操作追加到 `~/.gstack/projects/SLUG/autonomous-log.jsonl`
- **中断处理**：loop.sh 捕获 SIGINT。完成当前任务，写状态，退出。哨兵文件 `.stop-autonomous` 也触发优雅关机。
- **自主模式禁止 /ship**：Agent 不能 merge、deploy 或 push 到 main

### 6. Gstack Fork 策略

Fork gstack 并修改工作流 prompt 以支持"自主模式"：

**前置条件（Next Steps #0）：** 审计 gstack 的 AskUserQuestion 使用模式。如果 AskUserQuestion 是内联在每个工作流的 prompt 中，第一步是将其重构为集中式 hook 或决策点。这决定了 fork 的 diff 范围。

- 添加 `AUTONOMOUS_MODE` 环境变量，工作流可以检查
- 在自主模式下，AskUserQuestion 调用被替换为决策函数，读取 OWNER.md + 上下文来选择推荐选项
- **接受分歧**：fork 会与上游 gstack 分歧。定期 cherry-pick 上游改进，但不试图维持完全的合并兼容性。自主模式的补丁是结构性变更，不是表面修改。

## 待解决问题

1. **通知**：Agent 是否应在完成重要工作或遇到阻塞时通知主人（email、Slack、webhook）？（Phase 2 的 nice-to-have）
2. **多分支策略**：如果 agent 一夜创建 10 个分支，如何组织？命名约定 `auto/[task-type]-[description]` 是开始，但是否应尝试 rebase 自己的分支？
3. **CC 调用模型**：每次循环迭代通过 `claude --print` 或类似方式启动新 CC 实例。需要验证 50+ 次连续调用不会累积僵尸进程或触发速率限制。

## 成功标准

1. Agent 可无人值守运行 1+ 小时不崩溃或陷入死循环
2. 产出至少 3 个改变行为的 git 分支（bug 修复、新测试、新功能 — 不是格式化或表面修改）
3. 主人画像准确反映项目优先级（由主人审查验证）
4. 每个分支自包含且可审查 — 无跨分支依赖
5. 主人审查分支后标记至少 2 个为"值得合并"或"方向正确"

## 分发计划

- Git 仓库：用户 clone 并 symlink 到 `~/.claude/skills/autonomous-skill/`
- SKILL.md 是入口 — 通过 `/autonomous-skill` 或自定义别名调用
- Fork 的 gstack 作为 git submodule 或 vendored copy 打包
- Pure Skill 方案（方案 A）不需要 build 步骤
- 未来：如果存在 skill registry 可通过其分发

## 下一步

0. **验证 CC 调用模型（阻塞门控）** — 测试 `claude -p "..." --output-format json` 能否从 bash while-loop 调用 10+ 次而不出现僵尸进程、stdin 阻塞或速率限制错误。如果失败，方案 A 作废，回退到方案 B（TS runtime）。在写其他代码之前先跑这个测试。
1. **审计 gstack AskUserQuestion 模式** — 确定是集中式还是内联的。这决定 fork 策略的复杂度。
2. **创建 OWNER.md 模板** — 主人填写的简单 persona 文件
3. **写 loop.sh** — 驱动迭代的 bash while-loop，管理状态，处理 SIGINT
4. **写 SKILL.md** — CC skill 入口，包含路由逻辑和 persona 加载
5. **写 discover.sh + persona.sh** — 项目探索和 persona 自动生成
6. **Fork gstack** — 给关键工作流（/qa、/review、/investigate）添加 AUTONOMOUS_MODE 标志
7. **在一个项目上测试** — 从 /Volumes/ssd/i/ 选一个真实项目，跑 10 次迭代
8. **迭代** — 审查分支，调整 persona 和路由
9. **Phase 2：持久化 + 自动学习** — SQLite 任务队列，基于合并历史自动更新 OWNER.md
10. **Phase 3：多 repo + 多 provider** — Fleet + Memory Bus，skill provider 抽象层

## 关于你思维方式的观察

- 你说"Claude Code 的 system prompt 和粒度控制比 OpenClaw 好太多" — 你真的用过两者并基于直接比较形成了技术判断。你不是跟风选工具，你是基于机制选的。
- "同时应该维护主人的用户画像"是对话中途的补充，不是对问题的回答。我们还在讨论架构，你已经在想 agent 的人格层了。这是产品思维，不是工程思维。
- 你选了"完整自主循环"而不是更安全的"发现 + 报告"选项。你不想要一个高级 linter — 你要的是完整的自主开发者。这个野心水平是合适的，因为底层原语（gstack skill）已经存在。
- 多 provider 的洞察（"之后可能不仅仅只是 gstack"）说明你在写第一行代码之前就在想抽象层了。好的可扩展性直觉，没有过早抽象。
