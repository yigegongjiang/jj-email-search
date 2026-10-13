```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

## [0.2.0] - 2026-10-13

### Added

- 实现 Thunderbird 本地只读手动同步，支持多账户 / 多文件夹和增量更新。
  - Mork 成员解析、mbox 边界流读取 / maildir、快照校验、稳定来源键和幂等提交；进度与数据原子持久化。
  - 缓存清理保留、取消 / 异常恢复、版本化索引与源目录导出保护。
- 实现中英全文检索，完整返回全部命中邮件，支持字段选择与短语 / 布尔查询。
  - Rust Tantivy + C ABI；原文 STORED、列表 fast fields；有界元数据缓存；中文 Jieba + 英文内置分词。
- 提供独立正文 / 完整正文预览、附件保存与邮件导出；所有处理在本地执行。
  - AppKit 原生 AX 后台操作；Universal Rust / Swift Release 构建与锁定依赖。

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
