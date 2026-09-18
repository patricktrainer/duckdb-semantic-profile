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
pub const KEYS: &[&str] = &[
    "api_key",
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

fn get_bool(key: &str, default: bool) -> bool {
    match get(key) {
        Some(v) => matches!(v.trim().to_lowercase().as_str(), "1" | "true" | "yes" | "on"),
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
        api_key: get("api_key"),
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
    fn redacts_all_but_the_edges() {
        assert_eq!(redact("short"), "***");
        assert_eq!(redact("sk-abcdefghijkl"), "sk-a…ijkl");
    }
}
