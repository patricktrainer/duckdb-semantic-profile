//! Settings, resolved from `profiler_config()` overrides first, then the environment.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

pub const DEFAULT_ENDPOINT: &str = "https://api.typesafe.ai/v1/systemone";
pub const DEFAULT_MODEL: &str = "jev-latest";

fn overrides() -> &'static Mutex<HashMap<String, String>> {
    static O: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
    O.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Keys accepted by `profiler_config()`, so typos are rejected rather than ignored.
///
/// `api_key` is deliberately NOT here. A key passed through SQL lands in query
/// logs, `duckdb_queries()` and shell history. Supply it as TYPESAFE_API_KEY in
/// the environment, or point `api_key_file` at a file holding it.
///
/// DuckDB Secrets would be the idiomatic home for it, but the C extension API
/// exposes no secrets interface, and secret values read back from SQL are
/// redacted -- so an extension built this way cannot reach them.
pub const KEYS: &[&str] = &[
    "api_key_file",
    "model",
    "endpoint",
    "cache_path",
    "offline",
    "max_requests",
    "concurrency",
    "timeout_secs",
];

pub fn set(key: &str, value: &str) -> Result<(), String> {
    if !KEYS.contains(&key) {
        return Err(format!(
            "unknown profiler setting '{key}'; known settings: {}",
            KEYS.join(", ")
        ));
    }
    overrides()
        .lock()
        .unwrap()
        .insert(key.to_string(), value.to_string());
    Ok(())
}

/// Override, else `PROFILER_<KEY>`, else `TYPESAFE_<KEY>`, else default.
fn get(key: &str) -> Option<String> {
    if let Some(v) = overrides().lock().unwrap().get(key) {
        return Some(v.clone());
    }
    let up = key.to_uppercase();
    std::env::var(format!("PROFILER_{up}"))
        .or_else(|_| std::env::var(format!("TYPESAFE_{up}")))
        .ok()
        .filter(|s| !s.is_empty())
}

fn get_or(key: &str, default: &str) -> String {
    get(key).unwrap_or_else(|| default.to_string())
}

fn get_usize(key: &str, default: usize) -> usize {
    get(key).and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// The key, from the environment or from a file whose path was configured.
/// Never from `profiler_config('api_key', ...)`, which is not a settable key.
fn api_key() -> Option<String> {
    if let Some(k) = get("api_key").filter(|s| !s.trim().is_empty()) {
        return Some(k.trim().to_string());
    }
    let path = get("api_key_file")?;
    std::fs::read_to_string(shellexpand_home(&path))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Expand a leading `~` so `api_key_file` can be written the way people type paths.
fn shellexpand_home(path: &str) -> String {
    match path.strip_prefix("~/") {
        Some(rest) => match std::env::var("HOME") {
            Ok(home) => format!("{home}/{rest}"),
            Err(_) => path.to_string(),
        },
        None => path.to_string(),
    }
}

fn get_bool(key: &str, default: bool) -> bool {
    match get(key) {
        Some(v) => matches!(
            v.trim().to_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        ),
        None => default,
    }
}

#[derive(Clone, Debug)]
pub struct Settings {
    pub api_key: Option<String>,
    pub model: String,
    pub endpoint: String,
    pub cache_path: PathBuf,
    pub offline: bool,
    pub max_requests: usize,
    pub concurrency: usize,
    pub timeout_secs: u64,
}

pub fn settings() -> Settings {
    Settings {
        api_key: api_key(),
        model: get_or("model", DEFAULT_MODEL),
        endpoint: get_or("endpoint", DEFAULT_ENDPOINT),
        cache_path: get("cache_path").map(PathBuf::from).unwrap_or_else(|| {
            let base = std::env::var("HOME").unwrap_or_else(|_| ".".into());
            PathBuf::from(base).join(".cache/duckdb-profiler/cache.jsonl")
        }),
        offline: get_bool("offline", false),
        // A deliberately low default: profiling a wide table by accident should
        // hit a wall, not a bill. Raise it explicitly for real runs.
        max_requests: get_usize("max_requests", 2000),
        concurrency: get_usize("concurrency", 8).clamp(1, 64),
        timeout_secs: get_usize("timeout_secs", 60) as u64,
    }
}

/// Settings as JSON for `profiler_settings()`, with the key redacted.
pub fn settings_json() -> String {
    let s = settings();
    serde_json::json!({
        "api_key": s.api_key.as_ref().map(|k| redact(k)),
        "model": s.model,
        "endpoint": s.endpoint,
        "cache_path": s.cache_path.to_string_lossy(),
        "offline": s.offline,
        "max_requests": s.max_requests,
        "concurrency": s.concurrency,
        "timeout_secs": s.timeout_secs,
    })
    .to_string()
}

fn redact(key: &str) -> String {
    let n = key.chars().count();
    if n <= 8 {
        return "***".into();
    }
    format!("{}…{}", &key[..4], &key[key.len() - 4..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_unknown_keys() {
        assert!(set("model", "jev-latest").is_ok());
        assert!(set("modle", "oops").is_err());
    }

    #[test]
    fn api_key_is_not_settable_through_sql() {
        // Setting it from SQL would put the key in query logs and shell history.
        assert!(set("api_key", "sk-leaked").is_err());
        assert!(set("api_key_file", "/tmp/k").is_ok());
    }

    #[test]
    fn reads_the_key_from_a_file_and_trims_it() {
        let dir = std::env::temp_dir().join(format!("profiler-key-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("key");
        std::fs::write(&f, "  sk-from-a-file\n").unwrap();
        set("api_key_file", f.to_str().unwrap()).unwrap();
        assert_eq!(api_key().as_deref(), Some("sk-from-a-file"));
        // An empty file is no key at all, not an empty one.
        std::fs::write(&f, "\n").unwrap();
        assert_eq!(api_key(), None);
        let _ = std::fs::remove_dir_all(&dir);
        overrides().lock().unwrap().remove("api_key_file");
    }

    #[test]
    fn expands_a_leading_tilde() {
        unsafe { std::env::set_var("HOME", "/home/x") };
        assert_eq!(shellexpand_home("~/.k"), "/home/x/.k");
        assert_eq!(shellexpand_home("/abs/.k"), "/abs/.k");
    }

    #[test]
    fn redacts_all_but_the_edges() {
        assert_eq!(redact("short"), "***");
        assert_eq!(redact("sk-abcdefghijkl"), "sk-a…ijkl");
    }
}
