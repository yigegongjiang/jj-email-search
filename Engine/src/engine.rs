use crate::thunderbird::{self, Folder};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs::{self, File},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Instant, SystemTime, UNIX_EPOCH},
};
use tantivy::schema::Value as _;
use tantivy::{
    DocAddress, DocId, Index, IndexReader, IndexWriter, Score, SegmentOrdinal, SegmentReader, Term,
    collector::{Collector, SegmentCollector},
    query::{AllQuery, BooleanQuery, Occur, Query, QueryParser, TermQuery},
    schema::*,
};

const VERSION: u32 = 1;
const PIPELINE_VERSION: u32 = 4;
#[derive(Default)]
struct MetadataCache {
    signature: String,
    bytes: usize,
    values: HashMap<(u32, u32), Item>,
}
#[derive(Default)]
pub struct Progress {
    pub current: AtomicU64,
    pub total: AtomicU64,
    pub imported: AtomicU64,
    pub bytes: AtomicU64,
    pub cancelled: AtomicBool,
}
impl Progress {
    pub fn reset(&self) {
        self.current.store(0, Ordering::Relaxed);
        self.total.store(0, Ordering::Relaxed);
        self.imported.store(0, Ordering::Relaxed);
        self.bytes.store(0, Ordering::Relaxed);
        self.cancelled.store(false, Ordering::Relaxed);
    }
    pub fn value(&self) -> Value {
        json!({"current":self.current.load(Ordering::Relaxed),"total":self.total.load(Ordering::Relaxed),"imported":self.imported.load(Ordering::Relaxed),"bytes":self.bytes.load(Ordering::Relaxed)})
    }
    fn check(&self) -> Result<()> {
        ensure!(!self.cancelled.load(Ordering::Relaxed), "操作已取消");
        Ok(())
    }
}
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Manifest {
    pub version: u32,
    pub folders: BTreeMap<String, FolderState>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct FolderState {
    #[serde(default)]
    pub pipeline_version: u32,
    pub folder: Folder,
    pub total: usize,
    pub count: usize,
    pub unavailable: usize,
    pub updated: usize,
    pub synced_at: u64,
    pub fingerprint: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    pub folder: String,
    pub account: String,
    pub folder_name: String,
    pub subject: String,
    pub sender: String,
    pub recipients: String,
    pub date: u64,
    pub flags: u64,
    pub size: u64,
    pub complete: u64,
    pub attachments: u64,
    pub digest: String,
}
#[derive(Clone)]
struct Fields {
    key: Field,
    folder: Field,
    account: Field,
    name: Field,
    subject: Field,
    sender: Field,
    recipients: Field,
    body: Field,
    date: Field,
    flags: Field,
    size: Field,
    complete: Field,
    attachments: Field,
    digest: Field,
    raw: Field,
}
pub struct Engine {
    pub index: Index,
    pub reader: IndexReader,
    fields: Fields,
    pub directory: PathBuf,
    pub progress: Arc<Progress>,
    cache: std::sync::Mutex<MetadataCache>,
}
impl Engine {
    pub fn open(directory: &Path, progress: Arc<Progress>) -> Result<Self> {
        fs::create_dir_all(directory)?;
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
        let mut builder = Schema::builder();
        let exact = STRING | TextOptions::default().set_fast(None);
        let full = TextOptions::default()
            .set_indexing_options(
                TextFieldIndexing::default()
                    .set_tokenizer("mixed")
                    .set_index_option(IndexRecordOption::WithFreqsAndPositions),
            )
            .set_fast(None);
        let body = TextOptions::default().set_indexing_options(
            TextFieldIndexing::default()
                .set_tokenizer("mixed")
                .set_index_option(IndexRecordOption::WithFreqsAndPositions),
        );
        let fields = Fields {
            key: builder.add_text_field("key", exact.clone()),
            folder: builder.add_text_field("folder", exact.clone()),
            account: builder.add_text_field("account", exact.clone()),
            name: builder.add_text_field("folder_name", exact.clone()),
            subject: builder.add_text_field("subject", full.clone()),
            sender: builder.add_text_field("sender", full.clone()),
            recipients: builder.add_text_field("recipients", full),
            body: builder.add_text_field("body", body),
            date: builder.add_u64_field("date", FAST | INDEXED),
            flags: builder.add_u64_field("flags", FAST),
            size: builder.add_u64_field("size", FAST),
            complete: builder.add_u64_field("complete", FAST),
            attachments: builder.add_u64_field("attachments", FAST),
            digest: builder.add_text_field("digest", exact),
            raw: builder.add_bytes_field("raw", STORED),
        };
        let schema = builder.build();
        // Native Tantivy writer locks serialize creation / writes across App instances.
        let index = Index::open_or_create(
            tantivy::directory::MmapDirectory::open(directory)?,
            schema.clone(),
        )?;
        ensure!(
            index.schema() == schema,
            "数据格式版本不兼容；保留现有数据，请先执行兼容迁移"
        );
        index.tokenizers().register(
            "mixed",
            tantivy::tokenizer::TextAnalyzer::builder(crate::tokenizer::MixedTokenizer)
                .filter(tantivy::tokenizer::LowerCaser)
                .build(),
        );
        let reader = index
            .reader_builder()
            .reload_policy(tantivy::ReloadPolicy::Manual)
            .try_into()?;
        let engine = Self {
            index,
            reader,
            fields,
            directory: directory.into(),
            progress,
            cache: std::sync::Mutex::new(MetadataCache::default()),
        };
        let manifest = engine.manifest()?;
        ensure!(
            manifest.version == 0 || manifest.version == VERSION,
            "不兼容的索引版本；现有数据保持不变"
        );
        Ok(engine)
    }
    pub fn manifest(&self) -> Result<Manifest> {
        let meta = self.index.load_metas()?;
        match meta.payload {
            Some(s) => serde_json::from_str(&s).context("Cannot read index synchronization state"),
            None => Ok(Manifest::default()),
        }
    }
    pub fn status(&self) -> Result<Value> {
        let m = self.manifest()?;
        Ok(
            json!({"version":VERSION,"folders":m.folders.values().collect::<Vec<_>>(),"count":self.reader.searcher().num_docs()}),
        )
    }
    pub fn search(&mut self, folder_ids: &[String], text: &str, field: &str) -> Result<Value> {
        let start = Instant::now();
        self.reader.reload()?;
        let f = &self.fields;
        let fields = match field {
            "subject" => vec![f.subject],
            "sender" => vec![f.sender],
            "recipients" => vec![f.recipients],
            "body" => vec![f.body],
            _ => vec![f.subject, f.sender, f.recipients, f.body],
        };
        let query: Box<dyn Query> = if text.trim().is_empty() {
            Box::new(AllQuery)
        } else {
            let mut p = QueryParser::for_index(&self.index, fields);
            p.set_conjunction_by_default();
            p.parse_query(text)
                .context("查询语法错误；支持关键词、\"短语\"、AND / OR / NOT")?
        };
        let query = self.scoped(query, folder_ids);
        let searcher = self.reader.searcher();
        let addresses = searcher.search(&query, &AllIds)?;
        let mut items = self.items(&searcher, &addresses)?;
        items.sort_unstable_by(|a, b| b.date.cmp(&a.date).then_with(|| a.id.cmp(&b.id)));
        Ok(
            json!({"items":items,"elapsed_ms":start.elapsed().as_secs_f64()*1000.0,"count":addresses.len()}),
        )
    }
    fn scoped(&self, query: Box<dyn Query>, folders: &[String]) -> Box<dyn Query> {
        if folders.is_empty() {
            return query;
        }
        let scope = BooleanQuery::new(
            folders
                .iter()
                .map(|s| {
                    (
                        Occur::Should,
                        Box::new(TermQuery::new(
                            Term::from_field_text(self.fields.folder, s),
                            IndexRecordOption::Basic,
                        )) as Box<dyn Query>,
                    )
                })
                .collect(),
        );
        Box::new(BooleanQuery::new(vec![
            (Occur::Must, query),
            (Occur::Must, Box::new(scope)),
        ]))
    }
    fn items(&self, searcher: &tantivy::Searcher, addresses: &[DocAddress]) -> Result<Vec<Item>> {
        let signature = format!(
            "{:?}",
            searcher
                .segment_readers()
                .iter()
                .map(|s| s.segment_id())
                .collect::<Vec<_>>()
        );
        let mut cache = self
            .cache
            .lock()
            .map_err(|_| anyhow::anyhow!("Metadata cache unavailable"))?;
        if cache.signature != signature {
            cache.values.clear();
            cache.bytes = 0;
            cache.signature = signature;
        }
        let mut groups = BTreeMap::<u32, Vec<u32>>::new();
        for a in addresses {
            groups.entry(a.segment_ord).or_default().push(a.doc_id);
        }
        let mut items = Vec::with_capacity(addresses.len());
        for (ord, docs) in groups {
            let segment = searcher.segment_reader(ord);
            let fast = segment.fast_fields();
            let columns: [_; 8] = [
                "key",
                "folder",
                "account",
                "folder_name",
                "subject",
                "sender",
                "recipients",
                "digest",
            ]
            .map(|n| fast.str(n));
            let columns = columns.into_iter().collect::<tantivy::Result<Vec<_>>>()?;
            let numbers = ["date", "flags", "size", "complete", "attachments"].map(|n| fast.u64(n));
            let numbers = numbers.into_iter().collect::<tantivy::Result<Vec<_>>>()?;
            for doc in docs {
                if let Some(item) = cache.values.get(&(ord, doc)) {
                    items.push(item.clone());
                    continue;
                }
                let mut values = Vec::with_capacity(8);
                for c in columns.iter().take(8) {
                    let mut s = String::new();
                    if let Some(c) = c
                        && let Some(n) = c.term_ords(doc).next()
                    {
                        c.ord_to_str(n, &mut s)?;
                    }
                    values.push(s);
                }
                let mut it = values.into_iter();
                let item = Item {
                    id: it.next().unwrap(),
                    folder: it.next().unwrap(),
                    account: it.next().unwrap(),
                    folder_name: it.next().unwrap(),
                    subject: it.next().unwrap(),
                    sender: it.next().unwrap(),
                    recipients: it.next().unwrap(),
                    digest: it.next().unwrap(),
                    date: numbers[0].first(doc).unwrap_or(0),
                    flags: numbers[1].first(doc).unwrap_or(0),
                    size: numbers[2].first(doc).unwrap_or(0),
                    complete: numbers[3].first(doc).unwrap_or(0),
                    attachments: numbers[4].first(doc).unwrap_or(0),
                };
                let estimate = std::mem::size_of::<Item>()
                    + [
                        &item.id,
                        &item.folder,
                        &item.account,
                        &item.folder_name,
                        &item.subject,
                        &item.sender,
                        &item.recipients,
                        &item.digest,
                    ]
                    .iter()
                    .map(|s| s.capacity())
                    .sum::<usize>();
                if cache.bytes + estimate <= 128 * 1024 * 1024 {
                    cache.bytes += estimate;
                    cache.values.insert((ord, doc), item.clone());
                }
                items.push(item);
            }
        }
        Ok(items)
    }
    fn raw(&self, key: &str) -> Result<Vec<u8>> {
        let q = TermQuery::new(
            Term::from_field_text(self.fields.key, key),
            IndexRecordOption::Basic,
        );
        let s = self.reader.searcher();
        let ids = s.search(&q, &AllIds)?;
        ensure!(ids.len() == 1, "邮件标识不存在或不唯一，请重新同步");
        let d: TantivyDocument = s.doc(ids[0])?;
        Ok(d.get_first(self.fields.raw)
            .and_then(|v| v.as_bytes())
            .context("Missing stored MIME")?
            .to_vec())
    }
    pub fn preview(&mut self, key: &str) -> Result<Value> {
        self.reader.reload()?;
        Ok(serde_json::to_value(crate::content::preview(
            &self.raw(key)?,
        )?)?)
    }
    pub fn export(&mut self, key: &str, attachment: Option<u32>, dest: &Path) -> Result<Value> {
        self.reader.reload()?;
        let raw = self.raw(key)?;
        let data = if let Some(i) = attachment {
            let m = mail_parser::MessageParser::default()
                .parse(&raw)
                .context("Cannot parse MIME")?;
            let p = m.attachment(i).context("Attachment missing")?;
            ensure!(
                crate::content::attachment_available(p),
                "附件编码损坏，无法导出"
            );
            p.contents().to_vec()
        } else {
            raw
        };
        let parent = dest.parent().context("Invalid output path")?;
        let canonical = fs::canonicalize(parent)?;
        ensure!(
            !canonical.starts_with(fs::canonicalize(&self.directory)?),
            "禁止导出到 App 数据目录"
        );
        let default_root = PathBuf::from(std::env::var("HOME")?).join("Library/Thunderbird");
        if let Ok(root) = fs::canonicalize(default_root) {
            ensure!(
                !canonical.starts_with(root),
                "Thunderbird 数据保持只读，禁止导出到源目录"
            );
        }
        for state in self.manifest()?.folders.values() {
            ensure!(
                !canonical.starts_with(&state.folder.profile),
                "Thunderbird profile 保持只读"
            );
            if let Some(source) = state.folder.store.parent() {
                ensure!(
                    !canonical.starts_with(source),
                    "Thunderbird 邮件存储保持只读"
                );
            }
        }
        let mut temp = tempfile::NamedTempFile::new_in(parent)?;
        use std::io::Write;
        temp.write_all(&data)?;
        temp.as_file().sync_all()?;
        temp.persist(dest).map_err(|e| e.error)?;
        Ok(json!({"bytes":data.len()}))
    }
    pub fn sync(&mut self, folders: &[Folder]) -> Result<Value> {
        self.progress.check()?;
        ensure!(!folders.is_empty(), "请选择至少一个文件夹");
        ensure!(
            !thunderbird_running(),
            "请先关闭 Thunderbird，再同步本地数据"
        );
        let start = Instant::now();
        let mut writer: IndexWriter<TantivyDocument> = self
            .index
            .writer_with_num_threads(2, 96 * 1024 * 1024)
            .context("索引正在由其他实例写入；稍后重试")?;
        let result = self.sync_inner(&mut writer, folders);
        if result.is_err() {
            let _ = writer.rollback();
        }
        // Joining merges also releases writer locks; no detached work survives a completed operation.
        let merged = writer.wait_merging_threads();
        if result.is_ok() {
            merged?;
        }
        self.reader.reload()?;
        let stats = result?;
        Ok(json!({"folders":stats,"elapsed_ms":start.elapsed().as_secs_f64()*1000.0}))
    }
    fn sync_inner(
        &mut self,
        writer: &mut IndexWriter<TantivyDocument>,
        folders: &[Folder],
    ) -> Result<Vec<FolderState>> {
        // The writer lock is already held: no other sync can own a snapshot here.
        for entry in fs::read_dir(&self.directory)? {
            let entry = entry?;
            if entry.file_type()?.is_dir()
                && entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("sync-snapshot-")
            {
                fs::remove_dir_all(entry.path())?;
            }
        }
        let mut manifest = self.manifest()?;
        manifest.version = VERSION;
        let mut results = Vec::new();
        for folder in folders {
            self.progress.check()?;
            ensure!(
                !thunderbird_running(),
                "Thunderbird 已启动，同步停止，已提交数据保留"
            );
            let fingerprint = fingerprint(folder)?;
            if let Some(old) = manifest.folders.get(&folder.id)
                && old.fingerprint == fingerprint
                && old.pipeline_version == PIPELINE_VERSION
            {
                results.push(FolderState {
                    updated: 0,
                    ..old.clone()
                });
                continue;
            }
            ensure!(
                fs::metadata(&folder.summary)?.len() < 512 * 1024 * 1024,
                "Folder summary exceeds memory budget"
            );
            let snapshot = tempfile::Builder::new()
                .prefix("sync-snapshot-")
                .tempdir_in(&self.directory)?;
            thunderbird::snapshot_file(&folder.summary, &snapshot.path().join("folder.msf"))?;
            if folder.maildir {
                copy_maildir(&folder.store, &snapshot.path().join("store"))?;
            } else {
                thunderbird::snapshot_file(&folder.store, &snapshot.path().join("store"))?;
            }
            ensure!(
                fingerprint == fingerprint_fn(folder)?,
                "Thunderbird 文件在快照期间发生变化，同步已取消"
            );
            ensure!(!thunderbird_running(), "Thunderbird 已启动，同步已取消");
            let db = crate::mork::parse(&fs::read(snapshot.path().join("folder.msf"))?)?;
            let validity = db.info.get("UIDValidity").cloned().unwrap_or_default();
            self.reader.reload()?;
            let searcher = self.reader.searcher();
            let old_ids = searcher.search(
                &self.scoped(Box::new(AllQuery), std::slice::from_ref(&folder.id)),
                &AllIds,
            )?;
            let old: HashMap<_, _> = self
                .items(&searcher, &old_ids)?
                .into_iter()
                .map(|i| (i.id.clone(), i))
                .collect();
            drop(searcher);
            let mut seen = HashSet::new();
            let mut added = 0usize;
            let mut unavailable = 0usize;
            let mut bytes_since_commit = 0usize;
            let mut processed = 0usize;
            let store_path = snapshot.path().join("store");
            let source_file = if folder.maildir {
                None
            } else {
                Some(File::open(&store_path)?)
            };
            self.progress
                .total
                .store(db.messages.len() as u64, Ordering::Relaxed);
            self.progress.current.store(0, Ordering::Relaxed);
            for (uid, row) in &db.messages {
                self.progress.check()?;
                let flags = thunderbird::number(row, "flags");
                processed += 1;
                self.progress
                    .current
                    .store(processed as u64, Ordering::Relaxed);
                if processed.is_multiple_of(128) {
                    ensure!(!thunderbird_running(), "Thunderbird 已启动，同步停止");
                }
                if flags & 8 != 0 || flags & 0x200000 != 0 {
                    continue;
                }
                let id = blake3::hash(format!("{}\0{}\0{:x}", folder.id, validity, uid).as_bytes())
                    .to_hex()
                    .to_string();
                let cached = folder.imap && flags & 0x80 == 0;
                if cached {
                    unavailable += 1;
                    // Cache eviction is not message deletion. Preserve a previously imported body.
                    if !old.contains_key(&id) {
                        continue;
                    }
                }
                let token = row.get("storeToken").cloned().unwrap_or_default();
                let raw_store = if cached {
                    self.raw(&id)?
                } else if folder.maildir {
                    ensure!(
                        !token.is_empty() && !token.contains('/') && !token.contains(".."),
                        "Invalid maildir store token"
                    );
                    fs::read(store_path.join("cur").join(&token))
                        .or_else(|_| fs::read(store_path.join("new").join(&token)))?
                } else {
                    let file = source_file.as_ref().context("本地邮件正文存储为空")?;
                    let offset: u64 = if token.is_empty() {
                        thunderbird::number(row, "msgOffset")
                    } else {
                        token.parse().context("Invalid mbox storeToken")?
                    };
                    let record = read_mbox_record(file, offset)
                        .with_context(|| format!("UID {uid:x}, offset {offset}"))?;
                    normalize_mbox(&record)?
                };
                let message = mail_parser::MessageParser::default()
                    .parse(&raw_store)
                    .context("无法解析本地 MIME 邮件")?;
                if let Some(expected) = row.get("message-id")
                    && !expected.is_empty()
                {
                    ensure!(
                        message
                            .message_id()
                            .is_some_and(|id| id.trim_matches(['<', '>'])
                                == expected.trim_matches(['<', '>'])),
                        "mbox 正文与 msf message-id 不匹配；请在 Thunderbird 修复文件夹"
                    );
                }
                let content_hash = blake3::hash(&raw_store).to_hex().to_string();

                seen.insert(id.clone());
                let separator = raw_store.windows(4).any(|w| w == b"\r\n\r\n")
                    || raw_store.windows(2).any(|w| w == b"\n\n");
                let complete = if separator
                    && flags & 0x400 == 0
                    && !message.parts.iter().any(|p| p.is_encoding_problem)
                    && message
                        .attachments()
                        .all(crate::content::attachment_available)
                {
                    1
                } else {
                    0
                };
                let meta_hash = blake3::hash(
                    format!("{PIPELINE_VERSION}/{content_hash}/{flags}/{complete}").as_bytes(),
                )
                .to_hex()
                .to_string();
                self.progress
                    .bytes
                    .fetch_add(raw_store.len() as u64, Ordering::Relaxed);
                if old.get(&id).is_some_and(|v| v.digest == meta_hash) {
                    continue;
                }
                let own = crate::content::own_text(&message);
                let f = &self.fields;
                let mut doc = TantivyDocument::new();
                for (field, value) in [
                    (f.key, id.as_str()),
                    (f.folder, folder.id.as_str()),
                    (f.account, folder.account.as_str()),
                    (f.name, folder.name.as_str()),
                    (f.subject, message.subject().unwrap_or("(无主题)")),
                    (f.sender, crate::content::addresses(message.from()).as_str()),
                    (
                        f.recipients,
                        crate::content::addresses(message.to()).as_str(),
                    ),
                    (f.body, own.as_str()),
                    (f.digest, meta_hash.as_str()),
                ] {
                    doc.add_text(field, value);
                }
                let date = message
                    .date()
                    .map(|d| d.to_timestamp().max(0) as u64)
                    .unwrap_or_else(|| thunderbird::number(row, "date"));
                for (field, value) in [
                    (f.date, date),
                    (f.flags, flags),
                    (f.size, raw_store.len() as u64),
                    (f.complete, complete),
                    (f.attachments, message.attachment_count() as u64),
                ] {
                    doc.add_u64(field, value);
                }
                doc.add_bytes(f.raw, &raw_store);
                writer.delete_term(Term::from_field_text(f.key, &id));
                writer.add_document(doc)?;
                added += 1;
                bytes_since_commit += raw_store.len();
                self.progress.imported.fetch_add(1, Ordering::Relaxed);
                if bytes_since_commit >= 24 * 1024 * 1024 {
                    self.commit(writer, &manifest)?;
                    bytes_since_commit = 0;
                }
            }
            // Source deletion reconciliation is allowed only after a complete, validated enumeration.
            self.progress.check()?;
            ensure!(
                fingerprint == fingerprint_fn(folder)? && !thunderbird_running(),
                "Thunderbird 源文件发生变化，同步停止"
            );
            for id in old.keys() {
                if !seen.contains(id) {
                    writer.delete_term(Term::from_field_text(self.fields.key, id));
                }
            }
            let state = FolderState {
                pipeline_version: PIPELINE_VERSION,
                folder: folder.clone(),
                total: db.messages.len(),
                count: seen.len(),
                unavailable,
                updated: added,
                synced_at: now(),
                fingerprint,
            };
            manifest.folders.insert(folder.id.clone(), state.clone());
            self.commit(writer, &manifest)?;
            results.push(state);
        }
        Ok(results)
    }
    fn commit(&self, writer: &mut IndexWriter<TantivyDocument>, manifest: &Manifest) -> Result<()> {
        self.progress.check()?;
        let mut c = writer.prepare_commit()?;
        c.set_payload(&serde_json::to_string(manifest)?);
        c.commit()?;
        Ok(())
    }
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn fingerprint(folder: &Folder) -> Result<String> {
    fingerprint_fn(folder)
}
fn fingerprint_fn(folder: &Folder) -> Result<String> {
    use std::os::unix::fs::MetadataExt;
    let mut parts = Vec::new();
    for path in [&folder.summary, &folder.store] {
        let m = fs::metadata(path)?;
        parts.push(format!(
            "{}/{}/{}/{}/{}",
            m.dev(),
            m.ino(),
            m.len(),
            m.mtime(),
            m.mtime_nsec()
        ));
    }
    if folder.maildir {
        for name in ["cur", "new"] {
            let dir = folder.store.join(name);
            if !dir.is_dir() {
                continue;
            }
            for e in fs::read_dir(dir)? {
                let e = e?;
                let m = e.metadata()?;
                parts.push(format!(
                    "{}/{}/{}/{}",
                    e.file_name().to_string_lossy(),
                    m.len(),
                    m.mtime(),
                    m.mtime_nsec()
                ));
            }
        }
        parts.sort();
    }
    Ok(blake3::hash(parts.join("\0").as_bytes())
        .to_hex()
        .to_string())
}
fn copy_maildir(source: &Path, dest: &Path) -> Result<()> {
    fs::create_dir(dest)?;
    for name in ["cur", "new"] {
        let s = source.join(name);
        let d = dest.join(name);
        fs::create_dir(&d)?;
        if s.is_dir() {
            for e in fs::read_dir(s)? {
                let e = e?;
                ensure!(e.file_type()?.is_file(), "Unexpected maildir entry");
                thunderbird::snapshot_file(&e.path(), &d.join(e.file_name()))?;
            }
        }
    }
    Ok(())
}
fn read_mbox_record(file: &File, offset: u64) -> Result<Vec<u8>> {
    use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
    ensure!(offset < file.metadata()?.len(), "Invalid mbox offset");
    let mut file = file.try_clone()?;
    file.seek(SeekFrom::Start(offset))?;
    let mut reader = BufReader::with_capacity(64 * 1024, file.take(512 * 1024 * 1024 + 1));
    let mut record = Vec::new();
    let mut line = Vec::new();
    loop {
        line.clear();
        let n = reader.read_until(b'\n', &mut line)?;
        if n == 0 {
            break;
        }
        if !record.is_empty() && line.starts_with(b"From ") {
            break;
        }
        record.extend_from_slice(&line);
        ensure!(
            record.len() <= 512 * 1024 * 1024,
            "单封邮件超过 512 MiB 安全预算"
        );
    }
    ensure!(record.starts_with(b"From "), "Invalid mbox envelope");
    Ok(record)
}
fn normalize_mbox(data: &[u8]) -> Result<Vec<u8>> {
    ensure!(
        data.starts_with(b"From "),
        "mbox record does not start with envelope"
    );
    let first = data
        .iter()
        .position(|b| *b == b'\n')
        .context("Invalid mbox envelope")?
        + 1;
    let mut out = Vec::with_capacity(data.len() - first);
    let mut headers = true;
    for line in data[first..].split_inclusive(|b| *b == b'\n') {
        if headers {
            let lower = line.iter().map(u8::to_ascii_lowercase).collect::<Vec<_>>();
            if lower.starts_with(b"x-mozilla-status:")
                || lower.starts_with(b"x-mozilla-status2:")
                || lower.starts_with(b"x-mozilla-keys:")
            {
                continue;
            }
            if line == b"\n" || line == b"\r\n" {
                headers = false;
            }
        }
        let mut unquoted = line;
        if !headers && line.starts_with(b">") {
            let n = line.iter().take_while(|b| **b == b'>').count();
            if line[n..].starts_with(b"From ") {
                unquoted = &line[1..];
            }
        }
        out.extend_from_slice(unquoted);
    }
    Ok(out)
}
pub fn thunderbird_running() -> bool {
    std::process::Command::new("/bin/ps")
        .args(["-axo", "comm="])
        .output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout).lines().any(|s| {
                s.contains("Thunderbird.app/Contents/MacOS/") || s.ends_with("/thunderbird")
            })
        })
        .unwrap_or(true)
}
struct AllIds;
struct SegmentIds {
    ordinal: u32,
    ids: Vec<DocId>,
}
impl Collector for AllIds {
    type Fruit = Vec<DocAddress>;
    type Child = SegmentIds;
    fn for_segment(&self, o: SegmentOrdinal, _: &SegmentReader) -> tantivy::Result<SegmentIds> {
        Ok(SegmentIds {
            ordinal: o,
            ids: Vec::new(),
        })
    }
    fn requires_scoring(&self) -> bool {
        false
    }
    fn merge_fruits(&self, segments: Vec<Vec<DocAddress>>) -> tantivy::Result<Vec<DocAddress>> {
        let mut all = Vec::with_capacity(segments.iter().map(Vec::len).sum());
        for s in segments {
            all.extend(s);
        }
        Ok(all)
    }
}
impl SegmentCollector for SegmentIds {
    type Fruit = Vec<DocAddress>;
    fn collect(&mut self, d: DocId, _: Score) {
        self.ids.push(d);
    }
    fn collect_block(&mut self, docs: &[DocId]) {
        self.ids.extend_from_slice(docs);
    }
    fn harvest(self) -> Vec<DocAddress> {
        self.ids
            .into_iter()
            .map(|d| DocAddress::new(self.ordinal, d))
            .collect()
    }
}
