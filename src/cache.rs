//! Content-addressed response cache.
//!
//! Keyed on sha256(model ‖ canonical state ‖ canonical questions), stored as an
//! append-only JSONL file. Canonicalising through serde_json (whose maps are
//! sorted) means formatting and key order can't fork the key.
//!
//! The format is deliberately plain text: a cache file doubles as a test fixture
//! you can read, diff and hand-edit.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::sync::{Mutex, MutexGuard, OnceLock};

use serde_json::Value;
use sha2::{Digest, Sha256};

pub fn key(model: &str, state: &Value, questions: &Value) -> String {
    let mut h = Sha256::new();
    h.update(model.as_bytes());
    h.update([0u8]);
    h.update(state.to_string().as_bytes());
    h.update([0u8]);
    h.update(questions.to_string().as_bytes());
    hex::encode(h.finalize())
}

struct Cache {
    entries: HashMap<String, String>,
    loaded_from: Option<String>,
}

fn cache() -> MutexGuard<'static, Cache> {
    static C: OnceLock<Mutex<Cache>> = OnceLock::new();
    C.get_or_init(|| {
        Mutex::new(Cache {
            entries: HashMap::new(),
            loaded_from: None,
        })
    })
    .lock()
    .unwrap()
}

/// Load the file the first time we see a given path (and again if the path changes).
fn ensure_loaded(c: &mut Cache, path: &Path) {
    let p = path.to_string_lossy().to_string();
    if c.loaded_from.as_deref() == Some(p.as_str()) {
        return;
    }
    c.entries.clear();
    if let Ok(f) = File::open(path) {
        for line in BufReader::new(f).lines().map_while(Result::ok) {
            if line.trim().is_empty() {
                continue;
            }
            // A truncated or corrupt line is skipped rather than fatal: a cache
            // is an optimisation, and a half-written tail shouldn't break a query.
            if let Ok(Value::Object(o)) = serde_json::from_str::<Value>(&line)
                && let (Some(Value::String(k)), Some(resp)) = (o.get("k"), o.get("response"))
            {
                c.entries.insert(k.clone(), resp.to_string());
            }
        }
    }
    c.loaded_from = Some(p);
}

pub fn get(path: &Path, k: &str) -> Option<String> {
    let mut c = cache();
    ensure_loaded(&mut c, path);
    c.entries.get(k).cloned()
}

/// Record a response in memory and append it to the file. Also stores the state
/// and questions so a cache file is self-describing and regenerable.
pub fn put(path: &Path, k: &str, model: &str, state: &Value, questions: &Value, response: &str) {
    let mut c = cache();
    ensure_loaded(&mut c, path);
    c.entries.insert(k.to_string(), response.to_string());

    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let line = serde_json::json!({
        "k": k,
        "model": model,
        "state": state,
        "questions": questions,
        "response": serde_json::from_str::<Value>(response).unwrap_or(Value::Null),
    });
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{line}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn key_ignores_formatting_and_field_order() {
        let a: Value = serde_json::from_str(r#"{"b":2,"a":1}"#).unwrap();
        let b: Value = serde_json::from_str("{\n  \"a\": 1,\n  \"b\": 2\n}").unwrap();
        assert_eq!(key("m", &a, &json!({})), key("m", &b, &json!({})));
    }

    #[test]
    fn key_separates_state_from_questions() {
        // Without the separator byte these two would collide.
        let k1 = key("m", &json!("ab"), &json!(""));
        let k2 = key("m", &json!("a"), &json!("b"));
        assert_ne!(k1, k2);
    }

    #[test]
    fn key_tracks_the_model() {
        assert_ne!(
            key("m1", &json!(1), &json!(2)),
            key("m2", &json!(1), &json!(2))
        );
    }

    #[test]
    fn roundtrips_through_a_file() {
        let dir = std::env::temp_dir().join(format!(
            "semantic_profile-cache-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("cache.jsonl");
        let (st, qs) = (json!({"v": "x"}), json!({"q": {"type": "noul"}}));
        let k = key("jev-latest", &st, &qs);

        assert_eq!(get(&path, &k), None);
        put(
            &path,
            &k,
            "jev-latest",
            &st,
            &qs,
            r#"{"answers":{"q":{"noul":0.9}}}"#,
        );
        assert!(get(&path, &k).unwrap().contains("0.9"));

        // Force a reload from disk to prove the file itself carries the entry.
        cache().loaded_from = None;
        assert!(get(&path, &k).unwrap().contains("0.9"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn skips_corrupt_lines() {
        let dir = std::env::temp_dir().join(format!(
            "semantic_profile-corrupt-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cache.jsonl");
        std::fs::write(
            &path,
            "{\"k\":\"aa\",\"response\":{\"ok\":1}}\n{\"k\":\"bb\",\"resp\n",
        )
        .unwrap();
        cache().loaded_from = None;
        assert!(get(&path, "aa").is_some());
        assert!(get(&path, "bb").is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
