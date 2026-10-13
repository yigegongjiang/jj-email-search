```When Editing
本文档作用: 工程要点 (价值主张 / 核心要求 / 架构约束); MUST NOT 写发布流程 (→ workflow.md) / LLM 约束 (→ AGENTS.md)
遵循 AGENTS.md 文档编写规范
- 只写重点; MUST NOT 写文件结构 / 功能流水账 / 代码可直接看出的细节
- 首行一行价值主张, MUST NOT 带 LLM 提示
- NEVER 写「开发」段 (VibeCoding 不向人类解释 dev 命令)
```

# jj-email-search

macOS 邮件检索应用：只读接入 Thunderbird 已下载邮件，提供本地检索。

## 核心要求（MUST）

- 数据源：Thunderbird 已下载邮件；远端连接与邮件下载由 Thunderbird 完成。
- 本地同步：只读接入 Thunderbird 本机邮件数据及后续变化，更新本 App 索引 / 缓存。
- 本地检索：支持检索规则 / 数据处理能力；具体能力按后续需求确定。
- 数据完整性：检索范围限于本机已下载数据；区分正文 / 附件可用状态，缺失内容不作为完整邮件处理。
- 运行环境：邮件读取、同步、索引与检索完全本地运行；
- 简洁实用高效率: 界面清晰紧凑, 最大化利用屏幕; 实用优先, 美观不作为目标.
- 稳定性: 长期运行稳定, 无崩溃 / 资源泄漏 / 随运行时间增长的性能劣化.
- App 性能: 启动 + 交互快速; 数据读取 / 索引 MUST NOT 阻塞 UI.
- 所有行为 MUST 通过 accessibility 透出自动化节点, 后台可完整操作; 自动化验证 MUST NOT 抢前台 / 鼠标 / 键盘
- UI 默认: 紧凑, 最小留白 + 最大信息密度 (窗口常最大化); 按钮 MUST 保留 bezel, NEVER 无边框纯文字按钮; 新按钮 / 开关统一放标题栏右侧 accessory; 颜色跟随系统色
- 不要过度设计

## 邮件接入约束

- Thunderbird 原始邮件存储为正文 / 附件的数据源；`global-messages-db.sqlite` 可辅助检索，索引记录不保证完整正文 / 附件可用。[Thunderbird 存储说明](https://source-docs.thunderbird.net/en/latest/backend/folder_storage.html)
- 本地同步需处理重复邮件、源文件变化和数据库锁；保持账户 / 文件夹来源，不依赖永久有效的文件偏移。
- 大邮件文件流式处理；本 App 索引 / 缓存与 Thunderbird profile 分离，可从源数据重建。

## 架构

- Swift 6 + AppKit + Rust Tantivy；macOS 14+；纯代码 UI，无 SwiftUI / storyboard / xib。
- 邮件接入 / 索引 / 检索 / 持久化约束 → [技术方案](plan/tech.md)。
- 配置 / 界面状态: 本地 JSON 文件; 缺失键 / null 取默认; 解析失败停写该文件 + 窗口副标题提示
  - `~/.config/jj-email-search/config.jsonc`: 用户选项 + 逐键说明; 手工编辑 (JSON5) 重启生效
  - `~/.config/jj-email-search/config.default.jsonc`: 全部键默认值 + 说明, 启动刷新, 仅供查阅
  - `~/.config/jj-email-search/state.json`: 界面状态 (含窗口位置)
- 配置 / 窗口状态统一由 `ConfigStore` 管理；MUST NOT 用 `UserDefaults` / `setFrameAutosaveName`
- AX 后台可操作: `NSPopUpButton` -> 覆写 cell `isAccessibilitySelectorAllowed` + `setAccessibilityValue` (set value 切换, 无需弹菜单); 仅悬停显示的控件常驻 AX 树; 自绘视图 (单张位图 / 无子视图) -> 虚拟 `NSAccessibilityElement` 子节点

## 使用

- 同步设置：选择本地 Thunderbird 目录，Command 多选文件夹，点击「同步所选」；操作按钮仅可执行时启用；先退出 Thunderbird，再创建只读快照。
- 同步状态列：每个文件夹显示 `未同步` / `✓ 已同步 · 封数 · ⚠ 未下载数 · 同步时间` / `⚠ 来源已不存在`。
- 删除已同步：仅删除本 App 索引 / 邮件副本并回收空间，Thunderbird 不变；来源已不存在的已同步文件夹也列出，仅可删除。
- 主窗口：选择已同步文件夹 / 字段，输入关键词；支持 AND / OR / NOT、双引号短语（整串 `"..."` / `field:"..."` = 原样逐字精确匹配）、`subject:` / `sender:` / `recipients:` / `body:` 前缀；语法不完整时按关键词检索；空查询显示全部邮件；修改 / 清空输入立即取消进行中的检索。
- 键盘：⌘F 聚焦搜索；↓ / ↩ 进入结果列表；点击列头排序。
- 列表完整返回所有命中，默认按日期倒序；预览高亮当前检索的匹配词（遵循字段限定 / NOT），正文定位首个匹配处；可切换本封正文 / 含引用全文；原文与可用附件支持导出，禁止写入源目录。
- 不完整内容以 ⚠ 标记；正文未下载的邮件不从服务器补取，先由 Thunderbird 下载后再同步。
- 数据目录：`~/.config/jj-email-search/mail-index/`；含原文与索引，备份需覆盖完整目录。

## 诊断

- Rust CLI：`Engine/target/release/jj-email-engine discover` / `inspect <folder-name> <account>`；`serve <data-directory>` 接收逐行 JSON 请求，使用与 App 相同的引擎。
- AX 标识：`open-sync-settings` / `source-folders` / `sync-selected-folders` / `remove-synced-folders` / `cancel-sync` / `search-folder` / `search-field` / `mail-search` / `mail-results` / `preview-mode`。
- 表格 AXValue 为从 0 开始的行号，逗号分隔多选；下拉框 AXValue 接受标题或字段 / 文件夹 / 预览模式 (`own` / `full`) 标识。
