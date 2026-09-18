//! duckdb-profiler — semantic profiling of the *values* in a table.
//!
//! `SUMMARIZE` and friends describe the shape of data: types, ranges, quantiles,
//! null and distinct counts. They cannot see that an `email` column holds `n/a`,
//! that `city = 'Test City'` is fake, that a weight column mixes kg and lbs, or
//! that `country = 'US'` contradicts `postal_code = 'SW1A 1AA'` in the same row.
//!
//! Those are judgments about meaning, so this extension makes them first-class
//! SQL using TypeSafe's System One model (Jev), which returns calibrated typed
//! answers rather than free text.
//!
//! The Rust side is deliberately small: one scalar function, `ts_ask`, that owns
//! HTTP, caching, concurrency, retries and the spend cap. Sampling, question
//! construction, the probe catalog, answer parsing and reporting are all SQL
//! macros (`src/sql/`), which keeps them inspectable and editable by the user.

mod budget;
mod cache;
mod client;
mod config;
mod primitives;

use duckdb::{Connection, Result, duckdb_entrypoint_c_api};
use std::error::Error;

/// Registered at load time, in order. Splitting them keeps each file readable and
/// makes a failure point at the layer that broke.
const SQL_LAYERS: &[(&str, &str)] = &[
    ("primitives", include_str!("sql/00_primitives.sql")),
    ("sampling", include_str!("sql/10_sampling.sql")),
    ("discovery", include_str!("sql/20_discovery.sql")),
    ("catalog", include_str!("sql/30_catalog.sql")),
    ("probes", include_str!("sql/40_probes.sql")),
    ("values", include_str!("sql/50_values.sql")),
    ("report", include_str!("sql/60_report.sql")),
];

/// The macro layer as one script, for installing it by hand.
pub fn sql_text() -> String {
    SQL_LAYERS
        .iter()
        .map(|(_, sql)| *sql)
        .collect::<Vec<_>>()
        .join("\n")
}

#[duckdb_entrypoint_c_api]
pub unsafe fn extension_entrypoint(con: Connection) -> Result<(), Box<dyn Error>> {
    con.register_scalar_function::<primitives::TsAsk>("ts_ask")?;
    con.register_scalar_function::<primitives::ProfilerConfig>("profiler_config")?;
    con.register_scalar_function::<primitives::ProfilerSettings>("profiler_settings")?;
    con.register_scalar_function::<primitives::ProfilerStats>("profiler_stats")?;
    con.register_scalar_function::<primitives::ProfilerResetStats>("profiler_reset_stats")?;
    con.register_scalar_function::<primitives::ProfilerSql>("profiler_sql")?;
    con.register_scalar_function::<primitives::ProfilerStatus>("profiler_status")?;

    // The macros are ordinary catalog entries, which needs a writable database.
    // On a read-only one that is not fatal: ts_ask and the rest still work, and
    // profiler_status() explains how to install the macro layer by hand.
    for (name, sql) in SQL_LAYERS {
        if let Err(e) = con.execute_batch(sql) {
            primitives::record_install_failure(name, &e.to_string());
            break;
        }
    }
    Ok(())
}
