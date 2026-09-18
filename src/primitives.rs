//! The DuckDB scalar functions. `ts_ask` is the only one that talks to TypeSafe;
//! everything else in this extension is SQL composed over it.

use duckdb::{
    Result,
    core::{DataChunkHandle, Inserter, LogicalTypeId},
    ffi::duckdb_string_t,
    types::DuckString,
    vscalar::{ScalarFunctionSignature, VScalar},
    vtab::arrow::WritableVector,
};
use serde_json::{Value, json};

use crate::client::{self, AskError};
use crate::{budget, config};

/// Read a VARCHAR column out of a chunk as owned strings, with NULLs as None.
fn column(input: &DataChunkHandle, idx: usize) -> Vec<Option<String>> {
    let v = input.flat_vector(idx);
    let raw = unsafe { v.as_slice_with_len::<duckdb_string_t>(input.len()) };
    (0..input.len())
        .map(|i| {
            if v.row_is_null(i as u64) {
                None
            } else {
                let mut s = raw[i];
                Some(DuckString::new(&mut s).as_str().to_string())
            }
        })
        .collect()
}

/// Accept either a JSON document or a bare string for `state`, so callers can pass
/// `to_json(row)` or a plain column value without ceremony.
fn as_state(s: &str) -> Value {
    serde_json::from_str(s).unwrap_or_else(|_| Value::String(s.to_string()))
}

/// `ts_ask(state, questions) -> VARCHAR`
///
/// One request, N questions. Answers are independent of what else is in the
/// request, so batching questions is free accuracy-wise and much cheaper than
/// re-sending state per question.
pub struct TsAsk;

impl VScalar for TsAsk {
    type State = ();

    fn invoke(
        _: &Self::State,
        input: &mut DataChunkHandle,
        output: &mut dyn WritableVector,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let states = column(input, 0);
        let questions = column(input, 1);

        // Rows with a NULL argument are NULL out, and never become requests.
        let mut live: Vec<usize> = Vec::new();
        let mut pairs: Vec<(Value, Value)> = Vec::new();
        let mut bad: Vec<(usize, String)> = Vec::new();
        for i in 0..input.len() {
            let (Some(st), Some(qs)) = (&states[i], &questions[i]) else {
                continue;
            };
            match serde_json::from_str::<Value>(qs) {
                Ok(q) if q.is_object() && !q.as_object().unwrap().is_empty() => {
                    live.push(i);
                    pairs.push((as_state(st), q));
                }
                Ok(_) => bad.push((i, "questions must be a non-empty JSON object".into())),
                Err(e) => bad.push((i, format!("questions is not valid JSON: {e}"))),
            }
        }

        let resolved = client::resolve(&pairs);
        // A misconfiguration or a blown budget should stop the query outright
        // rather than scatter error cells across a million rows.
        if let Some(e) = resolved.iter().find_map(|r| match r {
            Err(e @ AskError::Hard(_)) => Some(e.message().to_string()),
            _ => None,
        }) {
            return Err(e.into());
        }

        // Decide every cell first, then write once. Writing a value into a row
        // that was already marked NULL does not clear the validity bit, so a row
        // must be either set_null or insert -- never both.
        let mut cells: Vec<Option<String>> = vec![None; input.len()];
        for (i, msg) in bad {
            cells[i] = Some(json!({ "error": msg }).to_string());
        }
        for (slot, row) in live.into_iter().enumerate() {
            cells[row] = Some(match &resolved[slot] {
                Ok(body) => body.clone(),
                Err(e) => json!({ "error": e.message() }).to_string(),
            });
        }

        let mut out = output.flat_vector();
        for (i, cell) in cells.iter().enumerate() {
            match cell {
                Some(v) => out.insert(i, v.as_str()),
                None => out.set_null(i),
            }
        }
        Ok(())
    }

    fn signatures() -> Vec<ScalarFunctionSignature> {
        vec![ScalarFunctionSignature::exact(
            vec![LogicalTypeId::Varchar.into(), LogicalTypeId::Varchar.into()],
            LogicalTypeId::Varchar.into(),
        )]
    }
}

/// Emit one VARCHAR value for every row of the chunk.
fn broadcast(
    input: &DataChunkHandle,
    output: &mut dyn WritableVector,
    value: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let out = output.flat_vector();
    for i in 0..input.len() {
        out.insert(i, value);
    }
    Ok(())
}

/// `profiler_config(key, value) -> VARCHAR`
pub struct ProfilerConfig;

impl VScalar for ProfilerConfig {
    type State = ();

    fn invoke(
        _: &Self::State,
        input: &mut DataChunkHandle,
        output: &mut dyn WritableVector,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let keys = column(input, 0);
        let values = column(input, 1);
        for i in 0..input.len() {
            if let (Some(k), Some(v)) = (&keys[i], &values[i]) {
                config::set(k, v)?;
            }
        }
        broadcast(input, output, &config::settings_json())
    }

    fn signatures() -> Vec<ScalarFunctionSignature> {
        vec![ScalarFunctionSignature::exact(
            vec![LogicalTypeId::Varchar.into(), LogicalTypeId::Varchar.into()],
            LogicalTypeId::Varchar.into(),
        )]
    }
}

macro_rules! nullary_varchar {
    ($name:ident, $body:expr) => {
        pub struct $name;
        impl VScalar for $name {
            type State = ();
            fn invoke(
                _: &Self::State,
                input: &mut DataChunkHandle,
                output: &mut dyn WritableVector,
            ) -> Result<(), Box<dyn std::error::Error>> {
                let f: fn() -> String = $body;
                broadcast(input, output, &f())
            }
            fn signatures() -> Vec<ScalarFunctionSignature> {
                vec![ScalarFunctionSignature::exact(
                    vec![],
                    LogicalTypeId::Varchar.into(),
                )]
            }
        }
    };
}

/// Set when the macro layer was not installed at load time, so the reason surfaces
/// as an explanation rather than as "function does not exist".
static INSTALL_SKIP: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

pub fn record_install_skip(reason: &str) {
    *INSTALL_SKIP.lock().unwrap() = Some(format!(
        "{reason}. The scalar functions (ts_ask, profiler_config, ...) work regardless. \
         To install the macro layer on this connection, run the script that \
         profiler_sql() returns."
    ));
}

nullary_varchar!(ProfilerSettings, || config::settings_json());
nullary_varchar!(ProfilerSql, || crate::sql_text());
nullary_varchar!(ProfilerStatus, || {
    match INSTALL_SKIP.lock().unwrap().as_ref() {
        Some(e) => serde_json::json!({ "macros_installed": false, "detail": e }).to_string(),
        None => serde_json::json!({ "macros_installed": true }).to_string(),
    }
});
nullary_varchar!(ProfilerStats, || budget::stats_json());
nullary_varchar!(ProfilerResetStats, || {
    budget::reset();
    budget::stats_json()
});

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_accepts_json_and_bare_text() {
        assert_eq!(as_state(r#"{"a":1}"#)["a"], json!(1));
        assert_eq!(as_state("[1,2]"), json!([1, 2]));
        // Not JSON, so it is the state, verbatim.
        assert_eq!(as_state("hello world"), Value::String("hello world".into()));
        // A bare word that happens to parse as JSON stays a string either way.
        assert_eq!(as_state("\"hi\""), Value::String("hi".into()));
    }
}
