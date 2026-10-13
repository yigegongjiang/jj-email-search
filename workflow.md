```When Editing
本文档作用: 工程工作流程 (可用工具 / 调试 / 发布); MUST NOT 写工程说明 (→ README.md) / LLM 约束 (→ AGENTS.md)
遵循 AGENTS.md 文档编写规范
- 所有段落均为条件段, 根据工程实际决定保留或删除; 存在即为明确流程, MUST NOT 附加强度标记
- 发布内按顺序编号步骤; 顶部 TL;DR ≤ 5 行; 删除子段后重编号保持连续
```

# 可用工具

- `gh`
- GitHub Actions: `.github/workflows/release.yml` push tag `vX.Y.Z` 自动发布 GitHub Release; `gh workflow run release.yml --ref vX.Y.Z` 仅用于重跑
- `xcodebuild` / `swiftformat` / `swiftlint`

# 调试

- 在 `worktree/{name}` 分支完成代码改动；构建 / 安装 / 运行统一使用 Release。

```bash
./scripts/debug.sh [DEVELOPMENT_TEAM]  # 构建 Release + 后台重启本 worktree 实例, 输出 pid={PID}
./scripts/debug.sh quit                # 退出本 worktree 实例, 删除 worktree 前执行
```

- 多 worktree 使用各自 Release 产物；同一 Bundle ID / 配置 / 数据，支持多实例并存。
- peekaboo 使用 `debug.sh` 输出的 PID（`--pid {PID}`）定位本 worktree 实例；MUST NOT 按名称 / Bundle ID 选择实例。
- 实例启停只经 `debug.sh`，按本 worktree 可执行文件路径匹配 PID；MUST NOT 用 `pkill` / `killall` 按名称退出。

# 发布

行为 / 交付物变更完成后执行; 纯文档调整不触发。交付 = 预部署 + commit + tag + push (无 remote 时跳过 push)。

## TL;DR

1. 写 changelog: `CHANGELOG.md` + `CHANGELOG.dev.md` 顶部 `## [Unreleased]` 段, 随改动 commit 到 worktree 分支
2. 发布: `./scripts/release.sh [minor] [DEVELOPMENT_TEAM]`
3. 收尾: `./scripts/debug.sh quit` + `git worktree remove` + 删分支

## 1. 写 changelog

- 两份文件顶部新增 `## [Unreleased]` 段 (版本号 + 日期由 `release.sh` 填写)
- 版本号: 默认递增 PATCH (第三位); 超大功能更新/调整 → `minor`; 禁止 → MAJOR（除非人类主动要求）

## 2. 发布

执行 `./scripts/release.sh [minor] [DEVELOPMENT_TEAM]` (封装: swiftformat / swiftlint 验证 -> rebase 到 master -> 按 master 版本号重算 + tag 查重 -> 写 `version.xcconfig` + changelog -> `install-local.sh` 预部署 -> commit -> merge --ff-only -> annotated tag -> push)

脚本失败 -> 修复原因后重跑。

## 3. 收尾

```bash
./scripts/debug.sh quit  # 在 worktree 内执行
git worktree remove worktree/{name} && git branch -d {name}  # 在主 checkout 执行
```
