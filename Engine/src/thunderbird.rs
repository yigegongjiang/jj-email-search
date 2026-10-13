use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Folder {
    pub id: String,
    pub account: String,
    pub name: String,
    pub profile: PathBuf,
    pub store: PathBuf,
    pub summary: PathBuf,
    pub imap: bool,
    pub maildir: bool,
}
pub fn discover(root: &Path) -> Result<Vec<Folder>> {
    let ini = fs::read_to_string(root.join("profiles.ini"))
        .context("Cannot read Thunderbird profiles.ini")?;
    let mut profiles = Vec::new();
    let mut section = BTreeMap::<String, String>::new();
    let flush = |section: &mut BTreeMap<String, String>, profiles: &mut Vec<PathBuf>| {
        if let Some(path) = section.get("Path") {
            profiles.push(
                if section.get("IsRelative").map(String::as_str) == Some("0") {
                    PathBuf::from(path)
                } else {
                    root.join(path)
                },
            );
        }
        section.clear();
    };
    for line in ini.lines() {
        if line.starts_with('[') {
            flush(&mut section, &mut profiles);
        } else if let Some((k, v)) = line.split_once('=') {
            section.insert(k.trim().into(), v.trim().into());
        }
    }
    flush(&mut section, &mut profiles);
    let mut folders = Vec::new();
    let mut seen = HashSet::new();
    let pref = regex::Regex::new(r#"user_pref\("(mail\.[^"]+)",\s*(.+)\);"#)?;
    for profile in profiles {
        if !profile.join("prefs.js").is_file() {
            continue;
        }
        let profile = fs::canonicalize(profile)?;
        if !seen.insert(profile.clone()) {
            continue;
        }
        let text = fs::read_to_string(profile.join("prefs.js"))?;
        let mut prefs = BTreeMap::<String, serde_json::Value>::new();
        for cap in pref.captures_iter(&text) {
            if let Ok(value) = serde_json::from_str(&cap[2]) {
                prefs.insert(cap[1].into(), value);
            }
        }
        let get = |k: &str| {
            prefs
                .get(k)
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .to_owned()
        };
        let accounts = get("mail.accountmanager.accounts");
        for account_key in accounts.split(',') {
            let server = get(&format!("mail.account.{account_key}.server"));
            if server.is_empty() {
                continue;
            }
            let prefix = format!("mail.server.{server}.");
            let kind = get(&(prefix.clone() + "type"));
            if !["imap", "pop3", "none"].contains(&kind.as_str())
                || get(&(prefix.clone() + "hostname")) == "smart mailboxes"
            {
                continue;
            }
            let account = get(&(prefix.clone() + "name"));
            let abs = get(&(prefix.clone() + "directory"));
            let rel = get(&(prefix.clone() + "directory-rel"));
            let directory = if let Some(s) = rel.strip_prefix("[ProfD]") {
                profile.join(s)
            } else {
                PathBuf::from(abs)
            };
            if !directory.is_dir() {
                continue;
            }
            let maildir = get(&(prefix + "storeContractID")).contains("maildirstore");
            walk(
                &directory,
                &directory,
                &profile,
                &account,
                kind == "imap",
                maildir,
                &mut folders,
            )?;
        }
    }
    folders.sort_by(|a, b| (&a.account, &a.name).cmp(&(&b.account, &b.name)));
    Ok(folders)
}
fn walk(
    dir: &Path,
    base: &Path,
    profile: &Path,
    account: &str,
    imap: bool,
    maildir: bool,
    out: &mut Vec<Folder>,
) -> Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let ty = entry.file_type()?;
        // No symlink traversal: source folders must be actual files/directories.
        if ty.is_dir() && path.extension().is_some_and(|v| v == "sbd") {
            walk(&path, base, profile, account, imap, maildir, out)?;
        }
        if !ty.is_file() || !path.extension().is_some_and(|v| v == "msf") {
            continue;
        }
        let store = path.with_extension("");
        if !store.exists() {
            continue;
        }
        let relative = store.strip_prefix(base)?.to_string_lossy();
        let name = relative
            .split('/')
            .map(|p| p.trim_end_matches(".sbd"))
            .collect::<Vec<_>>()
            .join(" / ");
        let key = format!("{}\0{}\0{}", profile.display(), account, store.display());
        out.push(Folder {
            id: blake3::hash(key.as_bytes()).to_hex().to_string(),
            account: account.into(),
            name,
            profile: profile.into(),
            store,
            summary: path,
            imap,
            maildir,
        });
    }
    Ok(())
}
pub fn inspect(folder: &Folder) -> Result<serde_json::Value> {
    let db = crate::mork::parse(&fs::read(&folder.summary)?)?;
    let local = db
        .messages
        .values()
        .filter(|r| !folder.imap || number(r, "flags") & 0x80 != 0)
        .count();
    Ok(
        serde_json::json!({"folder":folder.name,"messages":db.messages.len(),"local":local,"uidValidity":db.info.get("UIDValidity"),"metadata":db.info.keys().collect::<Vec<_>>()}),
    )
}
pub fn number(row: &crate::mork::Row, key: &str) -> u64 {
    row.get(key)
        .and_then(|s| u64::from_str_radix(s, 16).ok())
        .unwrap_or(0)
}
pub fn snapshot_file(source: &Path, dest: &Path) -> Result<()> {
    ensure!(source != dest, "Source and destination must differ");
    #[cfg(target_os = "macos")]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        unsafe extern "C" {
            fn clonefile(
                source: *const std::ffi::c_char,
                dest: *const std::ffi::c_char,
                flags: u32,
            ) -> i32;
        }
        let s = CString::new(source.as_os_str().as_bytes())?;
        let d = CString::new(dest.as_os_str().as_bytes())?;
        if unsafe { clonefile(s.as_ptr(), d.as_ptr(), 0) } == 0 {
            return Ok(());
        }
    }
    fs::copy(source, dest).context("Cannot snapshot Thunderbird data")?;
    Ok(())
}
