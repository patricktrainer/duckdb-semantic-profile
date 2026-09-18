//! TypeSafe System One client: retries, the cache read/write path, and the
//! bounded fan-out used to resolve a whole DuckDB vector at once.

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::budget;
use crate::cache;
use crate::config::{self, Settings};

/// `Hard` aborts the whole query (misconfiguration or budget); `Soft` is recorded
/// per row so one bad row can't sink a long profiling run.
#[derive(Debug, Clone)]
pub enum AskError {
    Hard(String),
    Soft(String),
}

impl AskError {
    pub fn message(&self) -> &str {
        match self {
            AskError::Hard(m) | AskError::Soft(m) => m,
        }
    }
}

const MAX_ATTEMPTS: u32 = 5;

/// Single-flight, keyed on the cache key.
///
/// The SQL layers evaluate sem_columns() more than once, and DuckDB may run
/// those evaluations on different threads. Deduplicating within a batch is not
/// enough: without this, two threads can both miss the cache for the same key and
/// both pay for it. A waiter re-reads the cache after the owner finishes.
mod inflight {
    use std::collections::HashSet;
    use std::sync::{Condvar, Mutex, OnceLock};

    fn state() -> &'static (Mutex<HashSet<String>>, Condvar) {
        static S: OnceLock<(Mutex<HashSet<String>>, Condvar)> = OnceLock::new();
        S.get_or_init(|| (Mutex::new(HashSet::new()), Condvar::new()))
    }

    /// Blocks until no other thread is fetching `key`, then claims it.
    pub fn acquire(key: &str) {
        let (m, cv) = state();
        let mut g = m.lock().unwrap_or_else(|e| e.into_inner());
        while g.contains(key) {
            g = cv.wait(g).unwrap_or_else(|e| e.into_inner());
        }
        g.insert(key.to_string());
    }

    pub fn release(key: &str) {
        let (m, cv) = state();
        m.lock().unwrap_or_else(|e| e.into_inner()).remove(key);
        cv.notify_all();
    }

    /// Releases the claim even if the fetch panics.
    pub struct Guard(pub String);
    impl Drop for Guard {
        fn drop(&mut self) {
            release(&self.0);
        }
    }
}

fn jitter_ms() -> u64 {
    // Enough spread to decorrelate a burst of parallel retries; no rand dependency.
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| (d.subsec_nanos() % 250) as u64)
        .unwrap_or(0)
}

fn backoff(attempt: u32) -> Duration {
    Duration::from_millis(500u64.saturating_mul(1 << attempt) + jitter_ms())
}

fn body(model: &str, state: &Value, questions: &Value) -> Value {
    json!({ "state": state, "model": model, "questions": questions })
}

/// One logical request, including retries. Retries do not consume extra budget.
fn call(s: &Settings, state: &Value, questions: &Value) -> Result<String, AskError> {
    let Some(api_key) = s.api_key.as_ref() else {
        return Err(AskError::Hard(
            "no TypeSafe API key. Set TYPESAFE_API_KEY in the environment, or call \
             SELECT sem_config('api_key', '<key>')."
                .into(),
        ));
    };

    let agent = ureq::builder()
        .timeout(Duration::from_secs(s.timeout_secs))
        .build();
    let payload = body(&s.model, state, questions);
    let mut last = String::new();

    for attempt in 0..MAX_ATTEMPTS {
        if attempt > 0 {
            budget::bump(&budget::RETRIES, 1);
            std::thread::sleep(backoff(attempt - 1));
        }
        match agent
            .post(&s.endpoint)
            .set("Authorization", &format!("Bearer {api_key}"))
            .set("Content-Type", "application/json")
            .send_json(payload.clone())
        {
            Ok(resp) => {
                return resp
                    .into_string()
                    .map_err(|e| AskError::Soft(format!("could not read response body: {e}")));
            }
            // 401/403 are configuration errors and 422 is a malformed question set:
            // retrying any of them just burns time and money.
            Err(ureq::Error::Status(code @ (401 | 403), _)) => {
                return Err(AskError::Hard(format!(
                    "TypeSafe rejected the API key (HTTP {code}). Check TYPESAFE_API_KEY."
                )));
            }
            Err(ureq::Error::Status(422, resp)) => {
                let detail = resp.into_string().unwrap_or_default();
                return Err(AskError::Hard(format!(
                    "TypeSafe rejected the request as invalid (HTTP 422): {}",
                    detail.chars().take(400).collect::<String>()
                )));
            }
            Err(ureq::Error::Status(code, resp)) => {
                let detail = resp.into_string().unwrap_or_default();
                last = format!(
                    "HTTP {code}: {}",
                    detail.chars().take(300).collect::<String>()
                );
                if !matches!(code, 408 | 429 | 500..=599) {
                    break;
                }
            }
            Err(ureq::Error::Transport(t)) => last = format!("transport error: {t}"),
        }
    }
    Err(AskError::Soft(format!(
        "TypeSafe request failed after {MAX_ATTEMPTS} attempts: {last}"
    )))
}

fn record_usage(response: &str) {
    if let Ok(Value::Object(o)) = serde_json::from_str::<Value>(response)
        && let Some(Value::Object(u)) = o.get("usage")
    {
        let n = |k: &str| u.get(k).and_then(Value::as_u64).unwrap_or(0);
        budget::bump(&budget::INPUT_TOKENS, n("input_tokens"));
        budget::bump(&budget::OUTPUT_TOKENS, n("output_tokens"));
    }
}

/// Resolve a batch of (state, questions) pairs.
///
/// Identical pairs within the batch collapse to one request, cached pairs cost
/// nothing, and the remaining misses run across a bounded thread pool.
pub fn resolve(pairs: &[(Value, Value)]) -> Vec<Result<String, AskError>> {
    let s = config::settings();
    let mut out: Vec<Option<Result<String, AskError>>> = vec![None; pairs.len()];

    // Group row indices by cache key so duplicates are fetched once.
    let mut keys: Vec<String> = Vec::with_capacity(pairs.len());
    let mut pending: std::collections::HashMap<String, Vec<usize>> = Default::default();
    for (i, (state, questions)) in pairs.iter().enumerate() {
        let k = cache::key(&s.model, state, questions);
        match cache::get(&s.cache_path, &k) {
            Some(hit) => {
                budget::bump(&budget::CACHE_HITS, 1);
                out[i] = Some(Ok(hit));
            }
            None => pending.entry(k.clone()).or_default().push(i),
        }
        keys.push(k);
    }

    if pending.is_empty() {
        return out.into_iter().map(Option::unwrap).collect();
    }

    if s.offline {
        let msg = format!(
            "semantic_profile is in offline mode and {} request(s) are not in the cache at {}. \
             Unset SEMANTIC_PROFILE_OFFLINE to allow live calls.",
            pending.len(),
            s.cache_path.to_string_lossy()
        );
        for idxs in pending.values() {
            for &i in idxs {
                out[i] = Some(Err(AskError::Hard(msg.clone())));
            }
        }
        return out.into_iter().map(Option::unwrap).collect();
    }

    let work: Vec<(String, usize)> = pending
        .iter()
        .map(|(k, idxs)| (k.clone(), idxs[0]))
        .collect();

    let n_threads = s.concurrency.min(work.len()).max(1);
    let results: Vec<(String, Result<String, AskError>)> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..n_threads)
            .map(|t| {
                let (s, work, pairs) = (&s, &work, pairs);
                scope.spawn(move || {
                    let mut local = Vec::new();
                    // Stride partitioning keeps each thread's share roughly equal
                    // without a shared work queue.
                    for (k, row) in work.iter().skip(t).step_by(n_threads) {
                        let (state, questions) = &pairs[*row];
                        inflight::acquire(k);
                        let _guard = inflight::Guard(k.clone());

                        // Another thread may have fetched this while we waited.
                        if let Some(hit) = cache::get(&s.cache_path, k) {
                            budget::bump(&budget::CACHE_HITS, 1);
                            local.push((k.clone(), Ok(hit)));
                            continue;
                        }
                        budget::bump(&budget::CACHE_MISSES, 1);

                        let r = match budget::reserve(s.max_requests) {
                            Err(e) => Err(AskError::Hard(e)),
                            Ok(()) => call(s, state, questions).inspect(|resp| {
                                record_usage(resp);
                                cache::put(&s.cache_path, k, &s.model, state, questions, resp);
                            }),
                        };
                        if r.is_err() {
                            budget::bump(&budget::ERRORS, 1);
                        }
                        local.push((k.clone(), r));
                    }
                    local
                })
            })
            .collect();
        handles
            .into_iter()
            .flat_map(|h| h.join().unwrap())
            .collect()
    });

    for (k, r) in results {
        for &i in &pending[&k] {
            out[i] = Some(r.clone());
        }
    }
    out.into_iter().map(Option::unwrap).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    #[test]
    fn body_matches_the_documented_request_shape() {
        let b = body(
            "jev-latest",
            &json!("hello"),
            &json!({"q": {"type": "noul"}}),
        );
        assert_eq!(b["model"], "jev-latest");
        assert_eq!(b["state"], "hello");
        assert_eq!(b["questions"]["q"]["type"], "noul");
        assert_eq!(b.as_object().unwrap().len(), 3);
    }

    #[test]
    fn backoff_grows_and_stays_bounded() {
        let d0 = backoff(0).as_millis();
        let d3 = backoff(3).as_millis();
        assert!((500..750).contains(&d0), "{d0}");
        assert!((4000..4250).contains(&d3), "{d3}");
    }

    #[test]
    fn usage_tokens_accumulate() {
        let _g = budget::test_lock();
        budget::reset();
        record_usage(r#"{"usage":{"input_tokens":120,"output_tokens":7}}"#);
        record_usage(r#"{"usage":{"input_tokens":30,"output_tokens":3}}"#);
        assert_eq!(budget::INPUT_TOKENS.load(Ordering::Relaxed), 150);
        assert_eq!(budget::OUTPUT_TOKENS.load(Ordering::Relaxed), 10);
        record_usage("not json"); // must not panic
        budget::reset();
    }

    #[test]
    fn missing_key_is_a_hard_error() {
        let s = Settings {
            api_key: None,
            ..config::settings()
        };
        match call(&s, &json!("x"), &json!({})) {
            Err(AskError::Hard(m)) => assert!(m.contains("TYPESAFE_API_KEY")),
            other => panic!("expected a hard error, got {other:?}"),
        }
    }
}
