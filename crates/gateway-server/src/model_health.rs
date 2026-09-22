use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::server::{GatewayServer, UpstreamEndpoint};

const PROBE_GAP_MS: u64 = 600;
const PROBE_RETRY_GAP_MS: u64 = 1000;
const PROBE_TIMEOUT_SECS: u64 = 8;
const MODEL_MAX_RETRIES: u32 = 1;

#[cfg(unix)]
extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HealthStatus {
    Available,
    Unavailable,
    Error,
    Skipped,
    Unchecked,
}

impl HealthStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::Unavailable => "unavailable",
            Self::Error => "error",
            Self::Skipped => "skipped",
            Self::Unchecked => "unchecked",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelRecord {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,
    pub checked_at: i64,
    #[serde(default)]
    pub retries: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountHealth {
    pub provider: String,
    pub provider_name: String,
    pub connection_id: String,
    pub slug: String,
    pub label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checked_at: Option<i64>,
    #[serde(default)]
    pub models: BTreeMap<String, ModelRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct HealthData {
    pub schema_version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_full_check_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_job_summary: Option<Value>,
    #[serde(default)]
    pub accounts: BTreeMap<String, AccountHealth>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct JobInfo {
    pub running: bool,
    pub scope: String,
    pub done: usize,
    pub total: usize,
    pub current: String,
    #[serde(default)]
    pub results: Vec<JobProbeResult>,
    pub started_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_finished_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_summary: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobProbeResult {
    pub scoped_id: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,
}

#[derive(Debug, Clone)]
pub enum ProbeOutcome {
    Available { latency_ms: u64 },
    HardFail { reason: String, latency_ms: u64 },
    Transient { reason: String, latency_ms: u64 },
    Skipped { reason: String },
}

#[derive(Debug, Clone)]
pub enum CheckScope {
    All,
    Account { provider: String, connection_id: String },
    Selective {
        providers: Vec<String>,
        account_ids: Vec<String>,
        all_accounts: bool,
    },
}

pub struct ModelHealthEngine {
    pub data: Mutex<HealthData>,
    pub staging_data: Mutex<Option<HealthData>>,
    pub path: Option<PathBuf>,
    pub job: Mutex<JobInfo>,
    pub cancel_requested: AtomicBool,
    pub active_child_pid: std::sync::atomic::AtomicU32,
}

impl ModelHealthEngine {
    pub fn default_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("Tomo")
            .join("gateway-model-health.json")
    }

    pub fn new_default() -> Self {
        Self::new_with_path(Some(Self::default_path()))
    }

    pub fn new_with_path(path: Option<PathBuf>) -> Self {
        let data = if let Some(ref p) = path {
            Self::load_from_disk(p).unwrap_or_default()
        } else {
            HealthData {
                schema_version: 1,
                ..Default::default()
            }
        };

        let last_finished_at = data.last_full_check_at;
        let last_summary = data.last_job_summary.clone();

        Self {
            data: Mutex::new(data),
            staging_data: Mutex::new(None),
            path,
            job: Mutex::new(JobInfo {
                last_finished_at,
                last_summary,
                ..Default::default()
            }),
            cancel_requested: AtomicBool::new(false),
            active_child_pid: std::sync::atomic::AtomicU32::new(0),
        }
    }

    fn load_from_disk(path: &Path) -> Option<HealthData> {
        let raw = fs::read_to_string(path).ok()?;
        serde_json::from_str(&raw).ok()
    }

    pub fn persist(&self) {
        let Some(ref path) = self.path else {
            return;
        };
        let snapshot = {
            let guard = match self.data.lock() {
                Ok(g) => g,
                Err(poisoned) => poisoned.into_inner(),
            };
            guard.clone()
        };

        let raw = match serde_json::to_string_pretty(&snapshot) {
            Ok(s) => s,
            Err(_) => return,
        };

        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }

        let tmp_path = path.with_extension("tmp");
        if fs::write(&tmp_path, raw).is_ok() {
            let _ = fs::rename(&tmp_path, path);
        }
    }

    pub fn now_epoch_secs() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    }

    pub fn record_probe(
        &self,
        connection_id: &str,
        provider: &str,
        provider_name: &str,
        slug: &str,
        label: &str,
        raw_model: &str,
        outcome: &ProbeOutcome,
        retries: u32,
    ) {
        let now = Self::now_epoch_secs();
        let record = match outcome {
            ProbeOutcome::Available { latency_ms } => ModelRecord {
                status: HealthStatus::Available.as_str().to_string(),
                reason: None,
                latency_ms: Some(*latency_ms),
                checked_at: now,
                retries,
            },
            ProbeOutcome::HardFail { reason, latency_ms } => ModelRecord {
                status: HealthStatus::Unavailable.as_str().to_string(),
                reason: Some(reason.clone()),
                latency_ms: Some(*latency_ms),
                checked_at: now,
                retries,
            },
            ProbeOutcome::Transient { reason, latency_ms } => ModelRecord {
                status: HealthStatus::Error.as_str().to_string(),
                reason: Some(reason.clone()),
                latency_ms: Some(*latency_ms),
                checked_at: now,
                retries,
            },
            ProbeOutcome::Skipped { reason } => ModelRecord {
                status: HealthStatus::Skipped.as_str().to_string(),
                reason: Some(reason.clone()),
                latency_ms: None,
                checked_at: now,
                retries: 0,
            },
        };

        {
            let mut staged_guard = match self.staging_data.lock() {
                Ok(s) => s,
                Err(p) => p.into_inner(),
            };

            if let Some(ref mut staged) = *staged_guard {
                let account = staged
                    .accounts
                    .entry(connection_id.to_string())
                    .or_insert_with(|| AccountHealth {
                        provider: provider.to_string(),
                        provider_name: provider_name.to_string(),
                        connection_id: connection_id.to_string(),
                        slug: slug.to_string(),
                        label: label.to_string(),
                        checked_at: None,
                        models: BTreeMap::new(),
                    });

                account.checked_at = Some(now);
                account.label = label.to_string();
                account.slug = slug.to_string();
                account.models.insert(raw_model.to_string(), record);
                return;
            }

            let mut guard = match self.data.lock() {
                Ok(g) => g,
                Err(p) => p.into_inner(),
            };
            let account = guard
                .accounts
                .entry(connection_id.to_string())
                .or_insert_with(|| AccountHealth {
                    provider: provider.to_string(),
                    provider_name: provider_name.to_string(),
                    connection_id: connection_id.to_string(),
                    slug: slug.to_string(),
                    label: label.to_string(),
                    checked_at: None,
                    models: BTreeMap::new(),
                });

            account.checked_at = Some(now);
            account.label = label.to_string();
            account.slug = slug.to_string();
            account.models.insert(raw_model.to_string(), record);
        }

        self.persist();
    }

    pub fn try_start_job(&self, scope_desc: &str, initial_total: usize) -> Result<(), ()> {
        let mut job = match self.job.lock() {
            Ok(j) => j,
            Err(p) => p.into_inner(),
        };
        if job.running {
            return Err(());
        }
        self.cancel_requested.store(false, Ordering::SeqCst);
        job.running = true;
        job.scope = scope_desc.to_string();
        job.done = 0;
        job.total = initial_total;
        job.current = if initial_total > 0 { "正在启动探测...".to_string() } else { String::new() };
        job.results.clear();
        job.started_at = Self::now_epoch_secs();

        // 阶段缓冲：检查过程中保留历史数据对客户端的可见性与路由，
        // 巡检产生的最新结果先写入 staging_data，巡检结束时再原子替换。
        let current_data = match self.data.lock() {
            Ok(d) => d.clone(),
            Err(p) => p.into_inner().clone(),
        };
        if let Ok(mut stage) = self.staging_data.lock() {
            *stage = Some(current_data);
        }
        Ok(())
    }

    pub fn cancel_job(&self) -> bool {
        let mut job = match self.job.lock() {
            Ok(j) => j,
            Err(p) => p.into_inner(),
        };
        if !job.running {
            return false;
        }
        self.cancel_requested.store(true, Ordering::SeqCst);
        let pid = self.active_child_pid.swap(0, Ordering::SeqCst);
        if pid > 0 {
            #[cfg(unix)]
            unsafe {
                kill(pid as i32, 9);
            }
        }
        if let Ok(mut stage) = self.staging_data.lock() {
            *stage = None;
        }
        job.current = "正在取消巡检...".to_string();
        true
    }

    pub fn interruptible_sleep(&self, millis: u64) {
        let chunk = 100;
        let mut elapsed = 0;
        while elapsed < millis {
            if self.cancel_requested.load(Ordering::SeqCst) {
                break;
            }
            let wait = std::cmp::min(chunk, millis - elapsed);
            thread::sleep(Duration::from_millis(wait));
            elapsed += wait;
        }
    }

    pub fn update_job_progress(&self, done: usize, total: usize, current: &str) {
        let mut job = match self.job.lock() {
            Ok(j) => j,
            Err(p) => p.into_inner(),
        };
        job.done = done;
        job.total = total;
        job.current = current.to_string();
    }

    fn record_job_result(&self, scoped_id: &str, outcome: &ProbeOutcome) {
        let (status, reason, latency_ms) = match outcome {
            ProbeOutcome::Available { latency_ms } => ("available", None, Some(*latency_ms)),
            ProbeOutcome::HardFail { reason, latency_ms } => {
                ("unavailable", Some(reason.clone()), Some(*latency_ms))
            }
            ProbeOutcome::Transient { reason, latency_ms } => {
                ("error", Some(reason.clone()), Some(*latency_ms))
            }
            ProbeOutcome::Skipped { reason } => ("skipped", Some(reason.clone()), None),
        };
        let mut job = match self.job.lock() {
            Ok(j) => j,
            Err(p) => p.into_inner(),
        };
        job.results.push(JobProbeResult {
            scoped_id: scoped_id.to_string(),
            status: status.to_string(),
            reason,
            latency_ms,
        });
    }

    pub fn finish_job(&self, summary: Value) {
        let now = Self::now_epoch_secs();
        let mut job = match self.job.lock() {
            Ok(j) => j,
            Err(p) => p.into_inner(),
        };
        job.running = false;
        job.last_finished_at = Some(now);
        job.last_summary = Some(summary.clone());
        job.current = String::new();
        self.cancel_requested.store(false, Ordering::SeqCst);

        let is_cancelled = summary
            .get("cancelled")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        if !is_cancelled && job.total > 0 {
            job.done = job.total;
        }

        let staged_opt = {
            let mut stage = match self.staging_data.lock() {
                Ok(s) => s,
                Err(p) => p.into_inner(),
            };
            stage.take()
        };

        if !is_cancelled {
            let mut data = match self.data.lock() {
                Ok(d) => d,
                Err(p) => p.into_inner(),
            };
            if let Some(staged) = staged_opt {
                data.accounts = staged.accounts;
            }
            if job.scope == "all" {
                data.last_full_check_at = Some(now);
            }
            data.last_job_summary = Some(summary.clone());
            drop(data);
            self.persist();
        }
        drop(job);
    }

    pub fn job_status_payload(&self) -> Value {
        let job = match self.job.lock() {
            Ok(j) => j,
            Err(p) => p.into_inner(),
        };
        json!({
            "running": job.running,
            "scope": job.scope,
            "done": job.done,
            "total": job.total,
            "current": job.current,
            "results": job.results,
            "startedAt": job.started_at,
            "lastFinishedAt": job.last_finished_at,
            "lastSummary": job.last_summary,
        })
    }

    /// Strict filter for `/v1/models` payload:
    /// - If no health check has ever run and records are empty, return unchanged (bootstrap grace).
    /// - Otherwise ONLY models verified as "available" are kept.
    ///   - "error", "unavailable", "skipped", "unchecked" are strictly DROPPED.
    pub fn filter_models_payload(&self, mut payload: Value) -> Value {
        let guard = match self.data.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        };

        // Bootstrap grace: only if no records exist at all
        if guard.accounts.is_empty() {
            return payload;
        }

        let Some(data_array) = payload.get_mut("data").and_then(|v| v.as_array_mut()) else {
            return payload;
        };

        // Build lookup indices:
        // (cid, mid) -> status
        // slug.to_lowercase() -> cid
        let mut model_status: HashMap<(String, String), String> = HashMap::new();
        let mut slug_to_cid: HashMap<String, String> = HashMap::new();

        for (cid, acc) in &guard.accounts {
            slug_to_cid.insert(acc.slug.to_lowercase(), cid.clone());
            let clean_cid = cid.replace('-', "").to_lowercase();
            slug_to_cid.insert(clean_cid, cid.clone());

            for (mid, rec) in &acc.models {
                let mid_lower = mid.to_lowercase();
                model_status.insert((cid.clone(), mid_lower.clone()), rec.status.clone());
                let trimmed = mid_lower.trim_end_matches("-tiered").to_string();
                model_status.insert((cid.clone(), trimmed), rec.status.clone());
            }
        }

        data_array.retain(|item| {
            let Some(id) = item.get("id").and_then(|v| v.as_str()) else {
                return false;
            };

            // Parse ID format: provider/model@slug or provider/model
            let parts: Vec<&str> = id.split('@').collect();
            if parts.len() == 2 {
                let scoped_prefix = parts[0];
                let slug = parts[1].to_lowercase();
                let raw_mid = scoped_prefix.split('/').nth(1).unwrap_or(scoped_prefix).to_lowercase();
                let trimmed_mid = raw_mid.trim_end_matches("-tiered").to_string();

                if let Some(cid) = slug_to_cid.get(&slug) {
                    if let Some(st) = model_status.get(&(cid.clone(), raw_mid.clone())) {
                        return st == "available";
                    }
                    if let Some(st) = model_status.get(&(cid.clone(), trimmed_mid.clone())) {
                        return st == "available";
                    }
                }

                for (known_slug, cid) in &slug_to_cid {
                    if slug.contains(known_slug) || known_slug.contains(&slug) {
                        if let Some(st) = model_status.get(&(cid.clone(), raw_mid.clone())) {
                            return st == "available";
                        }
                        if let Some(st) = model_status.get(&(cid.clone(), trimmed_mid.clone())) {
                            return st == "available";
                        }
                    }
                }
                false
            } else {
                // Consolidated or legacy alias without @slug:
                let raw_mid = id.split('/').nth(1).unwrap_or(id).to_lowercase();
                let trimmed_mid = raw_mid.trim_end_matches("-tiered").to_string();
                let any_available = model_status.iter().any(|((_, m), st)| {
                    (m == &raw_mid || m == &trimmed_mid) && st == "available"
                });
                any_available
            }
        });

        payload
    }

    /// Builds the rich `/v1/models/all` payload merging connections-v1.json with health records.
    /// Supports optional `status_filter` ("problematic", "error", "unavailable", "available").
    pub fn models_all_payload(&self, home: &str, status_filter: Option<&str>) -> Value {
        let registry_path = PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("Tomo")
            .join("connections-v1.json");

        let raw_registry = fs::read_to_string(&registry_path).unwrap_or_default();
        let registry: Value = serde_json::from_str(&raw_registry).unwrap_or_default();

        let guard = match self.data.lock() {
            Ok(g) => g,
            Err(p) => p.into_inner(),
        };

        let mut accounts_out = Vec::new();
        let mut grand_total = 0;
        let mut grand_available = 0;
        let mut grand_unavailable = 0;
        let mut grand_error = 0;
        let mut grand_unchecked = 0;
        let mut grand_skipped = 0;

        let sections = [
            ("google", "Google Gemini", "geminiConnections", "google"),
            ("openai", "OpenAI / Codex", "codexAccounts", "openai"),
            ("deepseek", "DeepSeek", "deepSeekConnections", "deepseek"),
            ("opencode", "OpenCode", "openCodeConnections", "opencode"),
        ];

        for (provider_key, provider_name, section_key, provider_suffix) in sections {
            let Some(accounts) = registry.get(section_key).and_then(|v| v.as_array()) else {
                continue;
            };

            for acc in accounts {
                let enabled = acc
                    .get("isEnabled")
                    .or_else(|| acc.get("enabled"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true);
                if !enabled {
                    continue;
                }

                let cid = GatewayServer::connection_id(acc);
                if cid.is_empty() {
                    continue;
                }

                let label = acc.get("label").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let short_id = GatewayServer::connection_short_id(acc);
                let (slug_base, clean_label) = GatewayServer::friendly_account_slug(
                    acc.get("accountName").and_then(|v| v.as_str()),
                    acc.get("email").and_then(|v| v.as_str()),
                    &label,
                );
                let final_label = if label.is_empty() { clean_label } else { label };
                let slug = format!("{slug_base}-{provider_suffix}-{short_id}");

                // Model IDs list:
                let raw_models: Vec<String> = if section_key == "codexAccounts" {
                    let standard = vec![
                        "gpt-5.4".into(),
                        "gpt-5.3-codex".into(),
                        "gpt-5.2-codex".into(),
                        "gpt-5.2".into(),
                        "gpt-5.1-codex-max".into(),
                        "gpt-5.1-codex".into(),
                    ];
                    acc.get("availableModelIDs")
                        .and_then(|v| v.as_array())
                        .map(|arr| arr.iter().filter_map(|m| m.as_str().map(String::from)).collect())
                        .unwrap_or(standard)
                } else {
                    acc.get("availableModelIDs")
                        .and_then(|v| v.as_array())
                        .map(|arr| arr.iter().filter_map(|m| m.as_str().map(String::from)).collect())
                        .unwrap_or_default()
                };

                let saved_account = guard.accounts.get(&cid);
                let mut models_out = Vec::new();

                let mut count_avail = 0;
                let mut count_unavail = 0;
                let mut count_err = 0;
                let mut count_unchk = 0;
                let mut count_skip = 0;

                for mid in &raw_models {
                    let scoped_id = format!("{provider_key}/{mid}@{slug}");
                    let record = saved_account.and_then(|a| a.models.get(mid));

                    let is_tab = mid.starts_with("tab_");
                    let status = if is_tab {
                        "skipped"
                    } else if let Some(rec) = record {
                        rec.status.as_str()
                    } else {
                        "unchecked"
                    };

                    match status {
                        "available" => count_avail += 1,
                        "unavailable" => count_unavail += 1,
                        "error" => count_err += 1,
                        "skipped" => count_skip += 1,
                        _ => count_unchk += 1,
                    }

                    // Apply status filter if specified
                    let matches_filter = match status_filter {
                        Some("problematic") | Some("abnormal") => {
                            status == "unavailable" || status == "error"
                        }
                        Some("available") => status == "available",
                        Some("error") => status == "error",
                        Some("unavailable") => status == "unavailable",
                        Some("skipped") => status == "skipped",
                        Some("unchecked") => status == "unchecked",
                        _ => true,
                    };

                    if !matches_filter {
                        continue;
                    }

                    let exported = status == "available";

                    models_out.push(json!({
                        "id": mid,
                        "scopedId": scoped_id,
                        "status": status,
                        "reason": record.and_then(|r| r.reason.as_deref()),
                        "latencyMs": record.and_then(|r| r.latency_ms),
                        "checkedAt": record.map(|r| r.checked_at),
                        "retries": record.map(|r| r.retries).unwrap_or(0),
                        "exported": exported,
                    }));
                }

                grand_total += raw_models.len();
                grand_available += count_avail;
                grand_unavailable += count_unavail;
                grand_error += count_err;
                grand_unchecked += count_unchk;
                grand_skipped += count_skip;

                if status_filter.is_none() || !models_out.is_empty() {
                    accounts_out.push(json!({
                        "provider": provider_key,
                        "providerName": provider_name,
                        "connectionId": cid,
                        "slug": slug,
                        "label": final_label,
                        "checkedAt": saved_account.and_then(|a| a.checked_at),
                        "summary": {
                            "total": raw_models.len(),
                            "available": count_avail,
                            "unavailable": count_unavail,
                            "error": count_err,
                            "unchecked": count_unchk,
                            "skipped": count_skip,
                        },
                        "models": models_out,
                    }));
                }
            }
        }

        json!({
            "lastFullCheckAt": guard.last_full_check_at,
            "job": self.job_status_payload(),
            "summary": {
                "total": grand_total,
                "available": grand_available,
                "unavailable": grand_unavailable,
                "error": grand_error,
                "unchecked": grand_unchecked,
                "skipped": grand_skipped,
            },
            "accounts": accounts_out,
        })
    }

    /// Builds a flat diagnosis payload directly listing all abnormal / problematic models with exact reasons.
    pub fn models_health_diagnosis_payload(&self, home: &str) -> Value {
        let all_payload = self.models_all_payload(home, None);
        let summary = all_payload.get("summary").cloned().unwrap_or(json!({}));
        let last_full = all_payload.get("lastFullCheckAt").cloned();
        let job = all_payload.get("job").cloned().unwrap_or(json!({}));

        let mut problematic_models = Vec::new();
        let mut available_models = Vec::new();

        if let Some(accounts) = all_payload.get("accounts").and_then(|v| v.as_array()) {
            for acc in accounts {
                let provider = acc.get("provider").and_then(|v| v.as_str()).unwrap_or("");
                let provider_name = acc.get("providerName").and_then(|v| v.as_str()).unwrap_or("");
                let account = acc.get("label").and_then(|v| v.as_str()).unwrap_or("");
                let cid = acc.get("connectionId").and_then(|v| v.as_str()).unwrap_or("");
                let slug = acc.get("slug").and_then(|v| v.as_str()).unwrap_or("");

                if let Some(models) = acc.get("models").and_then(|v| v.as_array()) {
                    for m in models {
                        let status = m.get("status").and_then(|v| v.as_str()).unwrap_or("");
                        let model_id = m.get("id").and_then(|v| v.as_str()).unwrap_or("");
                        let scoped_id = m.get("scopedId").and_then(|v| v.as_str()).unwrap_or("");
                        let reason = m.get("reason").and_then(|v| v.as_str());
                        let latency_ms = m.get("latencyMs").and_then(|v| v.as_u64());
                        let retries = m.get("retries").and_then(|v| v.as_u64()).unwrap_or(0);
                        let checked_at = m.get("checkedAt").and_then(|v| v.as_i64());

                        let item = json!({
                            "provider": provider,
                            "providerName": provider_name,
                            "account": account,
                            "connectionId": cid,
                            "slug": slug,
                            "model": model_id,
                            "scopedId": scoped_id,
                            "status": status,
                            "reason": reason,
                            "latencyMs": latency_ms,
                            "retries": retries,
                            "checkedAt": checked_at,
                        });

                        if status == "unavailable" || status == "error" {
                            problematic_models.push(item);
                        } else if status == "available" {
                            available_models.push(item);
                        }
                    }
                }
            }
        }

        json!({
            "summary": summary,
            "lastFullCheckAt": last_full,
            "job": job,
            "problematicCount": problematic_models.len(),
            "availableCount": available_models.len(),
            "problematicModels": problematic_models,
            "availableModels": available_models,
        })
    }
}

// ---------------------------------------------------------------------------
// Probing Engine (Strictly Sequential, with 1 retry on failure)
// ---------------------------------------------------------------------------

pub struct ModelTarget {
    pub provider_key: String,
    pub provider_name: String,
    pub connection_id: String,
    pub slug: String,
    pub label: String,
    pub raw_model: String,
}

impl ModelHealthEngine {
    pub fn provider_matches(query: &str, target_key: &str) -> bool {
        let q = query.trim().to_ascii_lowercase();
        let t = target_key.trim().to_ascii_lowercase();
        if q == t {
            return true;
        }
        matches!(
            (q.as_str(), t.as_str()),
            ("codex", "openai") | ("openai", "codex") | ("gemini", "google") | ("google", "gemini")
        )
    }

    /// Collect targets to check according to scope
    pub fn collect_targets(&self, home: &str, scope: &CheckScope) -> Vec<ModelTarget> {
        let registry_path = PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("Tomo")
            .join("connections-v1.json");

        let raw_registry = fs::read_to_string(&registry_path).unwrap_or_default();
        let registry: Value = serde_json::from_str(&raw_registry).unwrap_or_default();

        let mut targets = Vec::new();

        let sections = [
            ("google", "Google Gemini", "geminiConnections", "google"),
            ("openai", "OpenAI / Codex", "codexAccounts", "openai"),
            ("deepseek", "DeepSeek", "deepSeekConnections", "deepseek"),
            ("opencode", "OpenCode", "openCodeConnections", "opencode"),
        ];

        for (provider_key, provider_name, section_key, provider_suffix) in sections {
            let Some(accounts) = registry.get(section_key).and_then(|v| v.as_array()) else {
                continue;
            };

            for acc in accounts {
                let enabled = acc
                    .get("isEnabled")
                    .or_else(|| acc.get("enabled"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(true);
                if !enabled {
                    continue;
                }

                let cid = GatewayServer::connection_id(acc);
                if cid.is_empty() {
                    continue;
                }

                // Scope filtering
                match scope {
                    CheckScope::All => {}
                    CheckScope::Account {
                        provider: p,
                        connection_id: id,
                    } => {
                        let p_match = Self::provider_matches(p, provider_key);
                        let clean_id = id.replace('-', "").to_lowercase();
                        let clean_cid = cid.replace('-', "").to_lowercase();
                        let cid_match = clean_id == clean_cid
                            || clean_cid.starts_with(&clean_id)
                            || clean_id.starts_with(&clean_cid);
                        if !p_match || !cid_match {
                            continue;
                        }
                    }
                    CheckScope::Selective {
                        providers,
                        account_ids,
                        all_accounts,
                    } => {
                        let p_match = providers.is_empty()
                            || providers.iter().any(|p| Self::provider_matches(p, provider_key));
                        if !p_match {
                            continue;
                        }
                        if !all_accounts && !account_ids.is_empty() {
                            let clean_cid = cid.replace('-', "").to_lowercase();
                            let acc_match = account_ids.iter().any(|id| {
                                let clean_id = id.replace('-', "").to_lowercase();
                                clean_id == clean_cid
                                    || clean_cid.starts_with(&clean_id)
                                    || clean_id.starts_with(&clean_cid)
                            });
                            if !acc_match {
                                continue;
                            }
                        }
                    }
                }

                let label = acc.get("label").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let short_id = GatewayServer::connection_short_id(acc);
                let (slug_base, clean_label) = GatewayServer::friendly_account_slug(
                    acc.get("accountName").and_then(|v| v.as_str()),
                    acc.get("email").and_then(|v| v.as_str()),
                    &label,
                );
                let final_label = if label.is_empty() { clean_label } else { label };
                let slug = format!("{slug_base}-{provider_suffix}-{short_id}");

                let raw_models: Vec<String> = if section_key == "codexAccounts" {
                    let standard = vec![
                        "gpt-5.4".into(),
                        "gpt-5.3-codex".into(),
                        "gpt-5.2-codex".into(),
                        "gpt-5.2".into(),
                        "gpt-5.1-codex-max".into(),
                        "gpt-5.1-codex".into(),
                    ];
                    acc.get("availableModelIDs")
                        .and_then(|v| v.as_array())
                        .map(|arr| arr.iter().filter_map(|m| m.as_str().map(String::from)).collect())
                        .unwrap_or(standard)
                } else {
                    acc.get("availableModelIDs")
                        .and_then(|v| v.as_array())
                        .map(|arr| arr.iter().filter_map(|m| m.as_str().map(String::from)).collect())
                        .unwrap_or_default()
                };

                for mid in raw_models {
                    targets.push(ModelTarget {
                        provider_key: provider_key.to_string(),
                        provider_name: provider_name.to_string(),
                        connection_id: cid.clone(),
                        slug: slug.clone(),
                        label: final_label.clone(),
                        raw_model: mid,
                    });
                }
            }
        }

        targets
    }

    /// Main entry for running check in background thread. Strictly sequential!
    pub fn run_check(&self, home: &str, scope: CheckScope) {
        let targets = self.collect_targets(home, &scope);
        let total = targets.len();

        let mut available_count = 0;
        let mut unavailable_count = 0;
        let mut error_count = 0;
        let mut skipped_count = 0;

        for (idx, target) in targets.iter().enumerate() {
            if self.cancel_requested.load(Ordering::SeqCst) {
                eprintln!("[ModelHealth] Check cancelled by user before probing {idx}/{total}");
                break;
            }

            let scoped_model_id = format!(
                "{}/{}@{}",
                target.provider_key, target.raw_model, target.slug
            );
            // 进度语义：done 表示“已完成探测数”，探测开始前仍是 idx，
            // 避免最后一个模型仍在探测时 UI 就显示 total/total 而显得卡住。
            self.update_job_progress(idx, total, &scoped_model_id);

            // Tab models: skip
            if target.raw_model.starts_with("tab_") {
                self.record_probe(
                    &target.connection_id,
                    &target.provider_key,
                    &target.provider_name,
                    &target.slug,
                    &target.label,
                    &target.raw_model,
                    &ProbeOutcome::Skipped {
                        reason: "IDE completion model skipped".into(),
                    },
                    0,
                );
                self.record_job_result(
                    &scoped_model_id,
                    &ProbeOutcome::Skipped {
                        reason: "IDE completion model skipped".into(),
                    },
                );
                skipped_count += 1;
                self.update_job_progress(idx + 1, total, &scoped_model_id);
                continue;
            }

            // Probe attempt 1 (+ up to MODEL_MAX_RETRIES retries on transient failure)
            let mut attempt_reasons: Vec<String> = Vec::new();
            let mut outcome = self.probe_model(home, target);
            let mut retried = 0u32;

            let final_outcome = loop {
                match outcome {
                    ProbeOutcome::Available { latency_ms } => {
                        available_count += 1;
                        break ProbeOutcome::Available { latency_ms };
                    }
                    ProbeOutcome::Skipped { reason } => {
                        skipped_count += 1;
                        break ProbeOutcome::Skipped { reason };
                    }
                    ProbeOutcome::HardFail { reason, latency_ms } => {
                        // 硬性错误（404/模型不支持/明确拒绝）不重试，避免拖延整体巡检
                        unavailable_count += 1;
                        let combined = if attempt_reasons.is_empty() {
                            reason
                        } else {
                            format!(
                                "{reason} (第1次尝试失败: {})",
                                attempt_reasons.join(" → ")
                            )
                        };
                        break ProbeOutcome::HardFail {
                            reason: combined,
                            latency_ms,
                        };
                    }
                    ProbeOutcome::Transient { reason, latency_ms } if reason.contains("超时") || reason.contains("timed out") || reason.contains("timeout") => {
                        // 超时错误（如 8s 无响应）不再额外重试，避免连续死等拖死巡检流水线
                        error_count += 1;
                        break ProbeOutcome::Transient {
                            reason,
                            latency_ms,
                        };
                    }
                    ProbeOutcome::Transient { reason, latency_ms } if retried >= MODEL_MAX_RETRIES => {
                        error_count += 1;
                        attempt_reasons.push(reason.clone());
                        break ProbeOutcome::Transient {
                            reason: format!(
                                "{} (重试{retried}次后仍失败)",
                                attempt_reasons[0]
                            ),
                            latency_ms,
                        };
                    }
                    ProbeOutcome::Transient { reason, .. } => {
                        attempt_reasons.push(reason.clone());
                        self.interruptible_sleep(PROBE_RETRY_GAP_MS);
                        if self.cancel_requested.load(Ordering::SeqCst) {
                            error_count += 1;
                            break ProbeOutcome::Transient {
                                reason: format!(
                                    "{} (巡检已取消，重试中断)",
                                    attempt_reasons[0]
                                ),
                                latency_ms: 0,
                            };
                        }
                        outcome = self.probe_model(home, target);
                        retried += 1;
                    }
                }
            };

            self.record_probe(
                &target.connection_id,
                &target.provider_key,
                &target.provider_name,
                &target.slug,
                &target.label,
                &target.raw_model,
                &final_outcome,
                retried,
            );
            self.record_job_result(&scoped_model_id, &final_outcome);

            // 记录该模型探测完成，推进进度到 idx+1
            self.update_job_progress(idx + 1, total, &scoped_model_id);

            // Mandatory gap between sequential requests (1500ms)
            if idx + 1 < total {
                self.interruptible_sleep(PROBE_GAP_MS);
            }
            if self.cancel_requested.load(Ordering::SeqCst) {
                break;
            }
        }

        if !self.cancel_requested.load(Ordering::SeqCst) && total > 0 {
            self.update_job_progress(total, total, "");
        }

        let was_cancelled = self.cancel_requested.load(Ordering::SeqCst);
        let checked_so_far = available_count + unavailable_count + error_count + skipped_count;
        let unchecked_count = if total > checked_so_far { total - checked_so_far } else { 0 };
        let summary = json!({
            "total": total,
            "available": available_count,
            "unavailable": unavailable_count,
            "error": error_count,
            "skipped": skipped_count,
            "unchecked": unchecked_count,
            "cancelled": was_cancelled,
        });

        self.finish_job(summary);
    }

    /// Probes a single model by dispatching to the appropriate provider mechanism.
    fn probe_model(&self, home: &str, target: &ModelTarget) -> ProbeOutcome {
        let scoped_model_string = format!(
            "{}/{}@{}",
            target.provider_key, target.raw_model, target.slug
        );

        // Resolve upstream endpoint using gateway's native resolution
        let upstream = match GatewayServer::resolve_upstream_endpoint_for_home_with_exclusions(
            home,
            &scoped_model_string,
            &[],
        ) {
            Ok(u) => u,
            Err(e) => {
                return ProbeOutcome::Transient {
                    reason: format!("网关解析上游端点失败: {e}"),
                    latency_ms: 0,
                };
            }
        };

        if upstream.codex_home.is_some() {
            self.probe_codex(&upstream, &target.raw_model)
        } else if upstream.provider_name == "Google Gemini" {
            self.probe_gemini(&upstream, &target.raw_model)
        } else {
            self.probe_generic_chat(&upstream, &target.raw_model)
        }
    }

    fn run_interruptible_curl(
        &self,
        mut cmd: Command,
        max_time_secs: u64,
        _stdin_data: Option<&[u8]>,
    ) -> Result<std::process::Output, String> {
        // 载荷通过 argv 中的 --data-binary 传入，此处不再走 stdin，避免时序问题
        cmd.stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        let child = cmd.spawn().map_err(|e| format!("启动 curl 失败: {e}"))?;
        let pid = child.id();
        self.active_child_pid.store(pid, Ordering::SeqCst);

        let handle = thread::spawn(move || child.wait_with_output());
        let start = Instant::now();
        let timeout = Duration::from_secs(max_time_secs);

        while !handle.is_finished() {
            if self.cancel_requested.load(Ordering::SeqCst) {
                self.active_child_pid.store(0, Ordering::SeqCst);
                #[cfg(unix)]
                unsafe {
                    kill(pid as i32, 9);
                }
                let _ = handle.join();
                return Err("用户已取消巡检任务".to_string());
            }

            if start.elapsed() > timeout {
                self.active_child_pid.store(0, Ordering::SeqCst);
                #[cfg(unix)]
                unsafe {
                    kill(pid as i32, 9);
                }
                let _ = handle.join();
                return Err(format!("探测超时 (超过 {max_time_secs}s 未响应)"));
            }

            thread::sleep(Duration::from_millis(50));
        }

        self.active_child_pid.store(0, Ordering::SeqCst);
        match handle.join() {
            Ok(Ok(output)) => Ok(output),
            Ok(Err(e)) => Err(format!("读取输出失败: {e}")),
            Err(_) => Err("等待子进程异常".to_string()),
        }
    }

    /// Gemini probe via Cloud Code
    fn probe_gemini(&self, upstream: &UpstreamEndpoint, _raw_model: &str) -> ProbeOutcome {
        let start = Instant::now();
        let project = upstream
            .project
            .as_deref()
            .unwrap_or("cloudcode-pa-user-project");

        let gen_request = json!({
            "contents": [{
                "role": "user",
                "parts": [{"text": "ping"}]
            }]
        });

        let payload = GatewayServer::cloud_code_generate_payload(
            project,
            &upstream.target_model,
            gen_request,
            &format!("probe-{}", Self::now_epoch_secs()),
        );

        let mut cmd = Command::new("curl");
        cmd.arg("-sS")
            .arg("--fail-with-body")
            .arg("--connect-timeout")
            .arg("5")
            .arg("--max-time")
            .arg(PROBE_TIMEOUT_SECS.to_string())
            .arg("--data-binary")
            .arg(payload.to_string())
            .arg("-X")
            .arg("POST")
            .arg(&upstream.url)
            .arg("-H")
            .arg(format!("Authorization: {}", upstream.auth_header))
            .arg("-H")
            .arg("Content-Type: application/json")
            .arg("-H")
            .arg("User-Agent: antigravity")
            .arg("-H")
            .arg(r#"Client-Metadata: {"ideType":"ANTIGRAVITY"}"#);

        for (name, value) in &upstream.extra_headers {
            cmd.arg("-H").arg(format!("{name}: {value}"));
        }

        let payload_bytes = payload.to_string().into_bytes();
        let output = match self.run_interruptible_curl(cmd, PROBE_TIMEOUT_SECS, Some(&payload_bytes)) {
            Ok(o) => o,
            Err(e) => {
                let latency_ms = start.elapsed().as_millis() as u64;
                return ProbeOutcome::Transient {
                    reason: format!("网络连接或请求失败: {e}"),
                    latency_ms,
                };
            }
        };

        let latency_ms = start.elapsed().as_millis() as u64;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            return Self::classify_gemini_http_error(&stderr, &stdout, latency_ms);
        }

        let stdout_str = String::from_utf8_lossy(&output.stdout);
        let Ok(body) = serde_json::from_str::<Value>(&stdout_str) else {
            return ProbeOutcome::Transient {
                reason: "上游返回非 JSON 格式响应".into(),
                latency_ms,
            };
        };

        // Check for error payload
        if let Some(err) = body.get("error") {
            let msg = err
                .get("message")
                .and_then(|m| m.as_str())
                .unwrap_or("未知上游错误");
            return Self::classify_gemini_error_message(msg, latency_ms);
        }

        // Extract text or tool calls
        let parts = body
            .pointer("/response/candidates/0/content/parts")
            .or_else(|| body.pointer("/candidates/0/content/parts"))
            .and_then(|v| v.as_array());

        if let Some(parts_arr) = parts {
            let mut has_answer_text = false;
            let mut has_thought_text = false;
            let mut has_tool_call = false;

            for part in parts_arr {
                if part.get("functionCall").is_some() {
                    has_tool_call = true;
                }
                if part.get("thoughtSignature").is_some() {
                    has_thought_text = true;
                }
                if let Some(txt) = part.get("text").and_then(|t| t.as_str()) {
                    if !txt.trim().is_empty() {
                        if part.get("thought").and_then(|t| t.as_bool()).unwrap_or(false) {
                            has_thought_text = true;
                        } else {
                            has_answer_text = true;
                        }
                    }
                }
            }

            if has_answer_text || has_tool_call || has_thought_text {
                return ProbeOutcome::Available { latency_ms };
            }
        }

        // Extract finishReason and promptFeedback for diagnosis
        let finish_reason = body
            .pointer("/response/candidates/0/finishReason")
            .or_else(|| body.pointer("/candidates/0/finishReason"))
            .and_then(|v| v.as_str())
            .unwrap_or("UNKNOWN");

        let snippet: String = stdout_str.chars().take(200).collect();
        ProbeOutcome::Transient {
            reason: format!("上游未返回内容 (finishReason: {finish_reason}; 片段: {snippet})"),
            latency_ms,
        }
    }

    /// Codex probe via Responses HTTP/SSE
    fn probe_codex(&self, upstream: &UpstreamEndpoint, _raw_model: &str) -> ProbeOutcome {
        let start = Instant::now();
        let codex_home = upstream.codex_home.as_deref().unwrap_or("");
        let token = match GatewayServer::codex_oauth_access_token(codex_home) {
            Ok(t) => t,
            Err(e) => {
                return ProbeOutcome::Transient {
                    reason: format!("获取 Codex OAuth token 失败: {e}"),
                    latency_ms: 0,
                };
            }
        };

        let payload = json!({
            "model": upstream.target_model,
            "store": false,
            "stream": true,
            "input": [{
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "ping"}]
            }]
        });

        let target_url = if upstream.url.trim().is_empty() {
            "https://chatgpt.com/backend-api/codex/responses"
        } else {
            &upstream.url
        };

        let mut cmd = Command::new("curl");
        cmd.arg("-sN")
            .arg("--connect-timeout")
            .arg("5")
            .arg("--max-time")
            .arg(PROBE_TIMEOUT_SECS.to_string())
            .arg("--data-binary")
            .arg(payload.to_string())
            .arg("-X")
            .arg("POST")
            .arg(target_url)
            .arg("-H")
            .arg(format!("Authorization: Bearer {token}"))
            .arg("-H")
            .arg("Content-Type: application/json")
            .arg("-H")
            .arg("User-Agent: codex_cli_rs/0.153.4")
            .arg("-H")
            .arg("OpenAI-Beta: responses=v1");

        let payload_bytes = payload.to_string().into_bytes();
        let output = match self.run_interruptible_curl(cmd, PROBE_TIMEOUT_SECS, Some(&payload_bytes)) {
            Ok(o) => o,
            Err(e) => {
                let latency_ms = start.elapsed().as_millis() as u64;
                return ProbeOutcome::Transient {
                    reason: format!("curl 执行失败: {e}"),
                    latency_ms,
                };
            }
        };

        let latency_ms = start.elapsed().as_millis() as u64;
        let stdout = String::from_utf8_lossy(&output.stdout);

        if stdout.contains("response.output_text.delta")
            || stdout.contains("response.output_item.done")
            || stdout.contains("response.completed")
        {
            return ProbeOutcome::Available { latency_ms };
        }

        // Check for error JSON in output
        for line in stdout.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with('{') {
                if let Ok(val) = serde_json::from_str::<Value>(trimmed) {
                    if let Some(detail) = val.get("detail").and_then(|v| v.as_str()) {
                        let lower = detail.to_lowercase();
                        if lower.contains("not found") || lower.contains("unsupported") {
                            return ProbeOutcome::HardFail {
                                reason: format!("Codex 错误: {detail}"),
                                latency_ms,
                            };
                        }
                        return ProbeOutcome::Transient {
                            reason: format!("Codex 提示: {detail}"),
                            latency_ms,
                        };
                    }
                }
            }
        }

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return ProbeOutcome::Transient {
                reason: format!("Codex 连接失败: {stderr}"),
                latency_ms,
            };
        }

        ProbeOutcome::Transient {
            reason: "Codex 未返回有效的 SSE 事件流".into(),
            latency_ms,
        }
    }

    /// Generic OpenAI-compatible chat/completions probe
    fn probe_generic_chat(&self, upstream: &UpstreamEndpoint, _raw_model: &str) -> ProbeOutcome {
        let start = Instant::now();
        let payload = json!({
            "model": upstream.target_model,
            "messages": [{"role": "user", "content": "ping"}],
            "stream": false
        });

        let mut cmd = Command::new("curl");
        cmd.arg("-sS")
            .arg("--fail-with-body")
            .arg("--connect-timeout")
            .arg("5")
            .arg("--max-time")
            .arg(PROBE_TIMEOUT_SECS.to_string())
            .arg("--data-binary")
            .arg(payload.to_string())
            .arg("-X")
            .arg("POST")
            .arg(&upstream.url)
            .arg("-H")
            .arg(format!("Authorization: {}", upstream.auth_header))
            .arg("-H")
            .arg("Content-Type: application/json");

        for (k, v) in &upstream.extra_headers {
            cmd.arg("-H").arg(format!("{k}: {v}"));
        }

        let payload_bytes = payload.to_string().into_bytes();
        let output = match self.run_interruptible_curl(cmd, PROBE_TIMEOUT_SECS, Some(&payload_bytes)) {
            Ok(o) => o,
            Err(e) => {
                let latency_ms = start.elapsed().as_millis() as u64;
                return ProbeOutcome::Transient {
                    reason: format!("curl 执行失败: {e}"),
                    latency_ms,
                };
            }
        };

        let latency_ms = start.elapsed().as_millis() as u64;
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        if !output.status.success() {
            return Self::classify_generic_http_error(&stderr, &stdout, latency_ms);
        }

        if let Ok(body) = serde_json::from_str::<Value>(&stdout) {
            if let Some(err) = body.get("error") {
                let msg = err
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("未知上游错误");
                return Self::classify_generic_error_message(msg, latency_ms);
            }

            if let Some(choices) = body.get("choices").and_then(|v| v.as_array()) {
                if let Some(choice) = choices.first() {
                    let has_content = choice
                        .pointer("/message/content")
                        .and_then(|c| c.as_str())
                        .map(|s| !s.trim().is_empty())
                        .unwrap_or(false);
                    let has_tools = choice
                        .pointer("/message/tool_calls")
                        .and_then(|t| t.as_array())
                        .map(|a| !a.is_empty())
                        .unwrap_or(false);

                    if has_content || has_tools {
                        return ProbeOutcome::Available { latency_ms };
                    }
                }
            }
        }

        let snippet: String = stdout.chars().take(150).collect();
        ProbeOutcome::Transient {
            reason: format!("响应格式异常或 choices 为空: {snippet}"),
            latency_ms,
        }
    }

    // -----------------------------------------------------------------------
    // Error Classification Classifiers
    // -----------------------------------------------------------------------

    pub fn classify_gemini_http_error(stderr: &str, stdout: &str, latency_ms: u64) -> ProbeOutcome {
        if let Ok(body) = serde_json::from_str::<Value>(stdout) {
            if let Some(err) = body.get("error") {
                let msg = err
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("");
                if !msg.is_empty() {
                    return Self::classify_gemini_error_message(msg, latency_ms);
                }
            }
        }

        if stderr.contains("returned error: 404") {
            ProbeOutcome::HardFail {
                reason: "HTTP 404: 模型不存在或未开放".into(),
                latency_ms,
            }
        } else if stderr.contains("returned error: 400") {
            ProbeOutcome::HardFail {
                reason: "HTTP 400: 请求格式或模型参数不被支持".into(),
                latency_ms,
            }
        } else if stderr.contains("returned error: 429") {
            ProbeOutcome::Transient {
                reason: "HTTP 429: 配额或速率受限".into(),
                latency_ms,
            }
        } else if stderr.contains("returned error: 503") {
            ProbeOutcome::Transient {
                reason: "HTTP 503: 上游服务过载，建议稍后重试".into(),
                latency_ms,
            }
        } else if stderr.contains("timed out") || stderr.contains("Connection timeout") {
            ProbeOutcome::Transient {
                reason: "连接超时，网络波动".into(),
                latency_ms,
            }
        } else {
            let msg = stderr.trim();
            ProbeOutcome::Transient {
                reason: format!("上游 HTTP 错误: {msg}"),
                latency_ms,
            }
        }
    }

    pub fn classify_gemini_error_message(msg: &str, latency_ms: u64) -> ProbeOutcome {
        let lower = msg.to_lowercase();
        let hard_keywords = [
            "not found",
            "unsupported",
            "does not exist",
            "invalid model",
            "is disabled",
            "not supported",
        ];
        if hard_keywords.iter().any(|k| lower.contains(k)) {
            ProbeOutcome::HardFail {
                reason: format!("模型不可用: {msg}"),
                latency_ms,
            }
        } else {
            ProbeOutcome::Transient {
                reason: format!("上游提示: {msg}"),
                latency_ms,
            }
        }
    }

    pub fn classify_generic_http_error(
        stderr: &str,
        stdout: &str,
        latency_ms: u64,
    ) -> ProbeOutcome {
        // First inspect stdout if it contains an error JSON
        if let Ok(body) = serde_json::from_str::<Value>(stdout) {
            if let Some(err) = body.get("error") {
                let msg = err
                    .get("message")
                    .and_then(|m| m.as_str())
                    .unwrap_or("");
                if !msg.is_empty() {
                    return Self::classify_generic_error_message(msg, latency_ms);
                }
            }
        }

        if stderr.contains("returned error: 404") {
            ProbeOutcome::HardFail {
                reason: "HTTP 404: 模型未找到".into(),
                latency_ms,
            }
        } else if stderr.contains("returned error: 400") || stderr.contains("returned error: 422") {
            ProbeOutcome::HardFail {
                reason: "HTTP 400/422: 模型不支持该请求格式".into(),
                latency_ms,
            }
        } else if stderr.contains("returned error: 429") {
            ProbeOutcome::Transient {
                reason: "HTTP 429: 配额用尽或限流".into(),
                latency_ms,
            }
        } else if stderr.contains("timed out") || stderr.contains("Connection timeout") {
            ProbeOutcome::Transient {
                reason: "网络连接超时".into(),
                latency_ms,
            }
        } else {
            let snippet: String = stderr.chars().take(120).collect();
            ProbeOutcome::Transient {
                reason: format!("上游请求失败: {snippet}"),
                latency_ms,
            }
        }
    }

    pub fn classify_generic_error_message(msg: &str, latency_ms: u64) -> ProbeOutcome {
        let lower = msg.to_lowercase();
        let hard_keywords = [
            "unsupported model",
            "model is unavailable",
            "endpoint is unavailable",
            "no allowed providers",
            "not supported for format",
            "model not found",
            "does not exist",
            "invalid model",
            "requires explicit opt in",
            "unknown model",
        ];
        if hard_keywords.iter().any(|k| lower.contains(k)) {
            ProbeOutcome::HardFail {
                reason: format!("模型硬性不可用: {msg}"),
                latency_ms,
            }
        } else {
            ProbeOutcome::Transient {
                reason: format!("上游瞬时错误: {msg}"),
                latency_ms,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_classify_hard_keywords() {
        let outcome = ModelHealthEngine::classify_generic_error_message(
            "Unsupported model mimo-v2-omni",
            120,
        );
        match outcome {
            ProbeOutcome::HardFail { reason, latency_ms } => {
                assert!(reason.contains("mimo-v2-omni"));
                assert_eq!(latency_ms, 120);
            }
            _ => panic!("Expected HardFail"),
        }

        let outcome2 = ModelHealthEngine::classify_generic_error_message(
            "Rate limit exceeded; please wait",
            150,
        );
        match outcome2 {
            ProbeOutcome::Transient { reason, .. } => {
                assert!(reason.contains("Rate limit"));
            }
            _ => panic!("Expected Transient"),
        }
    }

    #[test]
    fn test_filter_models_payload_strict() {
        let engine = ModelHealthEngine::new_with_path(None);

        // Record 1 available, 1 unavailable, 1 error
        engine.record_probe(
            "cid1",
            "google",
            "Google Gemini",
            "test-google-12345678",
            "test label",
            "gemini-good",
            &ProbeOutcome::Available { latency_ms: 100 },
            0,
        );
        engine.record_probe(
            "cid1",
            "google",
            "Google Gemini",
            "test-google-12345678",
            "test label",
            "gemini-bad",
            &ProbeOutcome::HardFail {
                reason: "not found".into(),
                latency_ms: 100,
            },
            0,
        );
        engine.record_probe(
            "cid1",
            "google",
            "Google Gemini",
            "test-google-12345678",
            "test label",
            "gemini-err",
            &ProbeOutcome::Transient {
                reason: "503".into(),
                latency_ms: 100,
            },
            0,
        );

        let input_payload = json!({
            "object": "list",
            "data": [
                {"id": "google/gemini-good@test-google-12345678"},
                {"id": "google/gemini-bad@test-google-12345678"},
                {"id": "google/gemini-err@test-google-12345678"},
                {"id": "google/gemini-unchecked@test-google-12345678"}
            ]
        });

        let filtered = engine.filter_models_payload(input_payload);
        let data = filtered["data"].as_array().unwrap();

        // Strict mode: ONLY gemini-good (available) is kept; error, bad and unchecked all dropped
        assert_eq!(data.len(), 1);
        assert_eq!(data[0]["id"], "google/gemini-good@test-google-12345678");
    }

    #[test]
    fn test_filter_consolidated_models_requires_available() {
        let engine = ModelHealthEngine::new_with_path(None);

        // Account 1: gemini-pro is error
        engine.record_probe(
            "cid1",
            "google",
            "Google Gemini",
            "acc1-google-11111111",
            "acc1",
            "gemini-pro",
            &ProbeOutcome::Transient {
                reason: "503 overloaded".into(),
                latency_ms: 100,
            },
            0,
        );

        // Account 2: gemini-flash is available
        engine.record_probe(
            "cid2",
            "google",
            "Google Gemini",
            "acc2-google-22222222",
            "acc2",
            "gemini-flash",
            &ProbeOutcome::Available { latency_ms: 80 },
            0,
        );

        let input_payload = json!({
            "object": "list",
            "data": [
                {"id": "google/gemini-pro"},
                {"id": "google/gemini-flash"}
            ]
        });

        let filtered = engine.filter_models_payload(input_payload);
        let data = filtered["data"].as_array().unwrap();

        // ONLY gemini-flash is kept. gemini-pro has only error accounts so dropped!
        assert_eq!(data.len(), 1);
        assert_eq!(data[0]["id"], "google/gemini-flash");
    }

    #[test]
    fn test_staged_probes_committed_on_finish_job() {
        let engine = ModelHealthEngine::new_with_path(None);

        // Initial historical state: model-1 is available
        engine.record_probe(
            "cid1",
            "google",
            "Google Gemini",
            "slug1",
            "acc1",
            "model-1",
            &ProbeOutcome::Available { latency_ms: 50 },
            0,
        );

        {
            let data = engine.data.lock().unwrap();
            assert_eq!(data.accounts["cid1"].models["model-1"].status, "available");
        }

        // Start an inspection job
        assert!(engine.try_start_job("all", 2).is_ok());

        // Probe 1: model-1 is now unavailable
        engine.record_probe(
            "cid1",
            "google",
            "Google Gemini",
            "slug1",
            "acc1",
            "model-1",
            &ProbeOutcome::HardFail {
                reason: "Quota exceeded".into(),
                latency_ms: 100,
            },
            0,
        );

        // While job is running: engine.data MUST STILL HOLD THE HISTORICAL AVAILABLE STATUS!
        {
            let data = engine.data.lock().unwrap();
            assert_eq!(
                data.accounts["cid1"].models["model-1"].status,
                "available",
                "Historical record must not be overwritten during inspection"
            );
        }

        // Finish the job
        engine.finish_job(json!({"total": 1, "done": 1}));

        // Now engine.data is updated with the new inspection results!
        {
            let data = engine.data.lock().unwrap();
            assert_eq!(
                data.accounts["cid1"].models["model-1"].status,
                "unavailable",
                "Inspection results must commit after job finishes"
            );
        }
    }

    #[test]
    fn job_status_reports_each_completed_probe_result() {
        let engine = ModelHealthEngine::new_with_path(None);
        assert!(engine.try_start_job("all", 2).is_ok());
        engine.update_job_progress(0, 2, "google/gemini-pro@example");
        engine.record_job_result(
            "google/gemini-pro@example",
            &ProbeOutcome::Available { latency_ms: 84 },
        );

        let payload = engine.job_status_payload();
        let results = payload["results"].as_array().unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["scopedId"], "google/gemini-pro@example");
        assert_eq!(results[0]["status"], "available");
        assert_eq!(results[0]["latencyMs"], 84);

        engine.finish_job(json!({"total": 2, "cancelled": false}));
        assert!(engine.try_start_job("all", 1).is_ok());
        assert!(engine.job_status_payload()["results"]
            .as_array()
            .unwrap()
            .is_empty());
    }

    #[test]
    fn test_provider_matches() {
        assert!(ModelHealthEngine::provider_matches("codex", "openai"));
        assert!(ModelHealthEngine::provider_matches("openai", "codex"));
        assert!(ModelHealthEngine::provider_matches("openai", "openai"));
        assert!(ModelHealthEngine::provider_matches("gemini", "google"));
        assert!(ModelHealthEngine::provider_matches("google", "gemini"));
        assert!(ModelHealthEngine::provider_matches("deepseek", "deepseek"));
        assert!(ModelHealthEngine::provider_matches("opencode", "opencode"));
        assert!(!ModelHealthEngine::provider_matches("google", "openai"));
        assert!(!ModelHealthEngine::provider_matches("deepseek", "opencode"));
    }
}
