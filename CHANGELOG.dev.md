```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

## [0.1.1] - 2026-10-13

### Added

- 从 macOS 模板初始化 jj-email-search 应用骨架，邮件检索待实现
  - 复制模板工程、资源、配置与脚本；同步替换工程、scheme、Bundle ID 和配置目录标识

### Changed

- 构建与运行统一为 Release，多 worktree 支持同一应用标识的独立进程
  - 删除 Debug 构建配置、图标、配置目录及实例标题；debug.sh 构建 Release，按产物路径启停并输出 PID
  - install-local.sh 按安装产物路径定位进程，后台启动与输出 PID
- 应用图标改为蓝色信封与金色放大镜
  - 替换 AppIcon 的 16–1024 px PNG 资源，保留透明边缘
