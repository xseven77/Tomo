use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetryEvent {
    pub id: String,
    pub timestamp: i64,             // UTC milliseconds
    pub agent: String,              // e.g. "Hermes", "Pi", "Cursor", "Cline", "Unknown"
    pub ingress_protocol: String,   // "openai-chat", "openai-responses", "anthropic-messages", "passthrough"
    pub provider: String,           // "openai", "anthropic", "google", "deepseek", "opencode", etc.
    pub account: String,            // Account display name / label
    pub model_alias: String,        // Requested alias or model name
    pub target_model: String,       // Resolved upstream target model
    pub input_tokens: Option<i64>,  // Input / prompt tokens
    pub output_tokens: Option<i64>, // Output / completion tokens
    pub cache_read_tokens: Option<i64>,
    pub cache_write_tokens: Option<i64>,
    pub total_tokens: Option<i64>,
    pub latency_ms: i64,
    pub ttft_ms: i64,
    pub status_code: i32,
    pub status: String,                 // "success", "error"
    pub error_category: Option<String>, // "auth_error", "rate_limit", "upstream_error", "client_cancelled", "invalid_request", "network_error"
    pub fidelity: String, // "actual", "provider_reported", "estimated", "unavailable"
    pub is_stream: bool,
    pub tool_calls_count: i32,
    pub estimated_cost: Option<f64>,
    pub currency: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetryQueryFilter {
    pub from: Option<i64>,
    pub to: Option<i64>,
    pub tz_offset_minutes: Option<i32>,
    pub agent: Option<String>,
    pub provider: Option<String>,
    pub account: Option<String>,
    pub model: Option<String>,
    pub status: Option<String>,
    pub fidelity: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetrySummary {
    pub from: i64,
    pub to: i64,
    pub timezone_offset_minutes: i32,
    pub collection_started_at: Option<i64>,
    pub total_requests: i64,
    pub successful_requests: i64,
    pub failed_requests: i64,
    pub success_rate: f64,
    pub total_tokens: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_write_tokens: i64,
    pub actual_tokens_ratio: f64,
    pub estimated_tokens_ratio: f64,
    pub avg_latency_ms: f64,
    pub p50_ttft_ms: i64,
    pub p95_ttft_ms: i64,
    pub total_tool_calls: i64,
    pub estimated_cost: f64,
    pub currency: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeseriesBucket {
    pub bucket_start: i64,
    pub bucket_label: String,
    pub total_tokens: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub actual_ratio: f64,
    pub requests_count: i64,
    pub success_count: i64,
    pub error_count: i64,
    pub avg_latency_ms: f64,
    pub p50_ttft_ms: i64,
    pub p95_ttft_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimeseriesResponse {
    pub interval: String,
    pub metric: String,
    pub buckets: Vec<TimeseriesBucket>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BreakdownItem {
    pub name: String,
    pub requests_count: i64,
    pub total_tokens: i64,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub error_count: i64,
    pub avg_latency_ms: f64,
    pub avg_ttft_ms: f64,
    pub percentage: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BreakdownResponse {
    pub dimension: String,
    pub items: Vec<BreakdownItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestsListResponse {
    pub total: i64,
    pub limit: usize,
    pub offset: usize,
    pub items: Vec<TelemetryEvent>,
}

#[allow(dead_code)]
enum WriterCommand {
    Record(TelemetryEvent),
    Batch(Vec<TelemetryEvent>),
    Flush(Sender<()>),
    Shutdown,
}

#[derive(Clone)]
pub struct TelemetryStore {
    sender: Sender<WriterCommand>,
    db_conn: Arc<Mutex<Connection>>,
    #[allow(dead_code)]
    db_path: Option<PathBuf>,
}

impl TelemetryStore {
    pub fn new_in_memory() -> Result<Self, rusqlite::Error> {
        let conn = Connection::open_in_memory()?;
        Self::init_db(&conn)?;
        let conn_arc = Arc::new(Mutex::new(conn));

        let (tx, rx) = channel::<WriterCommand>();
        let conn_clone = conn_arc.clone();

        thread::spawn(move || {
            Self::writer_loop(rx, conn_clone);
        });

        Ok(Self {
            sender: tx,
            db_conn: conn_arc,
            db_path: None,
        })
    }

    pub fn new<P: AsRef<Path>>(path: P) -> Result<Self, rusqlite::Error> {
        let path_buf = path.as_ref().to_path_buf();
        if let Some(parent) = path_buf.parent() {
            let _ = std::fs::create_dir_all(parent);
        }

        let conn = Connection::open(&path_buf)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        Self::init_db(&conn)?;
        let conn_arc = Arc::new(Mutex::new(conn));

        let (tx, rx) = channel::<WriterCommand>();
        let conn_clone = conn_arc.clone();

        thread::spawn(move || {
            Self::writer_loop(rx, conn_clone);
        });

        Ok(Self {
            sender: tx,
            db_conn: conn_arc,
            db_path: Some(path_buf),
        })
    }

    pub fn default_db_path() -> PathBuf {
        if let Ok(home) = std::env::var("HOME") {
            PathBuf::from(home)
                .join("Library")
                .join("Application Support")
                .join("Tomo")
                .join("gateway-telemetry.sqlite")
        } else {
            PathBuf::from("gateway-telemetry.sqlite")
        }
    }

    fn init_db(conn: &Connection) -> Result<(), rusqlite::Error> {
        conn.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS request_events (
                id TEXT PRIMARY KEY,
                timestamp INTEGER NOT NULL,
                agent TEXT NOT NULL,
                ingress_protocol TEXT NOT NULL,
                provider TEXT NOT NULL,
                account TEXT NOT NULL,
                model_alias TEXT NOT NULL,
                target_model TEXT NOT NULL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                total_tokens INTEGER,
                latency_ms INTEGER NOT NULL,
                ttft_ms INTEGER NOT NULL,
                status_code INTEGER NOT NULL,
                status TEXT NOT NULL,
                error_category TEXT,
                fidelity TEXT NOT NULL,
                is_stream INTEGER NOT NULL,
                tool_calls_count INTEGER NOT NULL DEFAULT 0,
                estimated_cost REAL,
                currency TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_req_timestamp ON request_events(timestamp);
            CREATE INDEX IF NOT EXISTS idx_req_agent ON request_events(agent);
            CREATE INDEX IF NOT EXISTS idx_req_provider ON request_events(provider);
            CREATE INDEX IF NOT EXISTS idx_req_account ON request_events(account);
            CREATE INDEX IF NOT EXISTS idx_req_target_model ON request_events(target_model);
            CREATE INDEX IF NOT EXISTS idx_req_status ON request_events(status);
            CREATE INDEX IF NOT EXISTS idx_req_fidelity ON request_events(fidelity);

            CREATE TABLE IF NOT EXISTS telemetry_settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            "#,
        )?;
        Ok(())
    }

    fn writer_loop(rx: Receiver<WriterCommand>, conn: Arc<Mutex<Connection>>) {
        let mut buffer = Vec::with_capacity(32);
        loop {
            match rx.recv_timeout(Duration::from_millis(50)) {
                Ok(WriterCommand::Record(event)) => {
                    buffer.push(event);
                    if buffer.len() >= 32 {
                        Self::flush_buffer(&mut buffer, &conn);
                    }
                }
                Ok(WriterCommand::Batch(events)) => {
                    buffer.extend(events);
                    if buffer.len() >= 32 {
                        Self::flush_buffer(&mut buffer, &conn);
                    }
                }
                Ok(WriterCommand::Flush(ack_tx)) => {
                    Self::flush_buffer(&mut buffer, &conn);
                    let _ = ack_tx.send(());
                }
                Ok(WriterCommand::Shutdown) => {
                    Self::flush_buffer(&mut buffer, &conn);
                    break;
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if !buffer.is_empty() {
                        Self::flush_buffer(&mut buffer, &conn);
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    Self::flush_buffer(&mut buffer, &conn);
                    break;
                }
            }
        }
    }

    fn flush_buffer(buffer: &mut Vec<TelemetryEvent>, conn: &Arc<Mutex<Connection>>) {
        if buffer.is_empty() {
            return;
        }

        if let Ok(mut c) = conn.lock() {
            if let Ok(tx) = c.transaction() {
                for ev in buffer.drain(..) {
                    let _ = tx.execute(
                        r#"
                        INSERT OR REPLACE INTO request_events (
                            id, timestamp, agent, ingress_protocol, provider, account,
                            model_alias, target_model, input_tokens, output_tokens,
                            cache_read_tokens, cache_write_tokens, total_tokens,
                            latency_ms, ttft_ms, status_code, status, error_category,
                            fidelity, is_stream, tool_calls_count, estimated_cost, currency
                        ) VALUES (
                            ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
                            ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18,
                            ?19, ?20, ?21, ?22, ?23
                        )
                        "#,
                        params![
                            ev.id,
                            ev.timestamp,
                            ev.agent,
                            ev.ingress_protocol,
                            ev.provider,
                            ev.account,
                            ev.model_alias,
                            ev.target_model,
                            ev.input_tokens,
                            ev.output_tokens,
                            ev.cache_read_tokens,
                            ev.cache_write_tokens,
                            ev.total_tokens,
                            ev.latency_ms,
                            ev.ttft_ms,
                            ev.status_code,
                            ev.status,
                            ev.error_category,
                            ev.fidelity,
                            if ev.is_stream { 1 } else { 0 },
                            ev.tool_calls_count,
                            ev.estimated_cost,
                            ev.currency,
                        ],
                    );
                }
                let _ = tx.commit();
            }
        }
    }

    /// Record a telemetry event asynchronously without blocking caller.
    pub fn record_event(&self, event: TelemetryEvent) {
        let _ = self.sender.send(WriterCommand::Record(event));
    }

    /// Flush pending writes to disk synchronously (used in tests or shutdown).
    pub fn flush(&self) {
        let (tx, rx) = channel();
        if self.sender.send(WriterCommand::Flush(tx)).is_ok() {
            let _ = rx.recv_timeout(Duration::from_secs(2));
        }
    }

    // ==========================================
    // Query Methods
    // ==========================================

    fn build_where_clause(filter: &TelemetryQueryFilter) -> (String, Vec<rusqlite::types::Value>) {
        let mut conditions = Vec::new();
        let mut params = Vec::new();

        if let Some(from) = filter.from {
            conditions.push("timestamp >= ?".to_string());
            params.push(rusqlite::types::Value::Integer(from));
        }
        if let Some(to) = filter.to {
            conditions.push("timestamp <= ?".to_string());
            params.push(rusqlite::types::Value::Integer(to));
        }
        if let Some(ref agent) = filter.agent {
            if !agent.is_empty() && agent != "all" {
                conditions.push("agent = ?".to_string());
                params.push(rusqlite::types::Value::Text(agent.clone()));
            }
        }
        if let Some(ref provider) = filter.provider {
            if !provider.is_empty() && provider != "all" {
                conditions.push("provider = ?".to_string());
                params.push(rusqlite::types::Value::Text(provider.clone()));
            }
        }
        if let Some(ref account) = filter.account {
            if !account.is_empty() && account != "all" {
                conditions.push("(account = ? OR account LIKE ?)".to_string());
                params.push(rusqlite::types::Value::Text(account.clone()));
                params.push(rusqlite::types::Value::Text(format!("%{account}%")));
            }
        }
        if let Some(ref model) = filter.model {
            if !model.is_empty() && model != "all" {
                conditions.push("(target_model = ? OR model_alias = ?)".to_string());
                params.push(rusqlite::types::Value::Text(model.clone()));
                params.push(rusqlite::types::Value::Text(model.clone()));
            }
        }
        if let Some(ref status) = filter.status {
            if !status.is_empty() && status != "all" {
                conditions.push("status = ?".to_string());
                params.push(rusqlite::types::Value::Text(status.clone()));
            }
        }
        if let Some(ref fidelity) = filter.fidelity {
            if !fidelity.is_empty() && fidelity != "all" {
                conditions.push("fidelity = ?".to_string());
                params.push(rusqlite::types::Value::Text(fidelity.clone()));
            }
        }

        let sql = if conditions.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", conditions.join(" AND "))
        };

        (sql, params)
    }

    pub fn query_summary(
        &self,
        filter: &TelemetryQueryFilter,
    ) -> Result<TelemetrySummary, rusqlite::Error> {
        self.flush();
        let conn = self
            .db_conn
            .lock()
            .map_err(|_| rusqlite::Error::InvalidQuery)?;

        let (where_clause, params_vec) = Self::build_where_clause(filter);

        let sql = format!(
            r#"
            SELECT
                COUNT(*) as total_requests,
                COALESCE(SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END), 0) as successful_requests,
                COALESCE(SUM(CASE WHEN status != 'success' THEN 1 ELSE 0 END), 0) as failed_requests,
                COALESCE(SUM(total_tokens), 0) as total_tokens,
                COALESCE(SUM(input_tokens), 0) as input_tokens,
                COALESCE(SUM(output_tokens), 0) as output_tokens,
                COALESCE(SUM(cache_read_tokens), 0) as cache_read_tokens,
                COALESCE(SUM(cache_write_tokens), 0) as cache_write_tokens,
                COALESCE(SUM(CASE WHEN fidelity = 'actual' THEN COALESCE(total_tokens, 0) ELSE 0 END), 0) as actual_tokens,
                COALESCE(SUM(CASE WHEN fidelity = 'estimated' THEN COALESCE(total_tokens, 0) ELSE 0 END), 0) as estimated_tokens,
                COALESCE(AVG(latency_ms), 0.0) as avg_latency,
                COALESCE(SUM(tool_calls_count), 0) as total_tool_calls,
                COALESCE(SUM(estimated_cost), 0.0) as total_cost
            FROM request_events
            {}
            "#,
            where_clause
        );

        let params_refs: Vec<&dyn rusqlite::ToSql> = params_vec
            .iter()
            .map(|v| v as &dyn rusqlite::ToSql)
            .collect();

        let mut stmt = conn.prepare(&sql)?;
        let row = stmt.query_row(params_refs.as_slice(), |row| {
            let total_requests: i64 = row.get(0)?;
            let successful_requests: i64 = row.get(1)?;
            let failed_requests: i64 = row.get(2)?;
            let total_tokens: i64 = row.get(3)?;
            let input_tokens: i64 = row.get(4)?;
            let output_tokens: i64 = row.get(5)?;
            let cache_read_tokens: i64 = row.get(6)?;
            let cache_write_tokens: i64 = row.get(7)?;
            let actual_tokens: i64 = row.get(8)?;
            let estimated_tokens: i64 = row.get(9)?;
            let avg_latency: f64 = row.get(10)?;
            let total_tool_calls: i64 = row.get(11)?;
            let total_cost: f64 = row.get(12)?;

            Ok((
                total_requests,
                successful_requests,
                failed_requests,
                total_tokens,
                input_tokens,
                output_tokens,
                cache_read_tokens,
                cache_write_tokens,
                actual_tokens,
                estimated_tokens,
                avg_latency,
                total_tool_calls,
                total_cost,
            ))
        })?;

        // Calculate P50 and P95 TTFT
        let ttft_sql = format!(
            "SELECT ttft_ms FROM request_events {} ORDER BY ttft_ms ASC",
            where_clause
        );
        let mut ttft_stmt = conn.prepare(&ttft_sql)?;
        let ttfts: Vec<i64> = ttft_stmt
            .query_map(params_refs.as_slice(), |r| r.get(0))?
            .filter_map(|r| r.ok())
            .collect();

        let (p50_ttft, p95_ttft) = if ttfts.is_empty() {
            (0, 0)
        } else {
            let p50_idx = ((ttfts.len() as f64) * 0.50).floor() as usize;
            let p95_idx = ((ttfts.len() as f64) * 0.95).floor() as usize;
            let p50 = ttfts[p50_idx.min(ttfts.len() - 1)];
            let p95 = ttfts[p95_idx.min(ttfts.len() - 1)];
            (p50, p95)
        };

        // Earliest timestamp recorded in DB
        let collection_started_at: Option<i64> = conn
            .query_row("SELECT MIN(timestamp) FROM request_events", [], |r| {
                r.get::<_, Option<i64>>(0)
            })
            .optional()?
            .flatten();

        let total_reqs = row.0;
        let success_rate = if total_reqs > 0 {
            (row.1 as f64) / (total_reqs as f64)
        } else {
            1.0
        };

        let total_toks = row.3;
        let (actual_ratio, estimated_ratio) = if total_toks > 0 {
            (
                (row.8 as f64) / (total_toks as f64),
                (row.9 as f64) / (total_toks as f64),
            )
        } else {
            (1.0, 0.0)
        };

        let tz = filter.tz_offset_minutes.unwrap_or(0);
        let from = filter.from.unwrap_or(0);
        let to = filter.to.unwrap_or_else(|| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as i64
        });

        Ok(TelemetrySummary {
            from,
            to,
            timezone_offset_minutes: tz,
            collection_started_at,
            total_requests: row.0,
            successful_requests: row.1,
            failed_requests: row.2,
            success_rate,
            total_tokens: row.3,
            input_tokens: row.4,
            output_tokens: row.5,
            cache_read_tokens: row.6,
            cache_write_tokens: row.7,
            actual_tokens_ratio: actual_ratio,
            estimated_tokens_ratio: estimated_ratio,
            avg_latency_ms: row.10,
            p50_ttft_ms: p50_ttft,
            p95_ttft_ms: p95_ttft,
            total_tool_calls: row.11,
            estimated_cost: row.12,
            currency: "USD".to_string(),
        })
    }

    pub fn query_timeseries(
        &self,
        filter: &TelemetryQueryFilter,
        interval: &str, // "hour", "day", "week"
        metric: &str,   // "tokens", "requests", "latency"
    ) -> Result<TimeseriesResponse, rusqlite::Error> {
        self.flush();
        let conn = self
            .db_conn
            .lock()
            .map_err(|_| rusqlite::Error::InvalidQuery)?;

        let tz_minutes = filter.tz_offset_minutes.unwrap_or(0);
        let tz_ms = (tz_minutes as i64) * 60 * 1000;

        let bucket_ms = match interval {
            "minute" | "1m" => 60 * 1000,
            "10m" => 10 * 60 * 1000,
            "hour" => 3600 * 1000,
            "day" => 86400 * 1000,
            "week" => 7 * 86400 * 1000,
            _ => 3600 * 1000,
        };

        let (where_clause, params_vec) = Self::build_where_clause(filter);

        let sql = format!(
            r#"
            SELECT
                ((timestamp + {tz_ms}) / {bucket_ms}) * {bucket_ms} - {tz_ms} AS bucket_time,
                COUNT(*) as req_count,
                COALESCE(SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END), 0) as succ_count,
                COALESCE(SUM(CASE WHEN status != 'success' THEN 1 ELSE 0 END), 0) as err_count,
                COALESCE(SUM(total_tokens), 0) as tot_tokens,
                COALESCE(SUM(input_tokens), 0) as in_tokens,
                COALESCE(SUM(output_tokens), 0) as out_tokens,
                COALESCE(SUM(cache_read_tokens), 0) as cache_tokens,
                COALESCE(SUM(CASE WHEN fidelity = 'actual' THEN COALESCE(total_tokens, 0) ELSE 0 END), 0) as act_tokens,
                COALESCE(AVG(latency_ms), 0.0) as avg_lat
            FROM request_events
            {where_clause}
            GROUP BY bucket_time
            ORDER BY bucket_time ASC
            "#,
            tz_ms = tz_ms,
            bucket_ms = bucket_ms,
            where_clause = where_clause
        );

        let params_refs: Vec<&dyn rusqlite::ToSql> = params_vec
            .iter()
            .map(|v| v as &dyn rusqlite::ToSql)
            .collect();

        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_refs.as_slice(), |r| {
            let bucket_start: i64 = r.get(0)?;
            let req_count: i64 = r.get(1)?;
            let succ_count: i64 = r.get(2)?;
            let err_count: i64 = r.get(3)?;
            let tot_tokens: i64 = r.get(4)?;
            let in_tokens: i64 = r.get(5)?;
            let out_tokens: i64 = r.get(6)?;
            let cache_tokens: i64 = r.get(7)?;
            let act_tokens: i64 = r.get(8)?;
            let avg_lat: f64 = r.get(9)?;

            let label = Self::format_bucket_label(bucket_start, tz_minutes, interval);
            let actual_ratio = if tot_tokens > 0 {
                (act_tokens as f64) / (tot_tokens as f64)
            } else {
                1.0
            };

            Ok(TimeseriesBucket {
                bucket_start,
                bucket_label: label,
                total_tokens: tot_tokens,
                input_tokens: in_tokens,
                output_tokens: out_tokens,
                cache_read_tokens: cache_tokens,
                actual_ratio,
                requests_count: req_count,
                success_count: succ_count,
                error_count: err_count,
                avg_latency_ms: avg_lat,
                p50_ttft_ms: 0,
                p95_ttft_ms: 0,
            })
        })?;

        let mut buckets = Vec::new();
        for b in rows {
            if let Ok(bucket) = b {
                buckets.push(bucket);
            }
        }

        Ok(TimeseriesResponse {
            interval: interval.to_string(),
            metric: metric.to_string(),
            buckets,
        })
    }

    pub fn query_breakdown(
        &self,
        filter: &TelemetryQueryFilter,
        dimension: &str, // "agent", "provider", "account", "model", "status", "fidelity"
    ) -> Result<BreakdownResponse, rusqlite::Error> {
        self.flush();
        let conn = self
            .db_conn
            .lock()
            .map_err(|_| rusqlite::Error::InvalidQuery)?;

        let dim_col = match dimension {
            "agent" => "agent",
            "provider" => "provider",
            "account" => "account",
            "model" => "target_model",
            "status" => "status",
            "fidelity" => "fidelity",
            _ => "provider",
        };

        let (where_clause, params_vec) = Self::build_where_clause(filter);

        let sql = format!(
            r#"
            SELECT
                COALESCE(NULLIF({dim_col}, ''), 'unknown') as dim_name,
                COUNT(*) as req_count,
                COALESCE(SUM(total_tokens), 0) as tot_tokens,
                COALESCE(SUM(input_tokens), 0) as in_tokens,
                COALESCE(SUM(output_tokens), 0) as out_tokens,
                COALESCE(SUM(cache_read_tokens), 0) as cache_tokens,
                COALESCE(SUM(CASE WHEN status != 'success' THEN 1 ELSE 0 END), 0) as err_count,
                COALESCE(AVG(latency_ms), 0.0) as avg_lat,
                COALESCE(AVG(ttft_ms), 0.0) as avg_ttft
            FROM request_events
            {where_clause}
            GROUP BY dim_name
            ORDER BY tot_tokens DESC, req_count DESC
            LIMIT 20
            "#,
            dim_col = dim_col,
            where_clause = where_clause
        );

        let params_refs: Vec<&dyn rusqlite::ToSql> = params_vec
            .iter()
            .map(|v| v as &dyn rusqlite::ToSql)
            .collect();

        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(params_refs.as_slice(), |r| {
            let name: String = r.get(0)?;
            let req_count: i64 = r.get(1)?;
            let tot_tokens: i64 = r.get(2)?;
            let in_tokens: i64 = r.get(3)?;
            let out_tokens: i64 = r.get(4)?;
            let cache_tokens: i64 = r.get(5)?;
            let err_count: i64 = r.get(6)?;
            let avg_lat: f64 = r.get(7)?;
            let avg_ttft: f64 = r.get(8)?;

            Ok((
                name,
                req_count,
                tot_tokens,
                in_tokens,
                out_tokens,
                cache_tokens,
                err_count,
                avg_lat,
                avg_ttft,
            ))
        })?;

        let mut raw_items = Vec::new();
        let mut overall_tokens: i64 = 0;
        let mut overall_requests: i64 = 0;

        for r in rows {
            if let Ok(item) = r {
                overall_tokens += item.2;
                overall_requests += item.1;
                raw_items.push(item);
            }
        }

        let items: Vec<BreakdownItem> = raw_items
            .into_iter()
            .map(
                |(name, req_count, tot_tok, in_tok, out_tok, cache_tok, err_c, avg_l, avg_t)| {
                    let percentage = if overall_tokens > 0 {
                        (tot_tok as f64) / (overall_tokens as f64)
                    } else if overall_requests > 0 {
                        (req_count as f64) / (overall_requests as f64)
                    } else {
                        0.0
                    };

                    BreakdownItem {
                        name,
                        requests_count: req_count,
                        total_tokens: tot_tok,
                        input_tokens: in_tok,
                        output_tokens: out_tok,
                        cache_read_tokens: cache_tok,
                        error_count: err_c,
                        avg_latency_ms: avg_l,
                        avg_ttft_ms: avg_t,
                        percentage,
                    }
                },
            )
            .collect();

        Ok(BreakdownResponse {
            dimension: dimension.to_string(),
            items,
        })
    }

    pub fn query_requests(
        &self,
        filter: &TelemetryQueryFilter,
        limit: usize,
        offset: usize,
        sort: Option<&str>, // "time_desc", "time_asc", "tokens_desc", "latency_desc", "ttft_desc"
    ) -> Result<RequestsListResponse, rusqlite::Error> {
        self.flush();
        let conn = self
            .db_conn
            .lock()
            .map_err(|_| rusqlite::Error::InvalidQuery)?;

        let (where_clause, params_vec) = Self::build_where_clause(filter);

        let count_sql = format!("SELECT COUNT(*) FROM request_events {}", where_clause);
        let params_refs: Vec<&dyn rusqlite::ToSql> = params_vec
            .iter()
            .map(|v| v as &dyn rusqlite::ToSql)
            .collect();

        let total: i64 = conn.query_row(&count_sql, params_refs.as_slice(), |r| r.get(0))?;

        let order_by = match sort {
            Some("time_asc") => "ORDER BY timestamp ASC",
            Some("tokens_desc") => "ORDER BY COALESCE(total_tokens, 0) DESC, timestamp DESC",
            Some("latency_desc") => "ORDER BY latency_ms DESC, timestamp DESC",
            Some("ttft_desc") => "ORDER BY ttft_ms DESC, timestamp DESC",
            _ => "ORDER BY timestamp DESC",
        };

        let limit_val = limit.clamp(1, 200);
        let offset_val = offset;

        let list_sql = format!(
            r#"
            SELECT
                id, timestamp, agent, ingress_protocol, provider, account,
                model_alias, target_model, input_tokens, output_tokens,
                cache_read_tokens, cache_write_tokens, total_tokens,
                latency_ms, ttft_ms, status_code, status, error_category,
                fidelity, is_stream, tool_calls_count, estimated_cost, currency
            FROM request_events
            {where_clause}
            {order_by}
            LIMIT {limit_val} OFFSET {offset_val}
            "#
        );

        let mut stmt = conn.prepare(&list_sql)?;
        let rows = stmt.query_map(params_refs.as_slice(), |r| {
            let is_stream_int: i32 = r.get(19)?;
            Ok(TelemetryEvent {
                id: r.get(0)?,
                timestamp: r.get(1)?,
                agent: r.get(2)?,
                ingress_protocol: r.get(3)?,
                provider: r.get(4)?,
                account: r.get(5)?,
                model_alias: r.get(6)?,
                target_model: r.get(7)?,
                input_tokens: r.get(8)?,
                output_tokens: r.get(9)?,
                cache_read_tokens: r.get(10)?,
                cache_write_tokens: r.get(11)?,
                total_tokens: r.get(12)?,
                latency_ms: r.get(13)?,
                ttft_ms: r.get(14)?,
                status_code: r.get(15)?,
                status: r.get(16)?,
                error_category: r.get(17)?,
                fidelity: r.get(18)?,
                is_stream: is_stream_int != 0,
                tool_calls_count: r.get(20)?,
                estimated_cost: r.get(21)?,
                currency: r.get(22)?,
            })
        })?;

        let mut items = Vec::new();
        for r in rows {
            if let Ok(ev) = r {
                items.push(ev);
            }
        }

        Ok(RequestsListResponse {
            total,
            limit: limit_val,
            offset: offset_val,
            items,
        })
    }

    pub fn clear_all_data(&self) -> Result<(), rusqlite::Error> {
        self.flush();
        let conn = self
            .db_conn
            .lock()
            .map_err(|_| rusqlite::Error::InvalidQuery)?;
        conn.execute("DELETE FROM request_events", [])?;
        Ok(())
    }

    fn format_bucket_label(bucket_start_ms: i64, tz_offset_minutes: i32, interval: &str) -> String {
        let adjusted_secs = (bucket_start_ms / 1000) + (tz_offset_minutes as i64 * 60);
        let days = adjusted_secs / 86400;
        let rem = adjusted_secs % 86400;
        let hours = rem / 3600;
        let mins = (rem % 3600) / 60;

        // Approximate calendar calculation for label formatting
        // Simple leap year algorithm from Unix epoch (1970-01-01)
        let (year, month, day) = days_to_date(days);

        match interval {
            "minute" | "1m" | "10m" => format!("{:02}:{:02}", hours, mins),
            "hour" => format!("{:02}:{:02}", hours, mins),
            "day" => format!("{:02}/{:02}", month, day),
            "week" => format!("{:04}-W{:02}", year, (days / 7) % 52 + 1),
            _ => format!("{:02}:{:02}", hours, mins),
        }
    }
}

fn days_to_date(days_since_epoch: i64) -> (i64, i64, i64) {
    let mut d = days_since_epoch;
    let mut year = 1970;
    loop {
        let is_leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        let days_in_year = if is_leap { 366 } else { 365 };
        if d < days_in_year {
            break;
        }
        d -= days_in_year;
        year += 1;
    }

    let is_leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
    let days_in_months = [
        31,
        if is_leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];

    let mut month = 1;
    for &dim in &days_in_months {
        if d < dim {
            break;
        }
        d -= dim;
        month += 1;
    }
    let day = d + 1;

    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_telemetry_store_lifecycle_and_aggregations() {
        let store = TelemetryStore::new_in_memory().unwrap();

        let event1 = TelemetryEvent {
            id: "req_1".to_string(),
            timestamp: 1725200000000,
            agent: "Hermes".to_string(),
            ingress_protocol: "openai-chat".to_string(),
            provider: "google".to_string(),
            account: "Google Dev".to_string(),
            model_alias: "gemini-2.5-flash".to_string(),
            target_model: "gemini-2.5-flash".to_string(),
            input_tokens: Some(100),
            output_tokens: Some(50),
            cache_read_tokens: Some(20),
            cache_write_tokens: None,
            total_tokens: Some(150),
            latency_ms: 800,
            ttft_ms: 250,
            status_code: 200,
            status: "success".to_string(),
            error_category: None,
            fidelity: "actual".to_string(),
            is_stream: true,
            tool_calls_count: 2,
            estimated_cost: Some(0.001),
            currency: Some("USD".to_string()),
        };

        let event2 = TelemetryEvent {
            id: "req_2".to_string(),
            timestamp: 1725203600000,
            agent: "Pi".to_string(),
            ingress_protocol: "anthropic-messages".to_string(),
            provider: "anthropic".to_string(),
            account: "Claude Pro".to_string(),
            model_alias: "claude-3-7-sonnet".to_string(),
            target_model: "claude-3-7-sonnet-20250219".to_string(),
            input_tokens: Some(500),
            output_tokens: Some(200),
            cache_read_tokens: None,
            cache_write_tokens: None,
            total_tokens: Some(700),
            latency_ms: 1500,
            ttft_ms: 400,
            status_code: 200,
            status: "success".to_string(),
            error_category: None,
            fidelity: "actual".to_string(),
            is_stream: true,
            tool_calls_count: 0,
            estimated_cost: Some(0.005),
            currency: Some("USD".to_string()),
        };

        let event3 = TelemetryEvent {
            id: "req_3".to_string(),
            timestamp: 1725207200000,
            agent: "Cursor".to_string(),
            ingress_protocol: "openai-chat".to_string(),
            provider: "openai".to_string(),
            account: "OpenAI Main".to_string(),
            model_alias: "gpt-4o".to_string(),
            target_model: "gpt-4o".to_string(),
            input_tokens: Some(50),
            output_tokens: None,
            cache_read_tokens: None,
            cache_write_tokens: None,
            total_tokens: None,
            latency_ms: 300,
            ttft_ms: 0,
            status_code: 401,
            status: "error".to_string(),
            error_category: Some("auth_error".to_string()),
            fidelity: "unavailable".to_string(),
            is_stream: false,
            tool_calls_count: 0,
            estimated_cost: None,
            currency: None,
        };

        store.record_event(event1);
        store.record_event(event2);
        store.record_event(event3);
        store.flush();

        // 1. Query Summary
        let summary = store.query_summary(&TelemetryQueryFilter::default()).unwrap();
        assert_eq!(summary.total_requests, 3);
        assert_eq!(summary.successful_requests, 2);
        assert_eq!(summary.failed_requests, 1);
        assert_eq!(summary.total_tokens, 850);
        assert_eq!(summary.input_tokens, 650);
        assert_eq!(summary.output_tokens, 250);
        assert_eq!(summary.cache_read_tokens, 20);
        assert_eq!(summary.total_tool_calls, 2);
        assert!(summary.success_rate > 0.66 && summary.success_rate < 0.67);

        // 2. Query Breakdown by Provider
        let breakdown = store
            .query_breakdown(&TelemetryQueryFilter::default(), "provider")
            .unwrap();
        assert_eq!(breakdown.items.len(), 3);
        assert_eq!(breakdown.items[0].name, "anthropic"); // 700 tokens
        assert_eq!(breakdown.items[1].name, "google"); // 150 tokens
        assert_eq!(breakdown.items[2].name, "openai"); // 0 tokens (error)

        // 3. Query Breakdown with filter
        let filter_pi = TelemetryQueryFilter {
            agent: Some("Pi".to_string()),
            ..Default::default()
        };
        let breakdown_pi = store.query_breakdown(&filter_pi, "provider").unwrap();
        assert_eq!(breakdown_pi.items.len(), 1);
        assert_eq!(breakdown_pi.items[0].name, "anthropic");

        // 4. Query Timeseries
        let ts = store
            .query_timeseries(&TelemetryQueryFilter::default(), "hour", "tokens")
            .unwrap();
        assert!(!ts.buckets.is_empty());

        // 5. Query Requests List
        let reqs = store
            .query_requests(&TelemetryQueryFilter::default(), 10, 0, Some("time_desc"))
            .unwrap();
        assert_eq!(reqs.total, 3);
        assert_eq!(reqs.items.len(), 3);
        assert_eq!(reqs.items[0].id, "req_3"); // Latest first

        // 6. Clear all
        store.clear_all_data().unwrap();
        let summary_cleared = store.query_summary(&TelemetryQueryFilter::default()).unwrap();
        assert_eq!(summary_cleared.total_requests, 0);
        assert_eq!(summary_cleared.total_tokens, 0);
    }
}
