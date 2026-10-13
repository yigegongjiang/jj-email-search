use anyhow::{Context, Result};
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, Write},
    path::PathBuf,
    sync::Arc,
};
fn main() {
    if let Err(e) = run() {
        eprintln!("{e:#}");
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "discover".into());
    let root = PathBuf::from(std::env::var("HOME")?).join("Library/Thunderbird");
    if command == "discover" {
        println!(
            "{}",
            serde_json::to_string(&jj_email_engine::thunderbird::discover(&root)?)?
        );
        return Ok(());
    }
    if command == "inspect" {
        let name = args.next().context("inspect requires folder name")?;
        let account = args.next().unwrap_or_default();
        for f in jj_email_engine::thunderbird::discover(&root)?
            .iter()
            .filter(|f| f.name.contains(&name) && f.account.contains(&account))
        {
            println!("{}", jj_email_engine::thunderbird::inspect(f)?);
        }
        return Ok(());
    }
    let directory = PathBuf::from(
        args.next()
            .context("Usage: jj-email-engine serve <data-directory>; JSON requests on stdin")?,
    );
    let mut engine = jj_email_engine::engine::Engine::open(&directory, Arc::default())?;
    for line in io::stdin().lock().lines() {
        let line = line?;
        let response: Result<Value> = (|| {
            let request: Value = serde_json::from_str(&line)?;
            if request.get("op").and_then(Value::as_str) == Some("sync") {
                engine.progress.reset();
            }
            jj_email_engine::ffi::dispatch(&mut engine, &request)
        })();
        let value = match response {
            Ok(v) => json!({"ok":true,"data":v}),
            Err(e) => json!({"ok":false,"error":format!("{e:#}")}),
        };
        println!("{value}");
        io::stdout().flush()?;
    }
    Ok(())
}
