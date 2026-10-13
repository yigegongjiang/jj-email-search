```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

## [Unreleased]

### Changed

- 同步设置的「同步状态」列逐个标出未同步 / ✓ 已同步，并显示封数、未下载数与上次同步时间。
  - `SettingsViewController.syncStatus`: 读 manifest `FolderState` (`count` / `unavailable` / `synced_at`); 列宽 200 / 230 / 380

## [0.2.6] - 2026-10-13

### Changed

- 全新 App 图标：深色底 + 青绿渐变放大镜与信封，更简洁现代，小尺寸也清晰。
  - 源文件 `assets/AppIcon.svg`; `AppIcon.appiconset` 各尺寸由 `rsvg-convert -w <px>` 逐尺寸渲染

## [0.2.5] - 2026-10-13

### Changed

- 界面更易上手：导出 / 保存附件 / 同步 / 删除按钮只在可用时亮起，「同步所选」突出显示；设置页提示改为分步说明。
  - `MainViewController.updateActions` / `SettingsViewController.updateActions`: 启用状态与动作守卫同一谓词; `sync-selected-folders` `bezelColor = .controlAccentColor`, 不设 ↩ 默认键
- 预览更清晰：主题加粗、附件显示「第几个 / 共几个」，正文切换改名为「本封正文 / 含引用全文」；未同步邮件时预览区给出同步步骤。
  - `preview-mode` 项 `representedObject` = `own` / `full` (AX 稳定标识); 未选中邮件时隐藏 `mail-header`; `placeholder` 按 `libraryCount` 切换
- 状态栏精简为「共 / 找到 N 封」；搜索框悬停显示完整检索语法。
  - 去掉引擎耗时, 保留总耗时 + 语法降级提示; `titlebar` / `@objc` 处理移至 `MainViewController+Results.swift` (type_body_length)

## [0.2.4] - 2026-10-13

### Added

- 同步设置页可删除已同步的文件夹：列表显示每个文件夹已同步的邮件数，「删除已同步」确认后只删除本 App 的数据并回收磁盘空间，Thunderbird 邮件不受影响。
  - 引擎 `remove` 操作: 按 `folder` term 删除 + 移出 manifest + commit, 再合并含删除的 segment 回收存储的 MIME; 不经 `progress.check()`
  - 设置页新增「已同步」列 + `remove-synced-folders`; 来源已不存在的已同步文件夹追加列出, 仅可删除; 删除后取消勾选

## [0.2.3] - 2026-10-13

### Fixed

- 同步设置页底部进度条只在同步时显示：开始时先显示等待动画，有了总数后再按进度前进；平时不再显示一条不动的空进度条。
  - `SettingsViewController`: `sync-progress` 默认 `isHidden`; 同步开始 indeterminate + `startAnimation`, 首个 `total > 0` 切 determinate, 结束隐藏

## [0.2.2] - 2026-10-13

### Added

- 补齐 macOS 标准菜单：关于、服务、隐藏 / 全部显示、全屏幕、窗口与帮助；菜单与系统菜单项统一为中文。
  - `AppDelegate.makeMainMenu` 拆为 App / 文件 / 编辑 / 显示 / 窗口 / 帮助; 设置 `servicesMenu` / `windowsMenu` / `helpMenu`; 帮助打开 GitHub README
  - `developmentRegion` = `zh-Hans` -> 系统注入项 (听写 / 表情与符号 / 服务) 显示中文; `allowsAutomaticWindowTabbing = false` 去除标签页菜单项

## [0.2.1] - 2026-10-13

### Added

- 结果列表支持点击列头排序；⌘F 聚焦搜索，↓ / ↩ 进入结果列表；补齐复制 / 粘贴 / 全选快捷键。
  - `NSSortDescriptor` 原型列排序 (AX 表头可按)；补 Edit 菜单 nil-target 响应链；结果表改单选。

### Fixed

- 转发邮件的被转发内容可被检索；含 `Re:`、网址、撇号或未写完的查询不再报语法错误。
  - `own_text` 遇 Fwd 主题 / 转发分隔线保留全文；`PIPELINE_VERSION` 5 触发一次全量重导。
  - 非字段名 `:` 与 `'` 转义；严格解析失败回退全转义关键词并返回 `relaxed`。
- 同步不再强制结束 Thunderbird；取消 / 空库提示更清晰；切换邮件时附件与预览保持一致；含换行的主题正常显示。
  - 仅 `terminate()` + 30 s 超时报错；`CancellationError` 单独提示；选中按邮件 ID 重定位。
  - 保留的已缓存原文不再计入「正文未下载」；`ownBody` 为空回退完整正文；列表字段控制符 / 首尾空白归一。

### Changed

- 文件夹下拉优先显示文件夹名与数量；同步期间检索 / 预览显示排队状态。
  - `MailEngine.isSyncing`；检索状态写入 state.json 改为防抖后执行；结果排序移出主线程。

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
