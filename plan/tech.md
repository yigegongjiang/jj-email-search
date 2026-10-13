场景：macOS App，大量邮件，高性能全量检索；可跨语言实现。

# sync 方案

> 引用剥离：保留原始邮件；生成派生检索文本时剥离历史回复引用，仅索引当前邮件自身内容。识别不确定时保留内容，避免误删正文。

1. 同步前退出 Thunderbird；仅读取 `.msf` + mbox / maildir，创建只读快照；快照前后校验源文件状态。
2. 手动增量同步；原始数据只读，无服务器连接；源未变化时跳过，失败 / 取消保留已提交数据。
3. 设置窗口选择账户 / 文件夹，支持多账户 / 多文件夹。
4. `.msf` 有效成员决定邮件集合；mbox 按分隔边界流式读取，禁止把 `offlineMsgSize` 当作物理记录长度。
5. 本 App 已缓存且仍在源成员集合内的原文保留；Thunderbird 缓存清理不作为邮件删除。

# 检索方案

- 引擎：[Rust Tantivy](https://github.com/quickwit-oss/tantivy) 统一保存邮件数据 + 索引；暂不引入 SQLite；Swift 通过 C ABI 调用，后台建索引 / 查询。
- 接入：App 解析 MIME / 剥离引用 / 判断增量变化，交付结构化字段；Tantivy 执行分词 / 索引 / 检索。
- 范围：所选账户 / 文件夹条件参与索引查询；完整返回全部命中 items（邮件 ID / 主题 / 发件人 / 日期），无数量截断。
- 字段：主题 / 派生正文建立全文索引；列表字段使用 fast fields；完整原始 MIME 字节仅 STORED，预览 / 附件按需读取，列表查询避免逐封解压 docstore。[存储机制](https://github.com/quickwit-oss/tantivy/blob/main/ARCHITECTURE.md)
- 分词：支持中文 / 英文；英文使用 Tantivy 内置分词器，中文接入现成 Jieba 扩展；Rust 侧注册 / 配置后由 Tantivy 执行，索引与查询规则一致，无需自行实现分词算法。
- 标识：App 管理稳定来源键并建立精确索引；同键替换保证重试幂等，禁止用 Tantivy DocAddress 作为同步标识。
- 提交：批量写入 / 删除；文件夹同步进度随 commit payload 保存，commit 成功才推进进度；记录正文 / 附件可用状态，缺失内容不标记完整。[提交机制](https://github.com/quickwit-oss/tantivy/blob/main/src/indexer/prepared_commit.rs)
- 资源：复用索引句柄，及时释放旧查询快照；索引内存 / 输入队列按字节限制，配置 segment 合并与垃圾回收；元数据缓存有界，异常退出遗留的同步快照在下次同步清理。
- 重建：停写并关闭索引后备份完整数据目录；从旧数据读取原始邮件构建新目录，成功后切换；引用剥离 / 分词 / schema / 引擎版本变更时执行兼容迁移，禁止先清空旧目录。

# macos app layout

- setting 窗口用于 sync thunderbird 数据
- main 窗口用于检索 / 展示邮件列表 / 预览邮件内容
- 保持简洁、高信息密度、紧凑、实用；避免过度设计
