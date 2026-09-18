//! Per-process request accounting and the spend cap.
//!
//! Profiling fans out into many requests, so the failure mode worth engineering
//! against is a query that quietly costs more than expected. The cap is checked
//! before a request is issued and trips a hard SQL error, not a warning.

use std::sync::atomic::{AtomicU64, Ordering};

macro_rules! counters {
    ($($name:ident),* $(,)?) => {
        $(pub static $name: AtomicU64 = AtomicU64::new(0);)*
    };
}

counters!(REQUESTS, CACHE_HITS, CACHE_MISSES, RETRIES, ERRORS, INPUT_TOKENS, OUTPUT_TOKENS);

pub fn bump(c: &AtomicU64, n: u64) {
    c.fetch_add(n, Ordering::Relaxed);
}

/// Reserve one request slot. Returns Err once the cap is reached.
pub fn reserve(max_requests: usize) -> Result<(), String> {
    let prior = REQUESTS.fetch_add(1, Ordering::Relaxed);
    if prior >= max_requests as u64 {
        REQUESTS.fetch_sub(1, Ordering::Relaxed);
        return Err(format!(
            "profiler request budget exhausted: {max_requests} requests already issued this session. \
             Raise it with SELECT profiler_config('max_requests', '<n>'), or reset counters with \
             SELECT profiler_reset_stats()."
        ));
    }
    Ok(())
}

pub fn stats_json() -> String {
    let g = |c: &AtomicU64| c.load(Ordering::Relaxed);
    serde_json::json!({
        "requests": g(&REQUESTS),
        "cache_hits": g(&CACHE_HITS),
        "cache_misses": g(&CACHE_MISSES),
        "retries": g(&RETRIES),
        "errors": g(&ERRORS),
        "input_tokens": g(&INPUT_TOKENS),
        "output_tokens": g(&OUTPUT_TOKENS),
    })
    .to_string()
}

/// The counters are process-global, so any test that asserts on them must hold
/// this lock -- otherwise a parallel test's reset() lands mid-assertion.
#[cfg(test)]
pub fn test_lock() -> std::sync::MutexGuard<'static, ()> {
    static L: std::sync::Mutex<()> = std::sync::Mutex::new(());
    L.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn reset() {
    for c in [
        &REQUESTS,
        &CACHE_HITS,
        &CACHE_MISSES,
        &RETRIES,
        &ERRORS,
        &INPUT_TOKENS,
        &OUTPUT_TOKENS,
    ] {
        c.store(0, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cap_trips_and_does_not_leak_a_slot() {
        let _g = test_lock();
        reset();
        assert!(reserve(2).is_ok());
        assert!(reserve(2).is_ok());
        assert!(reserve(2).is_err());
        // The rejected attempt must not have consumed budget.
        assert_eq!(REQUESTS.load(Ordering::Relaxed), 2);
        reset();
        assert_eq!(REQUESTS.load(Ordering::Relaxed), 0);
    }
}
