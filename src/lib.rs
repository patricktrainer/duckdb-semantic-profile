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

    install_macros(&con);
    Ok(())
}

/// Whether installing the macro layer would write into the user's database file.
///
/// The macros are ordinary catalog entries, so `CREATE MACRO` on a file-backed
/// database persists them into that file. Loading an extension should not modify
/// someone's database, so we install automatically only where nothing persists --
/// an in-memory database, which is also the common case for ad-hoc profiling.
fn install_target(con: &Connection) -> Result<(bool, String), Box<dyn Error>> {
    let row: (String, bool, bool) = con.query_row(
        "SELECT database_name, (path IS NULL OR path = '') AS is_memory, readonly \
         FROM duckdb_databases() WHERE NOT internal LIMIT 1",
        [],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let (name, is_memory, readonly) = row;
    Ok(match (is_memory, readonly) {
        (true, _) => (true, "in-memory database".into()),
        (false, true) => (false, format!("'{name}' is read-only")),
        (false, false) => (false, format!("'{name}' is a database file on disk")),
    })
}

fn install_macros(con: &Connection) {
    // An explicit opt-in for people who do want the macros in their own database.
    let forced = std::env::var("PROFILER_INSTALL_MACROS")
        .map(|v| matches!(v.trim(), "1" | "true" | "yes" | "on"))
        .unwrap_or(false);

    match install_target(con) {
        Ok((auto, why)) if auto || forced => {
            for (name, sql) in SQL_LAYERS {
                if let Err(e) = con.execute_batch(sql) {
                    primitives::record_install_skip(&format!(
                        "the '{name}' SQL layer could not be installed ({why}): {e}"
                    ));
                    return;
                }
            }
        }
        Ok((_, why)) => primitives::record_install_skip(&format!(
            "the macro layer was not installed because {why}, and installing it would \
             write its macros into that catalog. Profile from an in-memory database with \
             this one ATTACHed READ_ONLY, or set PROFILER_INSTALL_MACROS=1 before LOAD to \
             install them here anyway"
        )),
        Err(e) => primitives::record_install_skip(&format!(
            "could not determine whether installing the macro layer would write to disk, \
             so it was skipped: {e}"
        )),
    }
}
