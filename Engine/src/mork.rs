//! Read-only Mork subset for Thunderbird folder databases. Unknown/malformed
//! structures fail closed; message membership is read from table 1, not from
//! the set of rows (deleted rows can survive in the store).
use anyhow::{Result, anyhow, bail, ensure};
use std::collections::{BTreeMap, BTreeSet, HashMap};

pub type Row = BTreeMap<String, String>;
#[derive(Default)]
pub struct Database {
    pub messages: BTreeMap<u64, Row>,
    pub info: Row,
}
struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
    columns: HashMap<String, String>,
    atoms: HashMap<String, String>,
    rows: BTreeMap<(String, u64), Row>,
    members: BTreeSet<u64>,
    message_scope: String,
    info_scope: String,
}
pub fn parse(bytes: &[u8]) -> Result<Database> {
    ensure!(
        bytes.starts_with(b"// <!-- <mdb:mork:z"),
        "Unsupported Thunderbird database format"
    );
    ensure!(
        bytes.len() < 512 * 1024 * 1024,
        "Folder database exceeds 512 MiB safety limit"
    );
    let mut p = Parser {
        bytes,
        pos: 0,
        columns: HashMap::new(),
        atoms: HashMap::new(),
        rows: BTreeMap::new(),
        members: BTreeSet::new(),
        message_scope: String::new(),
        info_scope: String::new(),
    };
    let mut transaction: Option<String> = None;
    while p.pos < bytes.len() {
        p.space();
        if p.pos >= bytes.len() {
            break;
        }
        match bytes[p.pos] {
            b'<' => p.dictionary()?,
            b'{' => p.table()?,
            b'[' => {
                p.row("", false, false)?;
            }
            b'@' => {
                let start = p.pos;
                while p.pos < bytes.len() && !matches!(bytes[p.pos], b'\n' | b'\r') {
                    p.pos += 1;
                }
                let marker = std::str::from_utf8(&bytes[start..p.pos])?;
                if let Some(id) = marker
                    .strip_prefix("@$${")
                    .and_then(|s| s.strip_suffix("{@"))
                {
                    ensure!(
                        transaction.is_none() && u64::from_str_radix(id, 16).is_ok(),
                        "Invalid Mork transaction start"
                    );
                    transaction = Some(id.to_owned());
                } else if let Some(id) = marker
                    .strip_prefix("@$$}")
                    .and_then(|s| s.strip_suffix("}@"))
                {
                    ensure!(
                        transaction.as_deref() == Some(id),
                        "Mork transaction mismatch"
                    );
                    transaction = None;
                } else {
                    bail!("Malformed Mork transaction marker");
                }
            }
            _ => bail!("Unknown Mork token at byte {}", p.pos),
        }
    }
    ensure!(
        transaction.is_none(),
        "Uncommitted Mork transaction; repair folder in Thunderbird"
    );
    ensure!(
        !p.message_scope.is_empty() && !p.info_scope.is_empty(),
        "Missing Thunderbird message/folder scopes: message={}, info={}, columns={:?}",
        p.message_scope,
        p.info_scope,
        p.columns
            .iter()
            .filter(|(_, v)| v.contains("scope"))
            .collect::<Vec<_>>()
    );
    let info = p
        .rows
        .remove(&(p.info_scope, 1))
        .ok_or_else(|| anyhow!("Missing Thunderbird folder info"))?;
    let mut messages = BTreeMap::new();
    for id in p.members {
        let row = p
            .rows
            .remove(&(p.message_scope.clone(), id))
            .ok_or_else(|| anyhow!("Missing message row {id:x}"))?;
        messages.insert(id, row);
    }
    if let Some(n) = info
        .get("numMsgs")
        .and_then(|s| u64::from_str_radix(s, 16).ok())
    {
        ensure!(
            n == messages.len() as u64,
            "Mork membership mismatch: expected {n}, parsed {}",
            messages.len()
        );
    }
    Ok(Database { messages, info })
}
impl Parser<'_> {
    fn space(&mut self) {
        loop {
            while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_whitespace() {
                self.pos += 1;
            }
            if self.bytes.get(self.pos..self.pos + 2) == Some(b"//") {
                while self.pos < self.bytes.len() && !matches!(self.bytes[self.pos], b'\n' | b'\r')
                {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }
    fn cell(&mut self) -> Result<Vec<u8>> {
        ensure!(
            self.bytes.get(self.pos) == Some(&b'('),
            "Expected Mork cell"
        );
        self.pos += 1;
        let mut out = Vec::new();
        while self.pos < self.bytes.len() {
            let c = self.bytes[self.pos];
            self.pos += 1;
            if c == b')' {
                return Ok(out);
            }
            if c == b'\\' {
                let next = *self
                    .bytes
                    .get(self.pos)
                    .ok_or_else(|| anyhow!("Truncated Mork escape"))?;
                self.pos += 1;
                if next == b'\r' {
                    if self.bytes.get(self.pos) == Some(&b'\n') {
                        self.pos += 1;
                    }
                    continue;
                }
                if next == b'\n' {
                    continue;
                }
                // Preserve escaped $ so that it is not interpreted as a hex escape.
                if next == b'$' {
                    out.push(b'\\');
                }
                out.push(next);
            } else {
                out.push(c);
            }
        }
        bail!("Unterminated Mork cell")
    }
    fn dictionary(&mut self) -> Result<()> {
        self.pos += 1;
        let mut key_dict = false;
        let mut pairs = Vec::new();
        loop {
            self.space();
            match self.bytes.get(self.pos) {
                Some(b'>') => {
                    self.pos += 1;
                    break;
                }
                Some(b'<') => {
                    self.pos += 1;
                    self.space();
                    let directive = self.cell()?;
                    ensure!(directive == b"a=c", "Unknown Mork dictionary directive");
                    self.space();
                    ensure!(
                        self.bytes.get(self.pos) == Some(&b'>'),
                        "Invalid dictionary directive"
                    );
                    self.pos += 1;
                    key_dict = true;
                }
                Some(b'(') => {
                    let c = self.cell()?;
                    if c == b"a=c" {
                        key_dict = true;
                    } else {
                        let eq = c
                            .iter()
                            .position(|c| *c == b'=')
                            .ok_or_else(|| anyhow!("Invalid Mork atom"))?;
                        pairs.push((
                            String::from_utf8_lossy(&c[..eq])
                                .trim()
                                .to_ascii_uppercase(),
                            decode(&c[eq + 1..]),
                        ));
                    }
                }
                _ => bail!("Malformed Mork dictionary at {}", self.pos),
            }
        }
        for (k, v) in pairs {
            if key_dict {
                if v == "ns:msg:db:row:scope:msgs:all" {
                    self.message_scope = k.clone();
                }
                if v == "ns:msg:db:row:scope:dbfolderinfo:all" {
                    self.info_scope = k.clone();
                }
                self.columns.insert(k, v);
            } else {
                self.atoms.insert(k, v);
            }
        }
        Ok(())
    }
    fn identifier(&mut self) -> String {
        let start = self.pos;
        while self.pos < self.bytes.len()
            && !self.bytes[self.pos].is_ascii_whitespace()
            && !b"{}[]()<>".contains(&self.bytes[self.pos])
        {
            self.pos += 1;
        }
        String::from_utf8_lossy(&self.bytes[start..self.pos]).into_owned()
    }
    fn table(&mut self) -> Result<()> {
        self.pos += 1;
        self.space();
        let header = self.identifier();
        let (id, scope) = split_id(&header, "");
        let main = id == Some(1) && scope == self.message_scope;
        let mut pending_remove = false;
        loop {
            self.space();
            match self.bytes.get(self.pos) {
                Some(b'}') => {
                    self.pos += 1;
                    break;
                }
                Some(b'{') => self.table()?,
                Some(b'[') => {
                    self.row(&scope, main, pending_remove)?;
                    pending_remove = false;
                }
                Some(b'(') => {
                    self.cell()?;
                }
                Some(b'<') => self.dictionary()?,
                Some(_) => {
                    let token = self.identifier();
                    ensure!(!token.is_empty(), "Invalid table token");
                    if token == "-" {
                        pending_remove = true;
                        continue;
                    }
                    if token == "+" {
                        pending_remove = false;
                        continue;
                    }
                    let remove = token.starts_with('-');
                    let (id, s) = split_id(token.trim_start_matches(['-', '+']), &scope);
                    if main && s == self.message_scope {
                        if let Some(id) = id {
                            if remove {
                                self.members.remove(&id);
                            } else {
                                self.members.insert(id);
                            }
                        } else {
                            bail!("Malformed message table member {token:?} at {}", self.pos);
                        }
                    }
                }
                None => bail!("Unterminated Mork table"),
            }
        }
        Ok(())
    }
    fn row(&mut self, default_scope: &str, main: bool, remove: bool) -> Result<()> {
        self.pos += 1;
        self.space();
        let header = self.identifier();
        let clear = header.starts_with('-');
        let (id, scope) = split_id(header.trim_start_matches(['-', '+']), default_scope);
        let id = id.ok_or_else(|| anyhow!("Invalid Mork row ID"))?;
        let relevant = scope == self.message_scope || scope == self.info_scope;
        let key = (scope.clone(), id);
        if clear && relevant {
            self.rows.remove(&key);
        }
        if main && scope == self.message_scope {
            if remove {
                self.members.remove(&id);
            } else {
                self.members.insert(id);
            }
        }
        let mut cells = Vec::new();
        loop {
            self.space();
            match self.bytes.get(self.pos) {
                Some(b']') => {
                    self.pos += 1;
                    break;
                }
                Some(b'(') => cells.push(self.cell()?),
                None => bail!("Unterminated Mork row"),
                _ => bail!("Invalid Mork row contents at {}", self.pos),
            }
        }
        if relevant {
            let mut values = Vec::new();
            for c in cells {
                if c.first() != Some(&b'^') {
                    continue;
                }
                let op = c[1..]
                    .iter()
                    .position(|b| *b == b'=' || *b == b'^')
                    .map(|n| n + 1)
                    .ok_or_else(|| anyhow!("Invalid Mork cell operator"))?;
                let column = String::from_utf8_lossy(&c[1..op])
                    .trim()
                    .to_ascii_uppercase();
                let name = self
                    .columns
                    .get(&column)
                    .ok_or_else(|| anyhow!("Unknown Mork column"))?
                    .clone();
                let value = if c[op] == b'^' {
                    self.atoms
                        .get(
                            &String::from_utf8_lossy(&c[op + 1..])
                                .trim()
                                .to_ascii_uppercase(),
                        )
                        .ok_or_else(|| anyhow!("Missing Mork value reference"))?
                        .clone()
                } else {
                    decode(&c[op + 1..])
                };
                values.push((name, value));
            }
            self.rows.entry(key).or_default().extend(values);
        }
        Ok(())
    }
}
fn split_id(s: &str, default: &str) -> (Option<u64>, String) {
    let (id, scope) = s.split_once(':').unwrap_or((s, default));
    (
        u64::from_str_radix(id.trim(), 16).ok(),
        scope.trim_start_matches('^').to_ascii_uppercase(),
    )
}
fn decode(bytes: &[u8]) -> String {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && bytes.get(i + 1) == Some(&b'$') {
            out.push(b'$');
            i += 2;
        } else if bytes[i] == b'$' && i + 2 < bytes.len() {
            if let Ok(s) = std::str::from_utf8(&bytes[i + 1..i + 3])
                && let Ok(c) = u8::from_str_radix(s, 16)
            {
                if c != 0 {
                    out.push(c);
                }
                i += 3;
                continue;
            }
            out.push(bytes[i]);
            i += 1;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    match String::from_utf8(out) {
        Ok(s) => s,
        Err(e) => e.into_bytes().into_iter().map(char::from).collect(),
    }
}
