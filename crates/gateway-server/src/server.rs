use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use gateway_ir::FinishReason;
use gateway_routing::RouteTable;
use gateway_state::{TelemetryEvent, TelemetryQueryFilter, TelemetryStore};
use gateway_stream::event::{ResponseCompleted, ResponseStarted, TextDelta};
use gateway_stream::StreamEvent;
use protocol_anthropic_messages::{
    decode_anthropic_request, encode_anthropic_stream_event, AnthropicMessagesRequest,
};
use protocol_openai_chat::{decode_chat_request, encode_chat_stream_event, OpenAiChatRequest};
use protocol_openai_responses::{
    decode_responses_request, encode_responses_stream_event, OpenAiResponsesRequest,
};

use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, OnceLock, RwLock};
use std::time::{Duration, Instant};

/// A short-lived in-memory cache of the codex CLI's servable-model catalog,
/// keyed by the connected runtime's `CODEX_HOME`. This lets the hot routing
/// path avoid re-spawning the `codex` CLI on every request while still picking
/// up newly released models automatically once the entry expires.
struct CodexCatalogEntry {
    fetched: Instant,
    catalog: Vec<serde_json::Value>,
}
static CODEX_CATALOG_CACHE: OnceLock<Mutex<HashMap<String, CodexCatalogEntry>>> = OnceLock::new();

#[derive(Default)]
pub struct AccountDynamicState {
    pub cooldown_map: HashMap<String, Instant>,
    pub last_served_map: HashMap<String, Instant>,
}

impl AccountDynamicState {
    pub fn global() -> &'static Mutex<AccountDynamicState> {
        static STATE: OnceLock<Mutex<AccountDynamicState>> = OnceLock::new();
        STATE.get_or_init(|| Mutex::new(AccountDynamicState::default()))
    }

    pub fn is_cooling_down(&self, id: &str) -> bool {
        if let Some(&expires) = self.cooldown_map.get(id) {
            Instant::now() < expires
        } else {
            false
        }
    }

    pub fn mark_cooldown(&mut self, id: &str, duration: Duration) {
        self.cooldown_map.insert(id.to_string(), Instant::now() + duration);
    }

    pub fn record_served(&mut self, id: &str) {
        self.last_served_map.insert(id.to_string(), Instant::now());
    }

    pub fn last_served(&self, id: &str) -> Option<Instant> {
        self.last_served_map.get(id).copied()
    }

    pub fn cooling_down_count(&self) -> usize {
        let now = Instant::now();
        self.cooldown_map.values().filter(|&&exp| exp > now).count()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProxyCallResult {
    Completed,
    RetryableFailover(String),
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayRequestRecord {
    pub id: String,
    pub time: String,
    pub agent: String,
    pub ingress_protocol: String,
    pub model_alias: String,
    pub target_provider: String,
    pub target_model: String,
    pub latency_ms: u64,
    pub ttft_ms: u64,
    pub tokens: usize,
    pub fidelity: String,
    pub status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayAutomationTask {
    pub id: String,
    pub name: String,
    #[serde(default = "default_automation_task_type")]
    pub task_type: String,
    #[serde(default = "default_automation_task_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub providers: Vec<String>,
    #[serde(default = "default_automation_task_all_accounts")]
    pub all_accounts: bool,
    #[serde(default)]
    pub account_ids: Vec<String>,
    #[serde(default)]
    pub hours: Vec<u8>,
    #[serde(default)]
    pub last_run_at: Option<i64>,
    #[serde(default)]
    pub last_run_status: Option<String>,
    #[serde(default)]
    pub last_run_summary: Option<String>,
}

/// 一次自动化任务的执行记录。
///
/// 字段必须与 `app/Codexling/Sources/Codexling/GatewaySettings.swift` 中的
/// `GatewayAutomationRunLog` 保持一致：网关进程与 App 写的是同一个
/// `gateway-settings.json`，任何字段名/类型漂移都会让 App 端解码失败。
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayAutomationRunLog {
    pub id: String,
    pub task_id: String,
    pub task_name: String,
    #[serde(default = "default_automation_task_type")]
    pub task_type: String,
    pub started_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_success: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    /// 本次巡检是否被用户取消。取消不是失败：App 端据此展示「已取消」而不是「失败」。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cancelled: Option<bool>,
    /// 单次巡检的逐个模型探测结果。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub results: Option<Vec<crate::model_health::JobProbeResult>>,
}

/// 与 App 端 `GatewayStore.maxAutomationRunLogs` 保持一致。
pub const MAX_AUTOMATION_RUN_LOGS: usize = 300;

fn default_automation_task_type() -> String {
    "modelHealthCheck".to_string()
}
fn default_automation_task_enabled() -> bool {
    true
}
fn default_automation_task_all_accounts() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewayModelCapabilityOverride {
    pub model_id: String,
    #[serde(default)]
    pub context_window: Option<u64>,
    #[serde(default)]
    pub max_tokens: Option<u64>,
    #[serde(default)]
    pub supports_image: Option<bool>,
    #[serde(default)]
    pub reasoning_levels: Option<Vec<String>>,
    #[serde(default)]
    pub default_reasoning_level: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatewaySettings {
    #[serde(rename = "$schemaVersion", default = "default_gateway_settings_schema_version")]
    pub schema_version: u32,
    #[serde(default)]
    pub model_consolidation_enabled: bool,
    #[serde(default)]
    pub consolidated_providers: Vec<String>,
    #[serde(default)]
    pub provider_routing_modes: HashMap<String, String>,
    #[serde(default)]
    pub provider_pinned_accounts: HashMap<String, String>,
    #[serde(default = "default_gateway_settings_allow_failover")]
    pub allow_failover: bool,
    #[serde(default = "default_gateway_settings_cooldown_seconds")]
    pub cooldown_seconds: u64,
    #[serde(default = "default_gateway_settings_max_failover_retries")]
    pub max_failover_retries: usize,
    #[serde(default)]
    pub auto_check_on_startup_with_history: bool,
    #[serde(default = "default_gateway_settings_health_check_interval")]
    pub health_check_interval: String,
    #[serde(default)]
    pub automation_tasks: Vec<GatewayAutomationTask>,
    #[serde(default)]
    pub automation_run_logs: Vec<GatewayAutomationRunLog>,
    #[serde(default)]
    pub model_capability_overrides: HashMap<String, GatewayModelCapabilityOverride>,
    #[serde(default)]
    pub allow_lan_access: bool,
    #[serde(default)]
    pub auth_token: Option<String>,
}

fn default_gateway_settings_schema_version() -> u32 {
    1
}
fn default_gateway_settings_allow_failover() -> bool {
    true
}
fn default_gateway_settings_cooldown_seconds() -> u64 {
    300
}
fn default_gateway_settings_max_failover_retries() -> usize {
    2
}
fn default_gateway_settings_health_check_interval() -> String {
    "1h".to_string()
}

impl Default for GatewaySettings {
    fn default() -> Self {
        Self {
            schema_version: 1,
            model_consolidation_enabled: false,
            consolidated_providers: Vec::new(),
            provider_routing_modes: HashMap::new(),
            provider_pinned_accounts: HashMap::new(),
            allow_failover: true,
            cooldown_seconds: 300,
            max_failover_retries: 2,
            auto_check_on_startup_with_history: false,
            health_check_interval: "1h".to_string(),
            automation_tasks: Vec::new(),
            automation_run_logs: Vec::new(),
            model_capability_overrides: HashMap::new(),
            allow_lan_access: false,
            auth_token: None,
        }
    }
}

impl GatewaySettings {
    pub fn is_provider_consolidated(&self, provider: &str) -> bool {
        let p = provider.trim().to_ascii_lowercase();
        if self.consolidated_providers.iter().any(|item| item.trim().eq_ignore_ascii_case(&p)) {
            return true;
        }
        if (p == "openai" || p == "codex")
            && self.consolidated_providers.iter().any(|item| {
                let s = item.trim().to_ascii_lowercase();
                s == "openai" || s == "codex"
            })
        {
            return true;
        }
        if (p == "google" || p == "gemini")
            && self.consolidated_providers.iter().any(|item| {
                let s = item.trim().to_ascii_lowercase();
                s == "google" || s == "gemini"
            })
        {
            return true;
        }
        // Fallback for backwards compatibility
        if self.consolidated_providers.is_empty() && self.model_consolidation_enabled {
            return true;
        }
        false
    }
    pub fn routing_mode_for_provider(&self, provider: &str) -> &str {
        let p = provider.trim().to_ascii_lowercase();
        let raw_mode = if let Some(mode) = self.provider_routing_modes.get(&p) {
            mode.as_str()
        } else if p == "google" || p == "gemini" {
            self.provider_routing_modes
                .get("google")
                .or_else(|| self.provider_routing_modes.get("gemini"))
                .map(|s| s.as_str())
                .unwrap_or("smooth")
        } else if p == "openai" || p == "codex" {
            self.provider_routing_modes
                .get("openai")
                .or_else(|| self.provider_routing_modes.get("codex"))
                .map(|s| s.as_str())
                .unwrap_or("smooth")
        } else {
            "smooth"
        };

        if raw_mode == "stickyHighQuota" {
            "smooth"
        } else {
            raw_mode
        }
    }

    pub fn pinned_account_for_provider(&self, provider: &str) -> Option<&str> {
        let p = provider.trim().to_ascii_lowercase();
        if let Some(id) = self.provider_pinned_accounts.get(&p).filter(|s| !s.trim().is_empty()) {
            return Some(id.as_str());
        }
        if p == "google" || p == "gemini" {
            if let Some(id) = self
                .provider_pinned_accounts
                .get("google")
                .or_else(|| self.provider_pinned_accounts.get("gemini"))
                .filter(|s| !s.trim().is_empty())
            {
                return Some(id.as_str());
            }
        }
        if p == "openai" || p == "codex" {
            if let Some(id) = self
                .provider_pinned_accounts
                .get("openai")
                .or_else(|| self.provider_pinned_accounts.get("codex"))
                .filter(|s| !s.trim().is_empty())
            {
                return Some(id.as_str());
            }
        }
        None
    }

    pub fn health_check_interval_seconds(&self) -> i64 {
        match self.health_check_interval.trim().to_ascii_lowercase().as_str() {
            "6h" => 6 * 3600,
            "1d" | "24h" | "midnight" => 24 * 3600,
            _ => 3600, // default 1h
        }
    }

    /// Check if a daily check at midnight (00:00 local time) is due.
    /// Returns true if local time has reached 00:00 of a calendar day that is later than
    /// the calendar day of last_check_epoch, or if at least 24 hours have elapsed.
    pub fn is_midnight_due(last_check_epoch: i64, now_epoch: i64) -> bool {
        if now_epoch < last_check_epoch {
            return false;
        }
        if now_epoch - last_check_epoch >= 86400 {
            return true;
        }
        // Extract local calendar days (YYYY, MM, DD) for both timestamps
        let (last_y, last_m, last_d) = Self::epoch_to_local_ymd(last_check_epoch);
        let (now_y, now_m, now_d) = Self::epoch_to_local_ymd(now_epoch);
        (now_y, now_m, now_d) > (last_y, last_m, last_d)
    }

    pub fn epoch_to_local_ymd_h(epoch: i64) -> (i32, i32, i32, u8) {
        unsafe {
            let t = epoch as libc::time_t;
            let mut tm: libc::tm = std::mem::zeroed();
            libc::localtime_r(&t, &mut tm);
            (tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour as u8)
        }
    }

    fn epoch_to_local_ymd(epoch: i64) -> (i32, i32, i32) {
        let (y, m, d, _) = Self::epoch_to_local_ymd_h(epoch);
        (y, m, d)
    }

    pub fn is_task_due(task: &GatewayAutomationTask, now_epoch: i64) -> bool {
        if !task.enabled {
            return false;
        }
        let (now_y, now_m, now_d, now_h) = Self::epoch_to_local_ymd_h(now_epoch);
        if !task.hours.contains(&now_h) {
            return false;
        }
        if let Some(last_epoch) = task.last_run_at {
            let (last_y, last_m, last_d, last_h) = Self::epoch_to_local_ymd_h(last_epoch);
            if (last_y, last_m, last_d, last_h) == (now_y, now_m, now_d, now_h) {
                return false;
            }
        }
        true
    }

    pub fn load_for_home(home: &str) -> Self {
        let path = format!("{home}/Library/Application Support/Tomo/gateway-settings.json");
        std::fs::read_to_string(&path)
            .ok()
            .and_then(|content| serde_json::from_str::<GatewaySettings>(&content).ok())
            .unwrap_or_default()
    }

    /// 追加一条自动化任务执行记录（保留最近 `MAX_AUTOMATION_RUN_LOGS` 条）。
    pub fn push_automation_run_log(&mut self, log: GatewayAutomationRunLog) {
        self.automation_run_logs.push(log);
        if self.automation_run_logs.len() > MAX_AUTOMATION_RUN_LOGS {
            let overflow = self.automation_run_logs.len() - MAX_AUTOMATION_RUN_LOGS;
            self.automation_run_logs.drain(0..overflow);
        }
    }

    /// 按 id 补全一条执行记录的结束时点、结果、摘要与探测结果。
    pub fn finish_automation_run_log(
        &mut self,
        log_id: &str,
        finished_at: i64,
        is_success: bool,
        summary: &str,
        cancelled: bool,
        results: Option<Vec<crate::model_health::JobProbeResult>>,
    ) {
        if let Some(log) = self
            .automation_run_logs
            .iter_mut()
            .rev()
            .find(|log| log.id == log_id)
        {
            log.finished_at = Some(finished_at);
            log.is_success = Some(is_success);
            log.summary = Some(summary.to_string());
            log.cancelled = if cancelled { Some(true) } else { None };
            if results.is_some() {
                log.results = results;
            }
        }
    }

    /// 写入设置文件。
    ///
    /// 网关进程与 App 共用同一个 `gateway-settings.json`，而两边都不一定认识对方的
    /// 全部字段（例如 App 独有的键）。这里以「读旧文件 → 合并未知键 → 落盘」的方式写入，
    /// 避免整份覆盖把对方的字段（自动化执行日志等）抹掉。
    pub fn save_for_home(&self, home: &str) -> std::io::Result<()> {
        let dir = format!("{home}/Library/Application Support/Tomo");
        let _ = std::fs::create_dir_all(&dir);
        let path = format!("{dir}/gateway-settings.json");

        let mut value = serde_json::to_value(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;

        if let Ok(existing_raw) = std::fs::read_to_string(&path) {
            if let Ok(serde_json::Value::Object(existing)) =
                serde_json::from_str::<serde_json::Value>(&existing_raw)
            {
                if let serde_json::Value::Object(ref mut merged) = value {
                    for (key, old_value) in existing {
                        merged.entry(key).or_insert(old_value);
                    }
                }
            }
        }

        let content = serde_json::to_string_pretty(&value)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
        std::fs::write(&path, content)
    }

    pub fn persist_fallback_to_smooth(home: &str, provider: &str) {
        let mut settings = Self::load_for_home(home);
        let p = provider.trim().to_ascii_lowercase();
        settings.provider_routing_modes.insert(p.clone(), "smooth".to_string());
        settings.provider_pinned_accounts.remove(&p);
        if p == "google" {
            settings.provider_routing_modes.insert("gemini".to_string(), "smooth".to_string());
            settings.provider_pinned_accounts.remove("gemini");
        } else if p == "gemini" {
            settings.provider_routing_modes.insert("google".to_string(), "smooth".to_string());
            settings.provider_pinned_accounts.remove("google");
        } else if p == "openai" {
            settings.provider_routing_modes.insert("codex".to_string(), "smooth".to_string());
            settings.provider_pinned_accounts.remove("codex");
        } else if p == "codex" {
            settings.provider_routing_modes.insert("openai".to_string(), "smooth".to_string());
            settings.provider_pinned_accounts.remove("openai");
        }
        let _ = settings.save_for_home(home);
    }

    pub fn persist_switched_pinned_account(home: &str, provider: &str, new_pinned_id: &str) {
        let mut settings = Self::load_for_home(home);
        let p = provider.trim().to_ascii_lowercase();
        settings.provider_pinned_accounts.insert(p.clone(), new_pinned_id.to_string());
        if p == "google" {
            settings.provider_pinned_accounts.insert("gemini".to_string(), new_pinned_id.to_string());
        } else if p == "gemini" {
            settings.provider_pinned_accounts.insert("google".to_string(), new_pinned_id.to_string());
        } else if p == "openai" {
            settings.provider_pinned_accounts.insert("codex".to_string(), new_pinned_id.to_string());
        } else if p == "codex" {
            settings.provider_pinned_accounts.insert("openai".to_string(), new_pinned_id.to_string());
        }
        let _ = settings.save_for_home(home);
    }
}

#[cfg(test)]
mod tests {
    use super::{AccountDynamicState, GatewayServer, UpstreamEndpoint};
    use gateway_ir::ModelSelector;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    static NEXT_TEMP_HOME: AtomicUsize = AtomicUsize::new(0);

    fn temporary_home() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "tomo-gateway-models-{}-{}-{}",
            std::process::id(),
            NEXT_TEMP_HOME.fetch_add(1, Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    #[test]
    fn gemini_upstream_error_summary_includes_google_error_details() {
        let summary = GatewayServer::gemini_upstream_error_summary(
            br#"{
                "error": {
                    "code": 400,
                    "status": "INVALID_ARGUMENT",
                    "message": "Model is not available for this project",
                    "details": [
                        {"reason": "MODEL_NOT_FOUND"},
                        {"violations": [{"description": "Model access is disabled"}]},
                        {"retryDelay": "30s"}
                    ]
                }
            }"#,
        )
        .unwrap();

        assert!(summary.contains("HTTP 400"));
        assert!(summary.contains("INVALID_ARGUMENT"));
        assert!(summary.contains("Model is not available for this project"));
        assert!(summary.contains("MODEL_NOT_FOUND"));
        assert!(summary.contains("Model access is disabled"));
        assert!(summary.contains("30s"));
    }

    #[test]
    fn gemini_upstream_error_summary_handles_oauth_style_and_html_errors() {
        let oauth = GatewayServer::gemini_upstream_error_summary(
            br#"{"error":"invalid_grant","error_description":"expired"}"#,
        )
        .unwrap();
        assert!(oauth.contains("invalid_grant"));
        assert!(oauth.contains("expired"));

        let proxy = GatewayServer::gemini_upstream_error_summary(
            b"<html><title>Bad Request</title><body>Proxy rejected CONNECT</body></html>",
        )
        .unwrap();
        assert!(proxy.contains("Bad Request"));
        assert!(proxy.contains("Proxy rejected CONNECT"));
        assert!(!proxy.contains("<html>"));
    }

    #[test]
    fn diagnostic_excerpt_normalizes_and_truncates_messages() {
        assert_eq!(
            GatewayServer::diagnostic_excerpt(" one\n two\tthree ", 80),
            "one two three"
        );
        assert_eq!(GatewayServer::diagnostic_excerpt("abcdef", 4), "abcd…");
        assert_eq!(
            GatewayServer::diagnostic_excerpt(
                "Authorization: Bearer secret-token access_token=also-secret",
                200,
            ),
            "Authorization: [REDACTED] access_token=[REDACTED]"
        );
    }

    #[test]
    fn gemini_proxy_validation_prefers_remote_dns_for_socks() {
        assert_eq!(
            GatewayServer::validated_proxy_url("socks5://127.0.0.1:7892", true).as_deref(),
            Some("socks5h://127.0.0.1:7892")
        );
        assert_eq!(
            GatewayServer::validated_proxy_url("socks5h://127.0.0.1:7892", true).as_deref(),
            Some("socks5h://127.0.0.1:7892")
        );
        assert!(GatewayServer::validated_proxy_url("http://127.0.0.1:7892", true).is_none());
        assert!(GatewayServer::validated_proxy_url("--proxy evil", false).is_none());
    }

    #[test]
    fn gateway_settings_loads_default_and_from_disk() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(&support).unwrap();

        // 1. Default when file doesn't exist
        let default_settings = super::GatewaySettings::load_for_home(home.to_str().unwrap());
        assert_eq!(default_settings.schema_version, 1);
        assert!(!default_settings.model_consolidation_enabled);
        assert!(default_settings.allow_failover);
        assert_eq!(default_settings.cooldown_seconds, 300);
        assert_eq!(default_settings.max_failover_retries, 2);
        assert_eq!(default_settings.health_check_interval, "1h");
        assert!(!default_settings.allow_lan_access);
        assert_eq!(default_settings.auth_token, None);

        // 2. Custom settings when file exists
        fs::write(
            support.join("gateway-settings.json"),
            r#"{
                "$schemaVersion": 2,
                "modelConsolidationEnabled": true,
                "consolidatedProviders": ["google", "openai"],
                "providerRoutingModes": {
                    "google": "stickyHighQuota",
                    "openai": "pinnedAccount"
                },
                "providerPinnedAccounts": {
                    "openai": "acc-pinned-123"
                },
                "allowFailover": false,
                "cooldownSeconds": 600,
                "maxFailoverRetries": 4,
                "healthCheckInterval": "6h",
                "allowLanAccess": true,
                "authToken": "cdx_custom_token_12345"
            }"#,
        )
        .unwrap();
        let loaded = super::GatewaySettings::load_for_home(home.to_str().unwrap());
        assert!(loaded.model_consolidation_enabled);
        assert!(!loaded.allow_failover);
        assert_eq!(loaded.cooldown_seconds, 600);
        assert_eq!(loaded.max_failover_retries, 4);
        assert_eq!(loaded.health_check_interval, "6h");
        assert!(loaded.allow_lan_access);
        assert_eq!(loaded.auth_token, Some("cdx_custom_token_12345".to_string()));
        assert_eq!(loaded.routing_mode_for_provider("google"), "smooth"); // stickyHighQuota falls back to smooth
        assert_eq!(loaded.routing_mode_for_provider("openai"), "pinnedAccount");
        assert_eq!(loaded.routing_mode_for_provider("deepseek"), "smooth"); // default fallback
        assert_eq!(loaded.pinned_account_for_provider("openai"), Some("acc-pinned-123"));
        assert_eq!(loaded.pinned_account_for_provider("google"), None);

        // Test intervals
        assert_eq!(loaded.health_check_interval_seconds(), 6 * 3600);
        let mut daily = loaded.clone();
        daily.health_check_interval = "midnight".to_string();
        assert_eq!(daily.health_check_interval_seconds(), 24 * 3600);

        // Test midnight due logic:
        // Case 1: Same day earlier -> not due
        // Use fixed epoch: 2026-09-08 10:00:00 (approx 1788861600)
        // 2 hours later same day -> not due
        let t0 = 1788861600;
        assert!(!super::GatewaySettings::is_midnight_due(t0, t0 + 7200));
        // Case 2: >= 24h later -> due
        assert!(super::GatewaySettings::is_midnight_due(t0, t0 + 86400));
        // Case 3: Next day past midnight (e.g. 15 hours later cross midnight) -> due
        assert!(super::GatewaySettings::is_midnight_due(t0, t0 + 60000));
    }

    #[test]
    fn test_token_manager_rotation_and_grace_period_expiry() {
        let mut mgr = super::TokenManager::new_with_grace("initial-token", Duration::from_millis(50));
        assert!(mgr.is_valid("initial-token"));
        assert!(!mgr.is_valid("wrong-token"));

        mgr.rotate("new-rotated-token");
        assert_eq!(mgr.current_token(), "new-rotated-token");
        assert!(mgr.is_valid("new-rotated-token"));
        assert!(mgr.is_valid("initial-token")); // within grace period

        std::thread::sleep(Duration::from_millis(70));
        assert!(mgr.is_valid("new-rotated-token"));
        assert!(!mgr.is_valid("initial-token")); // expired
    }

    #[test]
    fn test_gateway_automation_tasks_schedule_and_due() {
        let task = super::GatewayAutomationTask {
            id: "task-1".to_string(),
            name: "Codex 定时巡检".to_string(),
            task_type: "modelHealthCheck".to_string(),
            enabled: true,
            providers: vec!["openai".to_string()],
            all_accounts: true,
            account_ids: vec![],
            hours: vec![8, 14, 21],
            last_run_at: None,
            last_run_status: None,
            last_run_summary: None,
        };

        // Let's create an epoch at hour 8
        // Using epoch_to_local_ymd_h to verify
        let t_base = 1788861600_i64; // arbitrary epoch
        let (_y, _m, _d, h) = super::GatewaySettings::epoch_to_local_ymd_h(t_base);
        // Find epoch offset for target hour
        let target_diff = (8_i32 - h as i32) * 3600;
        let t_hour_8 = t_base + target_diff as i64;
        let (_, _, _, h8) = super::GatewaySettings::epoch_to_local_ymd_h(t_hour_8);
        assert_eq!(h8, 8);

        // Task at hour 8 is due!
        assert!(super::GatewaySettings::is_task_due(&task, t_hour_8));

        // Task at hour 9 is NOT due
        let t_hour_9 = t_hour_8 + 3600;
        assert!(!super::GatewaySettings::is_task_due(&task, t_hour_9));

        // If task already ran at hour 8, it shouldn't be due again in the same hour
        let mut ran_task = task.clone();
        ran_task.last_run_at = Some(t_hour_8 + 120); // ran 2 minutes into hour 8
        assert!(!super::GatewaySettings::is_task_due(&ran_task, t_hour_8 + 300));

        // If disabled, not due
        let mut disabled_task = task.clone();
        disabled_task.enabled = false;
        assert!(!super::GatewaySettings::is_task_due(&disabled_task, t_hour_8));
    }

    #[test]
    fn test_automation_run_logs_round_trip_and_unknown_keys_survive_save() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(&support).unwrap();
        let home = home.to_str().unwrap();

        // App 端写入的设置：含一条执行日志 + 一个网关进程不认识的键
        fs::write(
            support.join("gateway-settings.json"),
            r#"{
                "$schemaVersion": 2,
                "appOnlyKey": {"kept": true},
                "automationTasks": [
                    {
                        "id": "task-1",
                        "name": "5小时额度对齐巡检",
                        "hours": [5, 10, 15, 20]
                    }
                ],
                "automationRunLogs": [
                    {
                        "id": "app-log-1",
                        "taskId": "task-1",
                        "taskName": "5小时额度对齐巡检",
                        "taskType": "modelHealthCheck",
                        "startedAt": 1789023729,
                        "finishedAt": 1789023800,
                        "isSuccess": true,
                        "summary": "可用 56 · 异常 88"
                    }
                ]
            }"#,
        )
        .unwrap();

        // 模拟网关定时触发一次任务：写开始记录，再补全结束记录
        let mut settings = super::GatewaySettings::load_for_home(home);
        assert_eq!(settings.automation_run_logs.len(), 1);
        settings.push_automation_run_log(super::GatewayAutomationRunLog {
            id: "task-1-1789030000".to_string(),
            task_id: "task-1".to_string(),
            task_name: "5小时额度对齐巡检".to_string(),
            task_type: "modelHealthCheck".to_string(),
            started_at: 1789030000,
            finished_at: None,
            is_success: None,
            summary: None,
            cancelled: None,
            results: None,
        });
        settings.save_for_home(home).unwrap();

        let mut settings = super::GatewaySettings::load_for_home(home);
        assert_eq!(settings.automation_run_logs.len(), 2);
        assert!(settings.automation_run_logs[1].finished_at.is_none());

        settings.finish_automation_run_log(
            "task-1-1789030000",
            1789030120,
            true,
            "可用 60 · 异常 4",
            false,
            None,
        );
        settings.save_for_home(home).unwrap();

        // 未知键必须被保留，否则 App 端字段会被网关的整份覆盖抹掉
        let raw: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(support.join("gateway-settings.json")).unwrap())
                .unwrap();
        assert_eq!(raw.get("appOnlyKey"), Some(&serde_json::json!({"kept": true})));

        let settings = super::GatewaySettings::load_for_home(home);
        assert_eq!(settings.automation_run_logs.len(), 2);
        let finished = &settings.automation_run_logs[1];
        assert_eq!(finished.finished_at, Some(1789030120));
        assert_eq!(finished.is_success, Some(true));
        assert_eq!(finished.summary.as_deref(), Some("可用 60 · 异常 4"));
        assert_eq!(finished.cancelled, None);

        // 取消的巡检：结果标记为 cancelled，且往返磁盘后仍保留（App 端据此显示「已取消」）
        let mut settings = settings;
        settings.push_automation_run_log(super::GatewayAutomationRunLog {
            id: "task-1-1789030200".to_string(),
            task_id: "task-1".to_string(),
            task_name: "5小时额度对齐巡检".to_string(),
            task_type: "modelHealthCheck".to_string(),
            started_at: 1789030200,
            finished_at: None,
            is_success: None,
            summary: None,
            cancelled: None,
            results: None,
        });
        settings.finish_automation_run_log(
            "task-1-1789030200",
            1789030210,
            false,
            "已取消 · 可用 12 · 异常 3",
            true,
            None,
        );
        settings.save_for_home(home).unwrap();

        let settings = super::GatewaySettings::load_for_home(home);
        let cancelled = settings
            .automation_run_logs
            .iter()
            .find(|log| log.id == "task-1-1789030200")
            .expect("cancelled run log must survive the disk round trip");
        assert_eq!(cancelled.cancelled, Some(true));
        assert_eq!(cancelled.is_success, Some(false));
        assert_eq!(
            cancelled.summary.as_deref(),
            Some("已取消 · 可用 12 · 异常 3")
        );

        // 容量上限：只保留最近 MAX_AUTOMATION_RUN_LOGS 条
        let mut settings = settings;
        for i in 0..(super::MAX_AUTOMATION_RUN_LOGS + 5) {
            settings.push_automation_run_log(super::GatewayAutomationRunLog {
                id: format!("bulk-{i}"),
                task_id: "task-1".to_string(),
                task_name: "bulk".to_string(),
                task_type: "modelHealthCheck".to_string(),
                started_at: 1789030000 + i as i64,
                finished_at: None,
                is_success: None,
                summary: None,
                cancelled: None,
                results: None,
            });
        }
        assert_eq!(settings.automation_run_logs.len(), super::MAX_AUTOMATION_RUN_LOGS);
        assert_eq!(
            settings.automation_run_logs.last().map(|log| log.id.as_str()),
            Some(format!("bulk-{}", super::MAX_AUTOMATION_RUN_LOGS + 4).as_str())
        );
    }

    #[test]
    fn quota_scoring_algorithms() {
        // 1. OpenAI / Codex scoring
        let codex_short = serde_json::json!({
            "usage": {
                "shortWindow": {
                    "remaining": 40,
                    "total": 50
                }
            }
        });
        assert_eq!(GatewayServer::score_codex_account(&codex_short), 80);

        let codex_exhausted = serde_json::json!({
            "usage": {
                "shortWindow": {
                    "remaining": 0,
                    "total": 100
                }
            }
        });
        assert_eq!(GatewayServer::score_codex_account(&codex_exhausted), 0);

        let codex_no_usage = serde_json::json!({});
        assert_eq!(GatewayServer::score_codex_account(&codex_no_usage), 100);

        // 2. Google Gemini scoring
        let gemini_normal = serde_json::json!({
            "geminiFiveHourRemaining": 0.85,
            "geminiWeeklyRemaining": 0.90
        });
        assert_eq!(GatewayServer::score_gemini_account(&gemini_normal), 85);

        let gemini_cooldown = serde_json::json!({
            "geminiFiveHourRemaining": 0.85,
            "geminiWeeklyRemaining": 0.90,
            "cooldownResetsAt": "2099-01-01T00:00:00Z"
        });
        assert_eq!(GatewayServer::score_gemini_account(&gemini_cooldown), 0);

        // 3. DeepSeek scoring
        assert_eq!(
            GatewayServer::score_deepseek_account(&serde_json::json!({"balance": {"total": 0.0}})),
            0
        );
        assert_eq!(
            GatewayServer::score_deepseek_account(&serde_json::json!({"balance": {"total": 5.0}})),
            30
        );
        assert_eq!(
            GatewayServer::score_deepseek_account(&serde_json::json!({"balance": {"total": 25.0}})),
            70
        );
        assert_eq!(
            GatewayServer::score_deepseek_account(&serde_json::json!({"balance": {"total": 100.0}})),
            100
        );

        // 4. OpenCode scoring
        assert_eq!(
            GatewayServer::score_opencode_account(
                &serde_json::json!({"isEnabled": true, "authenticationState": "connected"})
            ),
            100
        );
        assert_eq!(
            GatewayServer::score_opencode_account(
                &serde_json::json!({"isEnabled": false, "authenticationState": "connected"})
            ),
            0
        );
    }

    #[test]
    fn model_consolidation_payload_exports_deduplicated_models_when_enabled() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(&support).unwrap();

        let codex_home_1 = support.join("Runtimes/Codex/acc-1");
        fs::create_dir_all(&codex_home_1).unwrap();
        fs::write(codex_home_1.join("oauth_token.json"), "{}").unwrap();
        fs::write(
            codex_home_1.join("models_cache.json"),
            r#"{"models": [{"slug":"gpt-5.6-sol","visibility":"list"}]}"#,
        )
        .unwrap();

        let codex_home_2 = support.join("Runtimes/Codex/acc-2");
        fs::create_dir_all(&codex_home_2).unwrap();
        fs::write(codex_home_2.join("oauth_token.json"), "{}").unwrap();
        fs::write(
            codex_home_2.join("models_cache.json"),
            r#"{"models": [{"slug":"gpt-5.6-sol","visibility":"list"}]}"#,
        )
        .unwrap();

        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [
                    {
                        "id": {"rawValue": "11111111-1111-1111-1111-111111111111"},
                        "label": "Low Quota User",
                        "relativeHomeDirectory": "acc-1",
                        "isEnabled": true,
                        "authenticationState": "connected",
                        "usage": {"shortWindow": {"remaining": 20, "total": 100}}
                    },
                    {
                        "id": {"rawValue": "22222222-2222-2222-2222-222222222222"},
                        "label": "High Quota User",
                        "relativeHomeDirectory": "acc-2",
                        "isEnabled": true,
                        "authenticationState": "connected",
                        "usage": {"shortWindow": {"remaining": 85, "total": 100}}
                    }
                ],
                "geminiConnections": [],
                "deepSeekConnections": [],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();

        // 1. Without consolidation: 2 separate scoped model IDs
        let payload_disabled = GatewayServer::get_dynamic_models_payload_for_home(home.to_str().unwrap());
        let models_disabled = payload_disabled["data"].as_array().unwrap();
        assert_eq!(models_disabled.len(), 2);
        assert!(models_disabled[0]["id"].as_str().unwrap().contains('@'));
        assert!(models_disabled[1]["id"].as_str().unwrap().contains('@'));

        // 2. With consolidation: 1 consolidated model ID "openai/gpt-5.6-sol"
        fs::write(
            support.join("gateway-settings.json"),
            r#"{"modelConsolidationEnabled": true}"#,
        )
        .unwrap();
        let payload_enabled = GatewayServer::get_dynamic_models_payload_for_home(home.to_str().unwrap());
        let models_enabled = payload_enabled["data"].as_array().unwrap();
        assert_eq!(models_enabled.len(), 1);
        let consolidated = &models_enabled[0];
        assert_eq!(consolidated["id"], "openai/gpt-5.6-sol");
        assert_eq!(consolidated["quota_remaining"], "最高额度 85%");
        assert!(consolidated["account"].as_str().unwrap().contains("2"));
    }

    #[test]
    fn routes_highest_quota_account_when_consolidation_enabled() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(&support).unwrap();

        let codex_home_1 = support.join("Runtimes/Codex/acc-low");
        fs::create_dir_all(&codex_home_1).unwrap();
        fs::write(codex_home_1.join("oauth_token.json"), "{}").unwrap();
        fs::write(
            codex_home_1.join("models_cache.json"),
            r#"{"models": [{"slug":"gpt-5.6-sol","visibility":"list"}]}"#,
        )
        .unwrap();

        let codex_home_2 = support.join("Runtimes/Codex/acc-high");
        fs::create_dir_all(&codex_home_2).unwrap();
        fs::write(codex_home_2.join("oauth_token.json"), "{}").unwrap();
        fs::write(
            codex_home_2.join("models_cache.json"),
            r#"{"models": [{"slug":"gpt-5.6-sol","visibility":"list"}]}"#,
        )
        .unwrap();

        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [
                    {
                        "id": {"rawValue": "11111111-1111-1111-1111-111111111111"},
                        "label": "Low Quota User",
                        "relativeHomeDirectory": "acc-low",
                        "isEnabled": true,
                        "authenticationState": "connected",
                        "usage": {"shortWindow": {"remaining": 20, "total": 100}}
                    },
                    {
                        "id": {"rawValue": "22222222-2222-2222-2222-222222222222"},
                        "label": "High Quota User",
                        "relativeHomeDirectory": "acc-high",
                        "isEnabled": true,
                        "authenticationState": "connected",
                        "usage": {"shortWindow": {"remaining": 85, "total": 100}}
                    }
                ],
                "geminiConnections": [],
                "deepSeekConnections": [],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();

        fs::write(
            support.join("gateway-settings.json"),
            r#"{"modelConsolidationEnabled": true}"#,
        )
        .unwrap();

        // 1. Bare / consolidated request: selects higher-quota account 2 (acc-high)
        let ep = GatewayServer::resolve_upstream_endpoint_for_home(home.to_str().unwrap(), "openai/gpt-5.6-sol")
            .unwrap();
        assert!(ep.codex_home.unwrap().contains("acc-high"));
        assert!(ep._account_name.contains("High Quota User"));

        // 2. Explicit account target: strictly routes to requested account 1 (acc-low)
        let ep_explicit = GatewayServer::resolve_upstream_endpoint_for_home(
            home.to_str().unwrap(),
            "openai/gpt-5.6-sol@low-quota-user-openai-11111111",
        )
        .unwrap();
        assert!(ep_explicit.codex_home.unwrap().contains("acc-low"));
        assert!(ep_explicit._account_name.contains("Low Quota User"));
    }

    #[test]
    fn model_catalog_uses_wire_safe_ids_and_excludes_disabled_accounts() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(&support).unwrap();
        let codex_home = support.join("Runtimes/Codex/abc123-def456");
        fs::create_dir_all(&codex_home).unwrap();
        fs::write(
            codex_home.join("models_cache.json"),
            r#"{
                "models": [
                    {"slug":"gpt-reserve","visibility":"hide","display_name":"Reserve"},
                    {"slug":"codex-auto-review","visibility":"hide","display_name":"Review"},
                    {"slug":"gpt-5.6-sol","visibility":"list","display_name":"GPT-5.6 Sol"},
                    {"slug":"gpt-5.6-luna","visibility":"list","display_name":"GPT-5.6 Luna"}
                ]
            }"#,
        )
        .unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [
                    {"id":{"rawValue":"1A0C5FD1-5B60-46BC-9C9E-3067003DB35B"},"label":"Seven X","relativeHomeDirectory":"abc123-def456","isEnabled":true,"authenticationState":"connected","availableModelIDs":["gpt-5-6-t-mini","gpt-5.6-luna-wm"]},
                    {"id":{"rawValue":"2B1D6FE2-6C71-57CD-ADAF-4178114EC46C"},"label":"Disabled User","isEnabled":false,"availableModelIDs":["disabled-model"]}
                ],
                "geminiConnections": [],
                "deepSeekConnections": [],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();

        let payload = GatewayServer::get_dynamic_models_payload_for_home(home.to_str().unwrap());
        let models = payload["data"].as_array().unwrap();
        assert!(!models.is_empty());
        // The catalog must expose only codex-CLI-servable slugs, never the
        // ChatGPT-side catalog models (e.g. `gpt-5-6-t-mini`, `gpt-5.6-luna-wm`).
        let ids: Vec<&str> = models.iter().map(|model| model["id"].as_str().unwrap()).collect();
        assert!(ids.contains(&"openai/gpt-5.6-sol@Seven-X-openai-1a0c5fd1"));
        assert!(ids.contains(&"openai/gpt-5.6-luna@Seven-X-openai-1a0c5fd1"));
        assert!(ids.iter().all(|id| !id.contains("gpt-reserve") && !id.contains("codex-auto-review")));
        assert!(ids.iter().all(|id| !id.contains("gpt-5-6-t-mini") && !id.contains("gpt-5.6-luna-wm")));
        assert!(models.iter().all(|model| {
            model["id"]
                .as_str()
                .is_some_and(|id| !id.chars().any(char::is_whitespace))
        }));
        assert!(models
            .iter()
            .all(|model| model["account"] != "Disabled User"));

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn model_catalog_has_no_fabricated_fallback_when_every_account_is_disabled() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(&support).unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [{"label":"Disabled User","isEnabled":false}],
                "geminiConnections": [],
                "deepSeekConnections": [],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();

        let payload = GatewayServer::get_dynamic_models_payload_for_home(home.to_str().unwrap());
        assert!(payload["data"].as_array().unwrap().is_empty());

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn model_catalog_exports_enabled_gemini_oauth_accounts() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(support.join("gemini_oauth")).unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [],
                "geminiConnections": [{
                    "id": {"rawValue": "9C3D876B-A93F-4123-9191-B193BEE4118F"},
                    "label":"OAuth User",
                    "credentialHandle":"oauth-handle",
                    "isEnabled":true,
                    "authenticationState":"connected",
                    "availableModelIDs":["gemini-3.6-flash", "gemini-catalog-test-tiered"]
                }],
                "deepSeekConnections": [],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();
        fs::write(
            support.join("gemini_oauth/oauth-handle.json"),
            r#"{"accessToken":"oauth-access-token","refreshToken":"oauth-refresh-token"}"#,
        )
        .unwrap();

        let payload = GatewayServer::get_dynamic_models_payload_for_home(home.to_str().unwrap());
        let models = payload["data"].as_array().unwrap();
        assert!(models.iter().any(|model| {
            model["id"] == "google/gemini-3.6-flash@OAuth-User-google-9c3d876b"
                && model["provider"] == "Google Gemini"
                && model["account"] == "OAuth User (Google · 9c3d876b)"
        }));
        assert!(models.iter().any(|model| {
            model["id"] == "google/gemini-catalog-test-tiered@OAuth-User-google-9c3d876b"
                && model["display_name"] == "Google · Gemini Catalog Test (OAuth User (Google · 9c3d876b))"
        }));

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn preserves_provider_catalog_model_ids_for_account_routes() {
        let account = serde_json::json!({
            "availableModelIDs": [
                "deepseek-v4-pro",
                "gpt-5.6-luna",
                "gemini-3.7-flash-tiered"
            ]
        });

        // OpenCode may expose models branded by other vendors.  Its selected
        // route must preserve the OpenCode catalog's exact upstream ID.
        assert_eq!(
            GatewayServer::connection_model_id(&account, "deepseek-v4-pro"),
            Some("deepseek-v4-pro".into())
        );
        assert_eq!(
            GatewayServer::connection_model_id(&account, "gpt-5.6-luna"),
            Some("gpt-5.6-luna".into())
        );
        assert_eq!(
            GatewayServer::connection_model_id(&account, "not-in-catalog"),
            None
        );
    }

    #[test]
    fn routes_opencode_aggregation_models_with_explicit_and_discovered_scoping() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(support.join("opencode_credentials")).unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [],
                "geminiConnections": [],
                "deepSeekConnections": [],
                "openCodeConnections": [{
                    "label": "go",
                    "plan": "go",
                    "credentialHandle": "opencode-cred-handle",
                    "isEnabled": true,
                    "authenticationState": "connected",
                    "availableModelIDs": ["deepseek-v4-pro", "claude-3-7-sonnet"]
                }]
            }"#,
        )
        .unwrap();
        fs::write(
            support.join("opencode_credentials/opencode-cred-handle.key"),
            "opencode-test-api-key\n",
        )
        .unwrap();

        let home_str = home.to_str().unwrap();

        // 1. Account-first discovery: bare `deepseek-v4-pro@go` routes to OpenCode, NOT DeepSeek
        let ep1 = GatewayServer::resolve_upstream_endpoint_for_home(home_str, "deepseek-v4-pro@go")
            .unwrap();
        assert_eq!(ep1.provider_name, "OpenCode 聚合平台");
        assert_eq!(ep1.target_model, "deepseek-v4-pro");
        assert_eq!(ep1.auth_header, "Bearer opencode-test-api-key");
        assert_eq!(ep1.url, "https://opencode.ai/zen/go/v1/chat/completions");
        assert!(ep1.extra_headers.iter().any(|(k, _)| k == "x-opencode-session"));

        // 2. Explicit provider prefix: `opencode/deepseek-v4-pro@go`
        let ep2 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "opencode/deepseek-v4-pro@go",
        )
        .unwrap();
        assert_eq!(ep2.provider_name, "OpenCode 聚合平台");
        assert_eq!(ep2.target_model, "deepseek-v4-pro");

        // 3. Provider appended to account slug: `deepseek-v4-pro@go-opencode`
        let ep3 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "deepseek-v4-pro@go-opencode",
        )
        .unwrap();
        assert_eq!(ep3.provider_name, "OpenCode 聚合平台");
        assert_eq!(ep3.target_model, "deepseek-v4-pro");

        // 4. Hermes picker label: `OpenCode·deepseek-v4-pro·go`
        let ep4 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "OpenCode·deepseek-v4-pro·go",
        )
        .unwrap();
        assert_eq!(ep4.provider_name, "OpenCode 聚合平台");
        assert_eq!(ep4.target_model, "deepseek-v4-pro");

        // 5. Zen plan uses zen endpoint and does NOT inject x-opencode-session
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "openCodeConnections": [{
                    "label": "zen",
                    "plan": "zen",
                    "credentialHandle": "opencode-cred-handle",
                    "isEnabled": true,
                    "authenticationState": "connected",
                    "availableModelIDs": ["deepseek-v4-pro"]
                }]
            }"#,
        )
        .unwrap();
        let ep_zen = GatewayServer::resolve_upstream_endpoint_for_home(home_str, "deepseek-v4-pro@zen")
            .unwrap();
        assert_eq!(ep_zen.url, "https://opencode.ai/zen/v1/chat/completions");
        assert!(!ep_zen.extra_headers.iter().any(|(k, _)| k == "x-opencode-session"));

        // 6. Consolidated display name with provider prefix: `OpenCode · deepseek-v4-pro`
        let ep_cons1 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "OpenCode · deepseek-v4-pro",
        )
        .unwrap();
        assert_eq!(ep_cons1.provider_name, "OpenCode 聚合平台");
        assert_eq!(ep_cons1.target_model, "deepseek-v4-pro");

        // 7. Consolidated wire format: `opencode/deepseek-v4-pro`
        let ep_cons2 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "opencode/deepseek-v4-pro",
        )
        .unwrap();
        assert_eq!(ep_cons2.provider_name, "OpenCode 聚合平台");
        assert_eq!(ep_cons2.target_model, "deepseek-v4-pro");

        // 8. Consolidated bracket format: `[OpenCode] deepseek-v4-pro`
        let ep_cons3 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "[OpenCode] deepseek-v4-pro",
        )
        .unwrap();
        assert_eq!(ep_cons3.provider_name, "OpenCode 聚合平台");
        assert_eq!(ep_cons3.target_model, "deepseek-v4-pro");

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn routes_google_cloud_code_3p_models_without_cross_provider_rejection() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(support.join("gemini_oauth")).unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [],
                "geminiConnections": [{
                    "label": "x-seven",
                    "displayName": "X Seven",
                    "email": "x-seven@gmail.com",
                    "credentialHandle": "oauth-handle",
                    "id": {"rawValue": "9c3d876b-a93f-4123-9191-b193bee4118f"},
                    "projectId": "test-project-123",
                    "isEnabled": true,
                    "authenticationState": "connected",
                    "availableModelIDs": ["gemini-2.5-flash", "claude-opus-4-6-thinking", "claude-sonnet-4-6"]
                }],
                "deepSeekConnections": [],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();
        fs::write(
            support.join("gemini_oauth/oauth-handle.json"),
            r#"{"accessToken":"oauth-test-token","refreshToken":"oauth-refresh-token"}"#,
        )
        .unwrap();

        let home_str = home.to_str().unwrap();

        // 1. Account-first discovery: `claude-opus-4-6-thinking@x-seven`
        let ep1 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "claude-opus-4-6-thinking@x-seven",
        )
        .unwrap();
        assert_eq!(ep1.provider_name, "Google Gemini");
        assert_eq!(ep1.target_model, "claude-opus-4-6-thinking");
        assert_eq!(ep1.auth_header, "Bearer oauth-test-token");
        assert_eq!(ep1.project.as_deref(), Some("test-project-123"));

        // 2. Explicit provider prefix: `google/claude-opus-4-6-thinking@x-seven`
        let ep2 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "google/claude-opus-4-6-thinking@x-seven",
        )
        .unwrap();
        assert_eq!(ep2.provider_name, "Google Gemini");
        assert_eq!(ep2.target_model, "claude-opus-4-6-thinking");

        // 3. Provider appended to account slug: `claude-opus-4-6-thinking@x-seven-google`
        let ep3 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "claude-opus-4-6-thinking@x-seven-google",
        )
        .unwrap();
        assert_eq!(ep3.provider_name, "Google Gemini");
        assert_eq!(ep3.target_model, "claude-opus-4-6-thinking");

        // 4. Hermes picker label: `Google·claude-opus-4-6-thinking·x-seven`
        let ep4 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "Google·claude-opus-4-6-thinking·x-seven",
        )
        .unwrap();
        assert_eq!(ep4.provider_name, "Google Gemini");
        assert_eq!(ep4.target_model, "claude-opus-4-6-thinking");

        // 5. Composite three-part slug: `claude-sonnet-4-6@x-seven-google-9c3d876b`
        let ep5 = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "claude-sonnet-4-6@x-seven-google-9c3d876b",
        )
        .unwrap();
        assert_eq!(ep5.provider_name, "Google Gemini");
        assert_eq!(ep5.target_model, "claude-sonnet-4-6");

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn routes_codex_catalog_models_and_passes_through_new_models() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        let codex_home = support.join("Runtimes/Codex/abc123-def456");
        fs::create_dir_all(&codex_home).unwrap();
        fs::write(
            codex_home.join("oauth_token.json"),
            r#"{"accessToken":"codex-token"}"#,
        )
        .unwrap();
        fs::write(
            codex_home.join("models_cache.json"),
            r#"{
                "models": [
                    {"slug":"gpt-reserve","visibility":"hide","display_name":"Reserve"},
                    {"slug":"gpt-5.6-sol","visibility":"list","display_name":"GPT-5.6 Sol"},
                    {"slug":"gpt-5.6-luna","visibility":"list","display_name":"GPT-5.6 Luna"}
                ]
            }"#,
        )
        .unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [{
                    "id":{"rawValue":"1A0C5FD1-5B60-46BC-9C9E-3067003DB35B"},
                    "label":"x-seven",
                    "relativeHomeDirectory":"abc123-def456",
                    "isEnabled":true,
                    "authenticationState":"connected",
                    "availableModelIDs":["gpt-5-6-t-mini","gpt-5.6-sol-wm","gpt-5-5"]
                }],
                "geminiConnections": [],
                "deepSeekConnections": [],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();

        let home_str = home.to_str().unwrap();

        // A codex-CLI-servable slug routes straight through, preserving the slug.
        let ep_ok = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "gpt-5.6-sol@x-seven-openai",
        )
        .unwrap();
        assert_eq!(ep_ok.provider_name, "OpenAI / Codex");
        assert_eq!(ep_ok.target_model, "gpt-5.6-sol");

        // A ChatGPT-catalog `-wm` suffix is normalized to the CLI-servable slug.
        let ep_wm = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "gpt-5.6-sol-wm@x-seven-openai",
        )
        .unwrap();
        assert_eq!(ep_wm.provider_name, "OpenAI / Codex");
        assert_eq!(ep_wm.target_model, "gpt-5.6-sol");

        // Newly released models not yet in local cache (e.g. `gpt-6-astra`) pass through
        // directly to the CLI instead of being blocked by a hardcoded gateway whitelist.
        let ep_new = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "gpt-6-astra@x-seven-openai",
        )
        .unwrap();
        assert_eq!(ep_new.provider_name, "OpenAI / Codex");
        assert_eq!(ep_new.target_model, "gpt-6-astra");

        // Newly released model with `-wm` suffix also normalizes properly.
        let ep_new_wm = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "gpt-6-astra-wm@x-seven-openai",
        )
        .unwrap();
        assert_eq!(ep_new_wm.provider_name, "OpenAI / Codex");
        assert_eq!(ep_new_wm.target_model, "gpt-6-astra");

        // Empty model is rejected.
        let err_empty = match GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "@x-seven-openai",
        ) {
            Ok(_) => panic!("expected an error for empty model"),
            Err(e) => e,
        };
        assert!(err_empty.contains("不支持模型"), "got: {err_empty}");

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn test_dynamic_cooldown_and_lru_rotation() {
        let dynamic_state = AccountDynamicState::global();
        {
            let mut state = dynamic_state.lock().unwrap();
            state.mark_cooldown("cooling-acc", std::time::Duration::from_secs(60));
            assert!(state.is_cooling_down("cooling-acc"));
            assert!(!state.is_cooling_down("healthy-acc"));
            assert_eq!(state.cooling_down_count(), 1);
        }

        let mut candidates = vec![
            (
                100,
                "cooling-acc".to_string(),
                UpstreamEndpoint {
                    url: "https://api.example.com".into(),
                    auth_header: "Bearer token1".into(),
                    extra_headers: Vec::new(),
                    project: None,
                    target_model: "test-model".into(),
                    provider_name: "OpenAI / Codex".into(),
                    _account_name: "cooling-acc".into(),
                    codex_home: None,
                    connection_id: "cooling-acc".into(),
                    quota_score: 100,
                    routing_mode: "consolidated".into(),
                },
            ),
            (
                80,
                "healthy-acc".to_string(),
                UpstreamEndpoint {
                    url: "https://api.example.com".into(),
                    auth_header: "Bearer token2".into(),
                    extra_headers: Vec::new(),
                    project: None,
                    target_model: "test-model".into(),
                    provider_name: "OpenAI / Codex".into(),
                    _account_name: "healthy-acc".into(),
                    codex_home: None,
                    connection_id: "healthy-acc".into(),
                    quota_score: 80,
                    routing_mode: "consolidated".into(),
                },
            ),
        ];

        // healthy-acc must be picked even with lower score because cooling-acc is cooling down
        let picked = GatewayServer::sort_and_pick_candidate("openai", "smooth", &mut candidates).unwrap();
        assert_eq!(picked.connection_id, "healthy-acc");

        // Test LRU rotation with equal scores
        let mut candidates_lru = vec![
            (
                100,
                "acc-a".to_string(),
                UpstreamEndpoint {
                    url: "https://api.example.com".into(),
                    auth_header: "Bearer token-a".into(),
                    extra_headers: Vec::new(),
                    project: None,
                    target_model: "test-model".into(),
                    provider_name: "OpenAI / Codex".into(),
                    _account_name: "acc-a".into(),
                    codex_home: None,
                    connection_id: "acc-a".into(),
                    quota_score: 100,
                    routing_mode: "consolidated".into(),
                },
            ),
            (
                100,
                "acc-b".to_string(),
                UpstreamEndpoint {
                    url: "https://api.example.com".into(),
                    auth_header: "Bearer token-b".into(),
                    extra_headers: Vec::new(),
                    project: None,
                    target_model: "test-model".into(),
                    provider_name: "OpenAI / Codex".into(),
                    _account_name: "acc-b".into(),
                    codex_home: None,
                    connection_id: "acc-b".into(),
                    quota_score: 100,
                    routing_mode: "consolidated".into(),
                },
            ),
        ];

        // acc-a has never been served, acc-b has never been served -> deterministic tie-break selects acc-a
        let picked1 = GatewayServer::sort_and_pick_candidate("openai", "smooth", &mut candidates_lru).unwrap();
        assert_eq!(picked1.connection_id, "acc-a");

        // Re-run candidates: now acc-a was served, acc-b was not served yet -> acc-b must be picked (LRU)
        let mut candidates_lru2 = vec![
            (
                100,
                "acc-a".to_string(),
                UpstreamEndpoint {
                    url: "https://api.example.com".into(),
                    auth_header: "Bearer token-a".into(),
                    extra_headers: Vec::new(),
                    project: None,
                    target_model: "test-model".into(),
                    provider_name: "OpenAI / Codex".into(),
                    _account_name: "acc-a".into(),
                    codex_home: None,
                    connection_id: "acc-a".into(),
                    quota_score: 100,
                    routing_mode: "consolidated".into(),
                },
            ),
            (
                100,
                "acc-b".to_string(),
                UpstreamEndpoint {
                    url: "https://api.example.com".into(),
                    auth_header: "Bearer token-b".into(),
                    extra_headers: Vec::new(),
                    project: None,
                    target_model: "test-model".into(),
                    provider_name: "OpenAI / Codex".into(),
                    _account_name: "acc-b".into(),
                    codex_home: None,
                    connection_id: "acc-b".into(),
                    quota_score: 100,
                    routing_mode: "consolidated".into(),
                },
            ),
        ];
        let picked2 = GatewayServer::sort_and_pick_candidate("openai", "smooth", &mut candidates_lru2).unwrap();
        assert_eq!(picked2.connection_id, "acc-b");
    }

    #[test]
    fn test_smooth_routing_mode_balance() {
        let provider = "google-test-smooth";
        let mut candidates = vec![
            (
                100,
                "primary-acc".to_string(),
                UpstreamEndpoint {
                    url: "https://api.example.com".into(),
                    auth_header: "Bearer t1".into(),
                    extra_headers: Vec::new(),
                    project: None,
                    target_model: "gemini-2.5-pro".into(),
                    provider_name: "Google Gemini".into(),
                    _account_name: "primary-acc".into(),
                    codex_home: None,
                    connection_id: "primary-acc".into(),
                    quota_score: 100,
                    routing_mode: "consolidated".into(),
                },
            ),
            (
                95,
                "secondary-acc".to_string(),
                UpstreamEndpoint {
                    url: "https://api.example.com".into(),
                    auth_header: "Bearer t2".into(),
                    extra_headers: Vec::new(),
                    project: None,
                    target_model: "gemini-2.5-pro".into(),
                    provider_name: "Google Gemini".into(),
                    _account_name: "secondary-acc".into(),
                    codex_home: None,
                    connection_id: "secondary-acc".into(),
                    quota_score: 95,
                    routing_mode: "consolidated".into(),
                },
            ),
        ];

        let picked1 = GatewayServer::sort_and_pick_candidate(provider, "smooth", &mut candidates).unwrap();
        assert_eq!(picked1.connection_id, "primary-acc");
    }

    #[test]
    fn test_hermes_two_segment_picker_routing() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(support.join("deepseek_credentials")).unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [],
                "geminiConnections": [],
                "deepSeekConnections": [{
                    "id": {"rawValue": "ds-conn-1"},
                    "label": "primary-ds",
                    "credentialHandle": "ds-cred",
                    "isEnabled": true,
                    "authenticationState": "connected",
                    "availableModelIDs": ["deepseek-chat", "deepseek-reasoner"]
                }],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();
        fs::write(
            support.join("deepseek_credentials/ds-cred.key"),
            "ds-key-123\n",
        )
        .unwrap();
        fs::write(
            support.join("gateway-settings.json"),
            r#"{"modelConsolidationEnabled":true,"allowFailover":true}"#,
        )
        .unwrap();

        let home_str = home.to_str().unwrap();

        // 2-segment picker alias: `DeepSeek·deepseek-chat`
        let ep = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "DeepSeek·deepseek-chat",
        )
        .unwrap();
        assert_eq!(ep.provider_name, "DeepSeek 官方");
        assert_eq!(ep.target_model, "deepseek-chat");
        assert_eq!(ep.routing_mode, "consolidated");
        assert_eq!(ep.connection_id, "ds-conn-1");

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn test_pinned_account_auto_switch_and_persist_on_failure() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(support.join("deepseek_credentials")).unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [],
                "geminiConnections": [],
                "deepSeekConnections": [
                    {
                        "id": {"rawValue": "ds-conn-1"},
                        "label": "primary-ds",
                        "credentialHandle": "ds-cred-1",
                        "isEnabled": true,
                        "authenticationState": "connected",
                        "availableModelIDs": ["deepseek-chat"],
                        "balance": {"total": 100.0}
                    },
                    {
                        "id": {"rawValue": "ds-conn-2"},
                        "label": "secondary-ds",
                        "credentialHandle": "ds-cred-2",
                        "isEnabled": true,
                        "authenticationState": "connected",
                        "availableModelIDs": ["deepseek-chat"],
                        "balance": {"total": 100.0}
                    }
                ],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();
        fs::write(
            support.join("deepseek_credentials/ds-cred-1.key"),
            "ds-key-1\n",
        )
        .unwrap();
        fs::write(
            support.join("deepseek_credentials/ds-cred-2.key"),
            "ds-key-2\n",
        )
        .unwrap();
        fs::write(
            support.join("gateway-settings.json"),
            r#"{
                "modelConsolidationEnabled": true,
                "allowFailover": true,
                "providerRoutingModes": {"deepseek": "pinnedAccount"},
                "providerPinnedAccounts": {"deepseek": "ds-conn-1"}
            }"#,
        )
        .unwrap();

        let home_str = home.to_str().unwrap();

        // 1. Initial resolution must pick the pinned account ds-conn-1 with routing_mode "pinned"
        let ep = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "DeepSeek·deepseek-chat",
        )
        .unwrap();
        assert_eq!(ep.connection_id, "ds-conn-1");
        assert_eq!(ep.routing_mode, "pinned");

        // 2. When pinned account is in exclusions (e.g. 429), it must auto-fallback to smooth routing and persist!
        let res_switched = GatewayServer::resolve_upstream_endpoint_for_home_with_exclusions(
            home_str,
            "DeepSeek·deepseek-chat",
            &["ds-conn-1".to_string()],
        )
        .unwrap();
        assert_eq!(res_switched.connection_id, "ds-conn-2");
        assert_eq!(res_switched.routing_mode, "consolidated");

        // Check that settings on disk was updated to smooth mode and pinned account cleared!
        let updated_settings = super::GatewaySettings::load_for_home(home_str);
        assert_eq!(
            updated_settings.routing_mode_for_provider("deepseek"),
            "smooth"
        );
        assert_eq!(
            updated_settings.pinned_account_for_provider("deepseek"),
            None
        );

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn test_pinned_account_auto_fallback_when_quota_exhausted() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(support.join("deepseek_credentials")).unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [],
                "geminiConnections": [],
                "deepSeekConnections": [
                    {
                        "id": {"rawValue": "ds-conn-1"},
                        "label": "primary-ds",
                        "credentialHandle": "ds-cred-1",
                        "isEnabled": true,
                        "authenticationState": "connected",
                        "availableModelIDs": ["deepseek-chat"],
                        "balance": {"total": 0.0}
                    },
                    {
                        "id": {"rawValue": "ds-conn-2"},
                        "label": "secondary-ds",
                        "credentialHandle": "ds-cred-2",
                        "isEnabled": true,
                        "authenticationState": "connected",
                        "availableModelIDs": ["deepseek-chat"],
                        "balance": {"total": 50.0}
                    }
                ],
                "openCodeConnections": []
            }"#,
        )
        .unwrap();
        fs::write(
            support.join("deepseek_credentials/ds-cred-1.key"),
            "ds-key-1\n",
        )
        .unwrap();
        fs::write(
            support.join("deepseek_credentials/ds-cred-2.key"),
            "ds-key-2\n",
        )
        .unwrap();
        fs::write(
            support.join("gateway-settings.json"),
            r#"{
                "modelConsolidationEnabled": true,
                "allowFailover": true,
                "providerRoutingModes": {"deepseek": "pinnedAccount"},
                "providerPinnedAccounts": {"deepseek": "ds-conn-1"}
            }"#,
        )
        .unwrap();

        let home_str = home.to_str().unwrap();

        // ds-conn-1 is pinned, but its quota is 0 (exhausted).
        // It must NOT be picked as pinned!
        // It must automatically fall back to smooth routing, pick ds-conn-2, and persist smooth to disk!
        let ep = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "DeepSeek·deepseek-chat",
        )
        .unwrap();
        assert_eq!(ep.connection_id, "ds-conn-2");
        assert_eq!(ep.routing_mode, "consolidated");

        // Check that settings on disk was updated to smooth mode and pinned account cleared!
        let updated_settings = super::GatewaySettings::load_for_home(home_str);
        assert_eq!(
            updated_settings.routing_mode_for_provider("deepseek"),
            "smooth"
        );
        assert_eq!(
            updated_settings.pinned_account_for_provider("deepseek"),
            None
        );

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn parse_visible_codex_models_filters_hidden_and_internal_slugs() {
        // Mirrors the shape of `codex debug models` output (and `models_cache.json`):
        // the servable set is whatever the CLI lists with `visibility: "list"`.
        let json = serde_json::json!({
            "models": [
                {"slug":"gpt-reserve","visibility":"hide","display_name":"Reserve"},
                {"slug":"codex-auto-review","visibility":"hide","display_name":"Review"},
                {"slug":"gpt-5.6-sol","visibility":"list","display_name":"GPT-5.6 Sol"},
                {"slug":"gpt-5.6-terra","visibility":"list","display_name":"GPT-5.6 Terra"},
                {"slug":"brand-new-model","visibility":"list"}
            ]
        });
        let catalog = GatewayServer::parse_visible_codex_models(&json);
        let slugs: Vec<&str> = catalog
            .iter()
            .filter_map(|m| m.get("slug").and_then(|s| s.as_str()))
            .collect();
        assert_eq!(slugs, vec!["gpt-5.6-sol", "gpt-5.6-terra", "brand-new-model"]);
        assert!(slugs.iter().all(|s| *s != "gpt-reserve" && *s != "codex-auto-review"));
        // Models without an explicit display name fall back to their slug.
        assert_eq!(catalog[2]["display_name"], "brand-new-model");
    }

    #[test]
    fn codex_catalog_returns_empty_when_no_servable_source_exists() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        let codex_home = support.join("Runtimes/Codex/abc123-def456");
        fs::create_dir_all(&codex_home).unwrap();
        // No `models_cache.json` at all: in a test build the CLI is never
        // shelled out, so the catalog must come back empty (never fabricated).
        let catalog = GatewayServer::codex_catalog(codex_home.to_str().unwrap());
        assert!(catalog.is_empty());
        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn disambiguates_accounts_sharing_identical_name_across_channels() {
        let home = temporary_home();
        let support = home.join("Library/Application Support/Tomo");
        fs::create_dir_all(support.join("opencode_credentials")).unwrap();
        fs::create_dir_all(support.join("gemini_oauth")).unwrap();
        fs::write(
            support.join("connections-v1.json"),
            r#"{
                "codexAccounts": [],
                "geminiConnections": [{
                    "id": {"rawValue": "9C3D876B-A93F-4123-9191-B193BEE4118F"},
                    "label": "work",
                    "displayName": "Work Account",
                    "credentialHandle": "google-work-handle",
                    "projectId": "work-project",
                    "isEnabled": true,
                    "authenticationState": "connected",
                    "availableModelIDs": ["gemini-2.5-flash", "claude-3-7-sonnet"]
                }],
                "deepSeekConnections": [],
                "openCodeConnections": [{
                    "id": {"rawValue": "1E29E790-7565-4D03-923A-91BA5E18E174"},
                    "label": "work",
                    "plan": "zen",
                    "credentialHandle": "opencode-work-handle",
                    "isEnabled": true,
                    "authenticationState": "connected",
                    "availableModelIDs": ["deepseek-v4-pro", "claude-3-7-sonnet"]
                }]
            }"#,
        )
        .unwrap();
        fs::write(
            support.join("opencode_credentials/opencode-work-handle.key"),
            "opencode-work-key\n",
        )
        .unwrap();
        fs::write(
            support.join("gemini_oauth/google-work-handle.json"),
            r#"{"accessToken":"google-work-token","refreshToken":"work-refresh-token"}"#,
        )
        .unwrap();

        let home_str = home.to_str().unwrap();

        // 1. Target OpenCode account explicitly via three-part slug (account + provider + short_id)
        let ep_opencode_full = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "claude-3-7-sonnet@work-opencode-1e29e790",
        )
        .unwrap();
        assert_eq!(ep_opencode_full.provider_name, "OpenCode 聚合平台");
        assert_eq!(ep_opencode_full._account_name, "work (OpenCode · 1e29e790)");

        // 2. Target Google account explicitly via three-part slug (account + provider + short_id)
        let ep_google_full = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "claude-3-7-sonnet@work-account-google-9c3d876b",
        )
        .unwrap();
        assert_eq!(ep_google_full.provider_name, "Google Gemini");
        assert_eq!(ep_google_full._account_name, "Work Account (Google · 9c3d876b)");

        // 3. Target OpenCode account by short_id directly
        let ep_opencode_id = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "claude-3-7-sonnet@1e29e790",
        )
        .unwrap();
        assert_eq!(ep_opencode_id.provider_name, "OpenCode 聚合平台");

        // 4. Target Google account by short_id directly
        let ep_google_id = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "claude-3-7-sonnet@9c3d876b",
        )
        .unwrap();
        assert_eq!(ep_google_id.provider_name, "Google Gemini");

        // 5. Target OpenCode account explicitly via account suffix without ID
        let ep_opencode = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "claude-3-7-sonnet@work-opencode",
        )
        .unwrap();
        assert_eq!(ep_opencode.provider_name, "OpenCode 聚合平台");
        assert_eq!(ep_opencode.auth_header, "Bearer opencode-work-key");
        assert_eq!(ep_opencode.url, "https://opencode.ai/zen/v1/chat/completions");

        // 6. Target Google account explicitly via account suffix without ID
        let ep_google = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "claude-3-7-sonnet@work-account-google",
        )
        .unwrap();
        assert_eq!(ep_google.provider_name, "Google Gemini");
        assert_eq!(ep_google.auth_header, "Bearer google-work-token");

        // 7. Target OpenCode via explicit provider prefix
        let ep_opencode_prefix = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "opencode/claude-3-7-sonnet@work",
        )
        .unwrap();
        assert_eq!(ep_opencode_prefix.provider_name, "OpenCode 聚合平台");

        // 8. Target Google via explicit provider prefix
        let ep_google_prefix = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "google/claude-3-7-sonnet@work",
        )
        .unwrap();
        assert_eq!(ep_google_prefix.provider_name, "Google Gemini");

        // 9. For a model only present in OpenCode (deepseek-v4-pro), bare `@work` routes to OpenCode
        let ep_unique = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "deepseek-v4-pro@work",
        )
        .unwrap();
        assert_eq!(ep_unique.provider_name, "OpenCode 聚合平台");

        // 10. For gemini native model, bare `@work` routes to Google Gemini
        let ep_gemini_native = GatewayServer::resolve_upstream_endpoint_for_home(
            home_str,
            "gemini-2.5-flash@work",
        )
        .unwrap();
        assert_eq!(ep_gemini_native.provider_name, "Google Gemini");

        fs::remove_dir_all(home).unwrap();
    }

    #[test]
    fn does_not_register_legacy_cross_provider_fallback_aliases() {
        let server = GatewayServer::new("test-token");
        for alias in [
            "coding-smart",
            "coding-fast",
            "coding-reasoner",
            "claude-3-7-sonnet",
            "gpt-4o",
        ] {
            assert!(server.route_table.resolve(&ModelSelector::alias(alias), None).is_err(), "{alias}");
        }
    }

    #[test]
    fn cloud_code_payload_wraps_native_generation_request() {
        let native_request = serde_json::json!({
            "contents": [{"role": "user", "parts": [{"text": "OAuth OK"}]}]
        });
        let payload = GatewayServer::cloud_code_generate_payload(
            "cloud-code-project",
            "gemini-2.5-flash",
            native_request.clone(),
            "tomo-test",
        );

        assert_eq!(payload["project"], "cloud-code-project");
        assert_eq!(payload["model"], "gemini-2.5-flash");
        assert_eq!(payload["request"], native_request);
        assert_eq!(payload["requestId"], "tomo-test");
    }

    #[test]
    fn cloud_code_response_unwraps_generated_text() {
        let response = serde_json::json!({
            "response": {
                "candidates": [{
                    "content": {"parts": [{"text": "first"}, {"text": "second"}]}
                }]
            }
        });

        assert_eq!(
            GatewayServer::cloud_code_response_text(&response).as_deref(),
            Some("first\nsecond")
        );
    }

    #[test]
    fn gemini_usage_metadata_reads_cloud_code_envelope_and_plain_api_shape() {
        // Cloud Code 包一层 response；usageMetadata 缺 thoughts 时按 0 处理。
        let cloud_code = serde_json::json!({
            "response": {
                "candidates": [{"content": {"parts": [{"text": "hi"}]}}],
                "usageMetadata": {
                    "promptTokenCount": 252265,
                    "candidatesTokenCount": 686,
                    "cachedContentTokenCount": 240000,
                    "totalTokenCount": 252951
                }
            }
        });
        assert_eq!(
            GatewayServer::gemini_usage_metadata(&cloud_code),
            Some((252265, 686, Some(240000), 252951))
        );

        // 普通 Gemini API 平铺形态，thoughtsTokenCount 计入输出。
        let plain = serde_json::json!({
            "usageMetadata": {
                "promptTokenCount": 1200,
                "candidatesTokenCount": 300,
                "thoughtsTokenCount": 500,
                "totalTokenCount": 2000
            }
        });
        assert_eq!(
            GatewayServer::gemini_usage_metadata(&plain),
            Some((1200, 800, None, 2000))
        );

        // 无 usageMetadata 时返回 None，让调用方回退到估算并标注 estimated。
        assert_eq!(GatewayServer::gemini_usage_metadata(&serde_json::json!({})), None);
    }

    #[test]
    fn test_gemini_thinking_budget_mappings() {
        // 1. OpenAI reasoning_effort mappings
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"reasoning_effort": "none"})),
            Some(0)
        );
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"reasoning_effort": "disabled"})),
            Some(0)
        );
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"reasoning_effort": "off"})),
            Some(0)
        );
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"reasoning_effort": "low"})),
            Some(1024)
        );
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"reasoning_effort": "medium"})),
            Some(2048)
        );
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"reasoning_effort": "high"})),
            Some(8192)
        );
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"reasoning_effort": 512})),
            Some(512)
        );

        // 2. Anthropic thinking object mappings
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"thinking": {"type": "disabled"}})),
            Some(0)
        );
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"thinking": {"type": "enabled", "budget_tokens": 3072}})),
            Some(3072)
        );
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"thinking": false})),
            Some(0)
        );

        // 3. Direct thinking_budget / thinkingBudget
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"thinking_budget": 1200})),
            Some(1200)
        );
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({"thinkingBudget": 2400})),
            Some(2400)
        );

        // 4. Nested thinkingConfig
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({
                "thinkingConfig": {"thinkingBudget": 4096}
            })),
            Some(4096)
        );

        // 5. None when not specified
        assert_eq!(
            GatewayServer::gemini_thinking_budget(&serde_json::json!({})),
            None
        );
    }

    #[test]
    fn cloud_code_tools_round_trip_to_openai_shape() {
        let request = serde_json::json!({
            "tools": [{"type":"function", "function": {
                "name":"read_file", "description":"Read a file",
                "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
            }}],
            "tool_choice": "required"
        });
        let tools = GatewayServer::openai_tools_to_gemini(&request).unwrap();
        assert_eq!(tools[0]["functionDeclarations"][0]["name"], "read_file");
        assert_eq!(
            GatewayServer::openai_tool_choice_to_gemini(request.get("tool_choice")).unwrap()
                ["functionCallingConfig"]["mode"],
            "ANY"
        );

        let response = serde_json::json!({"response":{"candidates":[{"content":{"parts":[{
            "functionCall":{"name":"read_file","args":{"path":"README.md"}}
        }]}}]}});
        let message = GatewayServer::new("test-token")
            .cloud_code_response_message(&response)
            .unwrap();
        assert_eq!(message["tool_calls"][0]["function"]["name"], "read_file");
        assert_eq!(
            message["tool_calls"][0]["function"]["arguments"],
            "{\"path\":\"README.md\"}"
        );
    }

    #[test]
    fn cloud_code_response_message_extracts_thought_and_indexes_tools() {
        let response = serde_json::json!({
            "response": {
                "candidates": [{
                    "content": {
                        "parts": [
                            {"text": "Let me think about this...", "thought": true},
                            {"functionCall": {"name": "bash", "args": {"command": "git status"}}},
                            {"text": "Proceeding with branch checkout."}
                        ]
                    }
                }]
            }
        });
        let message = GatewayServer::new("test-token")
            .cloud_code_response_message(&response)
            .unwrap();
        assert_eq!(
            message["reasoning_content"],
            "Let me think about this..."
        );
        assert_eq!(
            message["content"],
            "Proceeding with branch checkout."
        );
        assert_eq!(message["tool_calls"][0]["index"], 0);
        assert_eq!(message["tool_calls"][0]["function"]["name"], "bash");
        assert_eq!(
            message["tool_calls"][0]["function"]["arguments"],
            "{\"command\":\"git status\"}"
        );
    }

    #[test]
    fn wraps_non_object_tool_results_for_gemini_function_response() {
        let object = serde_json::json!({"path": "README.md", "found": true});
        assert_eq!(
            GatewayServer::gemini_function_response_object(object.clone()),
            object
        );

        assert_eq!(
            GatewayServer::gemini_function_response_object(serde_json::json!([{"name": "a"}])),
            serde_json::json!({"result": [{"name": "a"}]})
        );
        assert_eq!(
            GatewayServer::gemini_function_response_object(serde_json::json!("done")),
            serde_json::json!({"result": "done"})
        );
    }

    #[test]
    fn restores_gemini_thought_signature_when_client_rewrites_tool_call_id() {
        let server = GatewayServer::new("test-token");
        let response = serde_json::json!({"response":{"candidates":[{"content":{"parts":[{
            "functionCall":{"name":"bash","args":{"command":"git status"}},
            "thoughtSignature":"signature-from-gemini"
        }]}}]}});
        let message = server.cloud_code_response_message(&response).unwrap();
        let function = &message["tool_calls"][0]["function"];
        let args: serde_json::Value =
            serde_json::from_str(function["arguments"].as_str().unwrap()).unwrap();

        assert_eq!(
            server.gemini_thought_signature_for_call("rewritten_by_pi", "bash", &args),
            Some("signature-from-gemini".into())
        );
    }

    #[test]
    fn parses_swift_oauth_expiry_dates() {
        assert_eq!(
            GatewayServer::parse_rfc3339_utc("1970-01-01T00:00:00Z"),
            Some(0)
        );
        assert_eq!(
            GatewayServer::parse_rfc3339_utc("1970-01-02T00:00:00.000Z"),
            Some(86_400)
        );
        assert_eq!(GatewayServer::parse_rfc3339_utc("not-a-date"), None);
    }

    #[test]
    fn formats_gateway_refreshed_expiry_dates_for_swift_to_read() {
        let formatted = GatewayServer::format_rfc3339_utc(86_401);
        assert_eq!(formatted, "1970-01-02T00:00:01Z");
        assert_eq!(GatewayServer::parse_rfc3339_utc(&formatted), Some(86_401));
    }

    #[test]
    fn matches_gateway_account_slug_against_email() {
        assert!(GatewayServer::gateway_account_filter_matches(
            "xujinqixujinqi-gmail-com",
            &["", "xujinqixujinqi@gmail.com", "xujinqixujinqi@gmail.com"],
        ));
        assert!(!GatewayServer::gateway_account_filter_matches(
            "another-account",
            &["", "xujinqixujinqi@gmail.com", "xujinqixujinqi@gmail.com"],
        ));
    }

    #[test]
    fn matches_gateway_account_name_with_non_ascii_characters() {
        assert!(GatewayServer::gateway_account_filter_matches(
            "徐金琦",
            &["徐金琦", "xujinqi777@gmail.com", "xujinqi777@gmail.com"],
        ));
    }

    #[test]
    fn matches_gateway_account_slug_with_non_ascii_case() {
        assert!(GatewayServer::gateway_account_filter_matches(
            "qintelli-zø",
            &["Qintelli ZØ", "qintellizo@gmail.com"],
        ));
    }

    #[test]
    fn multimodal_user_message_keeps_its_attachment_on_every_upstream() {
        let content = serde_json::json!([
            {"type": "text", "text": "这张图里是什么？"},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,QUJD"}}
        ]);
        let content = Some(&content);

        // Text extraction alone is unchanged; it must not start reading images.
        assert_eq!(
            GatewayServer::message_text(content).as_deref(),
            Some("这张图里是什么？")
        );

        // Gemini Cloud Code: an inlineData part beside the text.
        let gemini = GatewayServer::gemini_inline_data_parts(content);
        assert_eq!(gemini.len(), 1);
        assert_eq!(gemini[0]["inlineData"]["mimeType"], "image/png");
        assert_eq!(gemini[0]["inlineData"]["data"], "QUJD");

        // Codex Responses: an input_image part beside the input_text part.
        let codex = GatewayServer::codex_user_content_parts(content);
        assert_eq!(codex.len(), 2);
        assert_eq!(codex[0]["type"], "input_text");
        assert_eq!(codex[1]["type"], "input_image");
        assert_eq!(codex[1]["image_url"], "data:image/png;base64,QUJD");
    }

    #[test]
    fn attachment_without_text_still_reaches_the_model() {
        let content = serde_json::json!([
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}}
        ]);
        let content = Some(&content);

        assert_eq!(GatewayServer::message_text(content).as_deref(), Some(""));
        assert_eq!(GatewayServer::gemini_inline_data_parts(content).len(), 1);
        let codex = GatewayServer::codex_user_content_parts(content);
        assert!(codex.iter().any(|part| part["type"] == "input_image"));
    }

    #[test]
    fn remote_image_urls_are_skipped_where_they_cannot_be_inlined() {
        let content = serde_json::json!([
            {"type": "text", "text": "hi"},
            {"type": "image_url", "image_url": {"url": "https://example.com/a.png"}}
        ]);
        let content = Some(&content);

        // Gemini has no field for an arbitrary remote URL, so it is dropped
        // rather than mislabelled as text. Codex forwards the URL as-is.
        assert!(GatewayServer::gemini_inline_data_parts(content).is_empty());
        let codex = GatewayServer::codex_user_content_parts(content);
        assert!(codex.iter().any(|part| part["image_url"] == "https://example.com/a.png"));
    }

    #[test]
    fn malformed_attachments_never_panic_or_leak_as_text() {
        assert_eq!(GatewayServer::parse_inline_data_url("data:image/png,QUJD"), None);
        assert_eq!(GatewayServer::parse_inline_data_url("data:;base64,QUJD"), None);
        assert_eq!(GatewayServer::parse_inline_data_url("data:image/png;base64,"), None);
        assert_eq!(GatewayServer::parse_inline_data_url("not-a-url"), None);

        let content = serde_json::json!([
            {"type": "image_url"},
            {"type": "image_url", "image_url": {}},
            {"type": "image_url", "image_url": {"url": "   "}},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,"}}
        ]);
        let content = Some(&content);
        // Collection is syntactic: three parts carry no usable URL, while the
        // fourth is a non-empty string that only conversion can judge.
        assert_eq!(GatewayServer::message_image_urls(content).len(), 1);
        // Conversion is semantic, so the payload-less data URL is refused
        // rather than inlined as an empty image.
        assert!(GatewayServer::gemini_inline_data_parts(content).is_empty());

        // A plain string message is not multimodal and must stay unaffected.
        let plain = serde_json::json!("just text");
        assert!(GatewayServer::message_image_urls(Some(&plain)).is_empty());
        assert_eq!(GatewayServer::codex_user_content_parts(Some(&plain)).len(), 1);
    }

    #[test]
    fn requires_bearer_only_for_network_peers() {
        // A local caller keeps working with or without the token: the machine's
        // own user already owns the credential documents.
        assert!(!GatewayServer::peer_requires_bearer(true, false));
        assert!(!GatewayServer::peer_requires_bearer(true, true));

        // A network peer is refused until it authenticates. This is the case
        // that used to consume quota unauthenticated whenever LAN access was on.
        assert!(GatewayServer::peer_requires_bearer(false, false));
        assert!(!GatewayServer::peer_requires_bearer(false, true));
    }

    #[test]
    fn infers_agent_name_from_pi_user_agent_and_headers() {
        // Explicit header
        assert_eq!(
            GatewayServer::infer_agent_name("X-Agent-Name: Pi\r\nHost: 127.0.0.1", None),
            "Pi"
        );
        // Pi AI default macOS user agent
        assert_eq!(
            GatewayServer::infer_agent_name("User-Agent: pi (darwin 24.3.0; arm64)\r\nHost: 127.0.0.1", None),
            "Pi"
        );
        // Pi AI default linux user agent
        assert_eq!(
            GatewayServer::infer_agent_name("User-Agent: pi (linux 6.6.0; x64)\r\nHost: 127.0.0.1", None),
            "Pi"
        );
        // Pi AI browser user agent
        assert_eq!(
            GatewayServer::infer_agent_name("User-Agent: pi (browser)\r\nHost: 127.0.0.1", None),
            "Pi"
        );
        // Hermes user agent
        assert_eq!(
            GatewayServer::infer_agent_name("User-Agent: hermes/0.9.1\r\nHost: 127.0.0.1", None),
            "Hermes"
        );
        // Fallback with custom product UA
        assert_eq!(
            GatewayServer::infer_agent_name("User-Agent: CustomTool/1.0\r\nHost: 127.0.0.1", None),
            "CustomTool"
        );
        // Fallback without headers
        assert_eq!(
            GatewayServer::infer_agent_name("Host: 127.0.0.1", None),
            "API Client"
        );
    }
}

#[derive(Clone, Debug)]
pub struct UpstreamEndpoint {
    pub url: String,
    pub auth_header: String,
    pub extra_headers: Vec<(String, String)>,
    pub project: Option<String>,
    pub target_model: String,
    pub provider_name: String,
    pub _account_name: String,
    /// ChatGPT/Codex subscriptions use the local Codex runtime rather than the
    /// public OpenAI API-key endpoint. `None` means a normal HTTP upstream.
    pub codex_home: Option<String>,
    pub connection_id: String,
    pub quota_score: i64,
    pub routing_mode: String,
}

impl UpstreamEndpoint {
    pub fn provider_key(&self) -> &'static str {
        if self.provider_name.contains("Google") || self.provider_name.contains("Gemini") {
            "google"
        } else if self.provider_name.contains("OpenAI") || self.provider_name.contains("Codex") {
            "openai"
        } else if self.provider_name.contains("DeepSeek") {
            "deepseek"
        } else if self.provider_name.contains("OpenCode") {
            "opencode"
        } else {
            ""
        }
    }
}

#[derive(Debug, Clone)]
pub struct TokenManager {
    current: String,
    previous: Option<(String, Instant)>,
    grace_period: Duration,
}

impl TokenManager {
    pub fn new(token: impl Into<String>) -> Self {
        Self {
            current: token.into(),
            previous: None,
            grace_period: Duration::from_secs(60),
        }
    }

    pub fn new_with_grace(token: impl Into<String>, grace_period: Duration) -> Self {
        Self {
            current: token.into(),
            previous: None,
            grace_period,
        }
    }

    pub fn current_token(&self) -> String {
        self.current.clone()
    }

    pub fn rotate(&mut self, new_token: impl Into<String>) {
        let old = std::mem::replace(&mut self.current, new_token.into());
        self.previous = Some((old, Instant::now()));
    }

    pub fn is_valid(&self, candidate: &str) -> bool {
        let trimmed = candidate.trim();
        if trimmed == self.current {
            return true;
        }
        if let Some((ref prev, timestamp)) = self.previous {
            if trimmed == prev && timestamp.elapsed() <= self.grace_period {
                return true;
            }
        }
        false
    }
}

#[derive(Clone)]
pub struct GatewayServer {
    pub token_manager: Arc<RwLock<TokenManager>>,
    pub route_table: RouteTable,
    pub active_requests: Arc<AtomicUsize>,
    pub total_requests: Arc<AtomicUsize>,
    pub total_input_tokens: Arc<AtomicUsize>,
    pub total_output_tokens: Arc<AtomicUsize>,
    pub total_tool_calls: Arc<AtomicUsize>,
    pub is_running: Arc<AtomicBool>,
    pub recent_requests: Arc<Mutex<VecDeque<GatewayRequestRecord>>>,
    pub telemetry_store: Arc<TelemetryStore>,
    /// Hermes keeps standard OpenAI tool-call IDs but may discard vendor
    /// extension fields. Cache Gemini's required thought signatures by ID so
    /// a subsequent tool result can be replayed correctly.
    pub gemini_thought_signatures: Arc<Mutex<HashMap<String, String>>>,
    pub model_health: Arc<crate::model_health::ModelHealthEngine>,
}

impl GatewayServer {
    pub fn new(token: impl Into<String>) -> Self {
        // Models are discovered per account from the upstream provider. An
        // empty table is deliberate: legacy aliases used to silently map
        // Claude/GPT/coding-* names to unrelated paid providers.
        let route_table = RouteTable::new();

        Self {
            token_manager: Arc::new(RwLock::new(TokenManager::new(token))),
            route_table,
            active_requests: Arc::new(AtomicUsize::new(0)),
            total_requests: Arc::new(AtomicUsize::new(0)),
            total_input_tokens: Arc::new(AtomicUsize::new(0)),
            total_output_tokens: Arc::new(AtomicUsize::new(0)),
            total_tool_calls: Arc::new(AtomicUsize::new(0)),
            is_running: Arc::new(AtomicBool::new(true)),
            recent_requests: Arc::new(Mutex::new(VecDeque::new())),
            telemetry_store: Arc::new(
                TelemetryStore::new(TelemetryStore::default_db_path()).unwrap_or_else(|_| {
                    TelemetryStore::new_in_memory()
                        .expect("in-memory telemetry store failed to open")
                }),
            ),
            gemini_thought_signatures: Arc::new(Mutex::new(HashMap::new())),
            model_health: Arc::new(crate::model_health::ModelHealthEngine::new_default()),
        }
    }

    pub fn new_with_token_manager(
        token_manager: TokenManager,
        model_health: Arc<crate::model_health::ModelHealthEngine>,
    ) -> Self {
        let route_table = RouteTable::new();
        Self {
            token_manager: Arc::new(RwLock::new(token_manager)),
            route_table,
            active_requests: Arc::new(AtomicUsize::new(0)),
            total_requests: Arc::new(AtomicUsize::new(0)),
            total_input_tokens: Arc::new(AtomicUsize::new(0)),
            total_output_tokens: Arc::new(AtomicUsize::new(0)),
            total_tool_calls: Arc::new(AtomicUsize::new(0)),
            is_running: Arc::new(AtomicBool::new(true)),
            recent_requests: Arc::new(Mutex::new(VecDeque::new())),
            telemetry_store: Arc::new(
                TelemetryStore::new(TelemetryStore::default_db_path()).unwrap_or_else(|_| {
                    TelemetryStore::new_in_memory()
                        .expect("in-memory telemetry store failed to open")
                }),
            ),
            gemini_thought_signatures: Arc::new(Mutex::new(HashMap::new())),
            model_health,
        }
    }

    pub fn new_with_health(
        token: impl Into<String>,
        model_health: Arc<crate::model_health::ModelHealthEngine>,
    ) -> Self {
        let route_table = RouteTable::new();
        Self {
            token_manager: Arc::new(RwLock::new(TokenManager::new(token))),
            route_table,
            active_requests: Arc::new(AtomicUsize::new(0)),
            total_requests: Arc::new(AtomicUsize::new(0)),
            total_input_tokens: Arc::new(AtomicUsize::new(0)),
            total_output_tokens: Arc::new(AtomicUsize::new(0)),
            total_tool_calls: Arc::new(AtomicUsize::new(0)),
            is_running: Arc::new(AtomicBool::new(true)),
            recent_requests: Arc::new(Mutex::new(VecDeque::new())),
            telemetry_store: Arc::new(
                TelemetryStore::new(TelemetryStore::default_db_path()).unwrap_or_else(|_| {
                    TelemetryStore::new_in_memory()
                        .expect("in-memory telemetry store failed to open")
                }),
            ),
            gemini_thought_signatures: Arc::new(Mutex::new(HashMap::new())),
            model_health,
        }
    }

    pub fn current_token(&self) -> String {
        self.token_manager.read().unwrap().current_token()
    }

    pub fn rotate_token(&self, new_token: impl Into<String>) {
        self.token_manager.write().unwrap().rotate(new_token);
    }

    pub fn is_authorized(&self, request: &str) -> bool {
        let token_mgr = self.token_manager.read().unwrap();
        request.lines().any(|l| {
            let trimmed = l.trim();
            if let Some(val) = trimmed.strip_prefix("Authorization:") {
                let v = val.trim();
                if let Some(bearer) = v.strip_prefix("Bearer ") {
                    token_mgr.is_valid(bearer)
                } else if let Some(bearer) = v.strip_prefix("bearer ") {
                    token_mgr.is_valid(bearer)
                } else {
                    token_mgr.is_valid(v)
                }
            } else if let Some(val) = trimmed.strip_prefix("authorization:") {
                let v = val.trim();
                if let Some(bearer) = v.strip_prefix("Bearer ") {
                    token_mgr.is_valid(bearer)
                } else if let Some(bearer) = v.strip_prefix("bearer ") {
                    token_mgr.is_valid(bearer)
                } else {
                    token_mgr.is_valid(v)
                }
            } else if let Some(val) = trimmed.strip_prefix("api-key:") {
                token_mgr.is_valid(val)
            } else if let Some(val) = trimmed.strip_prefix("x-api-key:") {
                token_mgr.is_valid(val)
            } else {
                false
            }
        })
    }

    pub fn handle_trigger_model_check(&self, body: &str) -> Vec<u8> {
        let scope_req: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
        let provider = scope_req
            .get("provider")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let connection_id = scope_req
            .get("connectionId")
            .and_then(|v| v.as_str())
            .map(str::to_string);

        let (scope_desc, scope) = if let Some(providers_arr) = scope_req.get("providers").and_then(|v| v.as_array()) {
            let providers = providers_arr
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect::<Vec<_>>();
            let account_ids = scope_req
                .get("accountIds")
                .and_then(|v| v.as_array())
                .map(|arr| arr.iter().filter_map(|v| v.as_str().map(str::to_string)).collect::<Vec<_>>())
                .unwrap_or_default();
            let all_accounts = scope_req.get("allAccounts").and_then(|v| v.as_bool()).unwrap_or(true);
            let desc = format!("selective:providers={}:accounts={}", providers.join(","), if all_accounts { "all".to_string() } else { account_ids.join(",") });
            (desc, crate::model_health::CheckScope::Selective { providers, account_ids, all_accounts })
        } else {
            match (provider, connection_id) {
                (Some(p), Some(cid)) if !p.is_empty() && !cid.is_empty() => (
                    format!("{p}:{cid}"),
                    crate::model_health::CheckScope::Account {
                        provider: p,
                        connection_id: cid,
                    },
                ),
                _ => ("all".to_string(), crate::model_health::CheckScope::All),
            }
        };

        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
        let initial_targets = self.model_health.collect_targets(&home, &scope);
        let initial_total = initial_targets.len();

        if initial_total == 0 {
            return Self::response(
                "400 Bad Request",
                "application/json",
                r#"{"error":"未找到可探测的模型（目标账号可能未启用或无可用模型）"}"#,
            );
        }

        if self.model_health.try_start_job(&scope_desc, initial_total).is_err() {
            return Self::response(
                "409 Conflict",
                "application/json",
                r#"{"error":"model check already in progress"}"#,
            );
        }

        let engine = self.model_health.clone();
        std::thread::spawn(move || {
            engine.run_check(&home, scope);
        });

        Self::response(
            "202 Accepted",
            "application/json",
            &format!(r#"{{"started":true,"scope":"{scope_desc}","total":{initial_total}}}"#),
        )
    }

    fn response(status: &str, content_type: &str, body: &str) -> Vec<u8> {
        format!(
            "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS, HEAD\r\nAccess-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    /// Whether a request from this peer must present the local bearer token.
    ///
    /// The gateway binds `0.0.0.0` when LAN access is enabled, and the
    /// inference and model-list paths used to answer unauthenticated on every
    /// interface — so turning LAN access on silently published the user's
    /// model quota to the whole network while the UI claimed the local token
    /// was protecting it.
    ///
    /// A loopback peer is the machine's own user, who already owns the
    /// credential documents, so local clients keep working unchanged. Any other
    /// peer must authenticate, which is exactly what the LAN toggle promises.
    pub fn peer_requires_bearer(is_loopback: bool, authorized: bool) -> bool {
        !is_loopback && !authorized
    }

    pub fn handle_client(&self, mut stream: TcpStream) -> std::io::Result<bool> {
        // Captured before the request is read: the peer address is the only
        // fact distinguishing a local caller from a network one.
        let peer_is_loopback = stream
            .peer_addr()
            .map(|addr| addr.ip().is_loopback())
            .unwrap_or(false);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
        let mut buffer = [0_u8; 65_536];
        let count = stream.read(&mut buffer)?;
        if count == 0 {
            return Ok(false);
        }

        let mut raw_data = buffer[..count].to_vec();

        // Check if we have received full headers
        let header_end = if let Some(idx) = raw_data.windows(4).position(|w| w == b"\r\n\r\n") {
            Some((idx, 4))
        } else if let Some(idx) = raw_data.windows(2).position(|w| w == b"\n\n") {
            Some((idx, 2))
        } else {
            None
        };

        // Extract content length if any
        let header_str = String::from_utf8_lossy(&raw_data);
        let content_length: usize = header_str
            .lines()
            .find_map(|l| {
                let lower = l.to_lowercase();
                if lower.starts_with("content-length:") {
                    l.split(':').nth(1)?.trim().parse().ok()
                } else {
                    None
                }
            })
            .unwrap_or(0);

        if let Some((hdr_idx, sep_len)) = header_end {
            let body_start = hdr_idx + sep_len;
            while raw_data.len() - body_start < content_length {
                let mut chunk = [0_u8; 8192];
                let n = stream.read(&mut chunk)?;
                if n == 0 {
                    break;
                }
                raw_data.extend_from_slice(&chunk[..n]);
            }
        }

        let request = String::from_utf8_lossy(&raw_data);
        let mut lines = request.lines();
        let request_line = lines.next().unwrap_or_default();
        let mut parts = request_line.split_whitespace();
        let method = parts.next().unwrap_or_default();
        let raw_path = parts.next().unwrap_or_default();

        if method.eq_ignore_ascii_case("OPTIONS") {
            let response_bytes = Self::response("200 OK", "text/plain", "");
            stream.write_all(&response_bytes)?;
            stream.flush()?;
            return Ok(false);
        }

        // Clean query parameters and redundant /v1 prefixes
        let clean_path = raw_path
            .split('?')
            .next()
            .unwrap_or(raw_path)
            .trim_end_matches('/');
        let query_string = raw_path.split('?').nth(1).unwrap_or("");
        let status_filter = query_string.split('&').find_map(|param| {
            let mut kv = param.split('=');
            if kv.next()? == "status" {
                kv.next()
            } else {
                None
            }
        });
        let path = if clean_path.starts_with("/v1/v1/") {
            &clean_path[3..]
        } else {
            clean_path
        };

        let authorized = self.is_authorized(&request);

        // Find JSON body if any
        let body = if let Some((hdr_idx, sep_len)) = header_end {
            &request[hdr_idx + sep_len..]
        } else if let Some(idx) = request.find("\r\n\r\n") {
            &request[idx + 4..]
        } else {
            ""
        };

        let mut should_stop = false;

        // Direct upstream proxy for chat completions
        if method == "POST" && (path == "/v1/chat/completions" || path == "/chat/completions") {
            // Inference spends the user's upstream quota, so a non-loopback
            // peer must authenticate before any of it is consumed.
            if Self::peer_requires_bearer(peer_is_loopback, authorized) {
                let response = Self::response(
                    "401 Unauthorized",
                    "application/json",
                    r#"{"error":{"message":"unauthorized: this gateway is reachable from the network (LAN access is enabled), so /v1/chat/completions requires the local bearer token","type":"invalid_request_error"}}"#,
                );
                stream.write_all(&response)?;
                stream.flush()?;
                return Ok(false);
            }
            self.active_requests.fetch_add(1, Ordering::SeqCst);
            self.total_requests.fetch_add(1, Ordering::Relaxed);
            let _ = self.proxy_chat_completions(&request, body, &mut stream);
            self.active_requests.fetch_sub(1, Ordering::SeqCst);
            return Ok(false);
        }

        let response_bytes = match (method, path) {
            ("GET", "/health") => Self::response(
                "200 OK",
                "application/json",
                r#"{"status":"ok","service":"tomo-gateway"}"#,
            ),
            ("GET", "/status") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let active = self.active_requests.load(Ordering::Relaxed);
                    let total_req = self.total_requests.load(Ordering::Relaxed);
                    let in_tok = self.total_input_tokens.load(Ordering::Relaxed);
                    let out_tok = self.total_output_tokens.load(Ordering::Relaxed);
                    let tools = self.total_tool_calls.load(Ordering::Relaxed);
                    let reqs: Vec<GatewayRequestRecord> = self
                        .recent_requests
                        .lock()
                        .map(|q| q.iter().cloned().collect())
                        .unwrap_or_default();
                    let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
                    let settings = GatewaySettings::load_for_home(&home);
                    let cooling_count = AccountDynamicState::global()
                        .lock()
                        .map(|s| s.cooling_down_count())
                        .unwrap_or(0);
                    let payload = serde_json::json!({
                        "running": true,
                        "bind": "127.0.0.1",
                        "active_requests": active,
                        "total_requests": total_req,
                        "total_input_tokens": in_tok,
                        "total_output_tokens": out_tok,
                        "total_tool_calls": tools,
                        "recent_requests": reqs,
                        "providers": ["google", "deepseek", "anthropic", "openai"],
                        "model_consolidation_enabled": settings.model_consolidation_enabled,
                        "consolidated_providers": settings.consolidated_providers,
                        "cooling_down_accounts_count": cooling_count,
                        "model_health_job": self.model_health.job_status_payload(),
                    });
                    Self::response("200 OK", "application/json", &payload.to_string())
                }
            }
            ("GET", "/v1/models/all") | ("GET", "/models/all") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
                    let payload = self.model_health.models_all_payload(&home, status_filter);
                    Self::response("200 OK", "application/json", &payload.to_string())
                }
            }
            ("GET", "/internal/models/health") | ("GET", "/v1/models/health") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
                    let payload = self.model_health.models_health_diagnosis_payload(&home);
                    Self::response("200 OK", "application/json", &payload.to_string())
                }
            }
            ("GET", "/v1/models") | ("GET", "/models") => {
                // The catalog names every account-scoped model the gateway
                // serves, so it follows the same network rule as inference.
                if Self::peer_requires_bearer(peer_is_loopback, authorized) {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let payload = Self::get_dynamic_models_payload();
                    let filtered = self.model_health.filter_models_payload(payload);
                    Self::response("200 OK", "application/json", &filtered.to_string())
                }
            }
            ("POST", "/internal/model-check") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    self.handle_trigger_model_check(body)
                }
            }
            ("POST", "/internal/model-check/cancel") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let cancelled = self.model_health.cancel_job();
                    if cancelled {
                        Self::response("200 OK", "application/json", r#"{"cancelled":true}"#)
                    } else {
                        // 如果后端当前本就未在运行巡检，视为幂等成功，返回已空闲
                        Self::response(
                            "200 OK",
                            "application/json",
                            r#"{"cancelled":false,"alreadyIdle":true,"message":"no model check in progress"}"#,
                        )
                    }
                }
            }
            ("GET", "/internal/model-check/status") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let status = self.model_health.job_status_payload();
                    Self::response("200 OK", "application/json", &status.to_string())
                }
            }
            ("POST", "/v1/chat/completions") | ("POST", "/chat/completions") => {
                self.active_requests.fetch_add(1, Ordering::SeqCst);
                let resp = self.process_chat_completions(body);
                self.active_requests.fetch_sub(1, Ordering::SeqCst);
                resp
            }
            ("POST", "/v1/responses") | ("POST", "/responses") => {
                self.active_requests.fetch_add(1, Ordering::SeqCst);
                let resp = self.process_responses(body);
                self.active_requests.fetch_sub(1, Ordering::SeqCst);
                resp
            }
            ("POST", "/v1/messages") | ("POST", "/messages") => {
                self.active_requests.fetch_add(1, Ordering::SeqCst);
                let resp = self.process_anthropic_messages(body);
                self.active_requests.fetch_sub(1, Ordering::SeqCst);
                resp
            }
            ("POST", "/internal/token/rotate") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let req_json: Result<serde_json::Value, _> = serde_json::from_str(body);
                    match req_json {
                        Ok(val) => {
                            if let Some(new_token) = val.get("new_token").and_then(|t| t.as_str()) {
                                let trimmed = new_token.trim();
                                if trimmed.is_empty() {
                                    Self::response(
                                        "400 Bad Request",
                                        "application/json",
                                        r#"{"error":"new_token cannot be empty"}"#,
                                    )
                                } else {
                                    self.rotate_token(trimmed);
                                    Self::response(
                                        "200 OK",
                                        "application/json",
                                        r#"{"rotated":true}"#,
                                    )
                                }
                            } else {
                                Self::response(
                                    "400 Bad Request",
                                    "application/json",
                                    r#"{"error":"missing 'new_token' in request body"}"#,
                                )
                            }
                        }
                        Err(_) => Self::response(
                            "400 Bad Request",
                            "application/json",
                            r#"{"error":"invalid JSON"}"#,
                        ),
                    }
                }
            }
            ("POST", "/shutdown") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    should_stop = true;
                    self.is_running.store(false, Ordering::Relaxed);
                    if let Ok(addr) = stream.local_addr() {
                        let _ = std::thread::spawn(move || {
                            let _ = std::net::TcpStream::connect(addr);
                        });
                    }
                    Self::response("200 OK", "application/json", r#"{"stopping":true}"#)
                }
            }
            ("GET", "/telemetry/summary") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let query_str = raw_path.split_once('?').map(|(_, q)| q).unwrap_or("");
                    let filter = Self::parse_telemetry_filter(query_str);
                    match self.telemetry_store.query_summary(&filter) {
                        Ok(summary) => {
                            let json_body = serde_json::to_string(&summary).unwrap_or_default();
                            Self::response("200 OK", "application/json", &json_body)
                        }
                        Err(err) => {
                            let err_json = serde_json::json!({"error": err.to_string()});
                            Self::response(
                                "500 Internal Server Error",
                                "application/json",
                                &err_json.to_string(),
                            )
                        }
                    }
                }
            }
            ("GET", "/telemetry/timeseries") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let query_str = raw_path.split_once('?').map(|(_, q)| q).unwrap_or("");
                    let filter = Self::parse_telemetry_filter(query_str);
                    let map = Self::parse_query_map(query_str);
                    let interval = map.get("interval").map(|s| s.as_str()).unwrap_or("hour");
                    let metric = map.get("metric").map(|s| s.as_str()).unwrap_or("tokens");
                    match self
                        .telemetry_store
                        .query_timeseries(&filter, interval, metric)
                    {
                        Ok(timeseries) => {
                            let json_body = serde_json::to_string(&timeseries).unwrap_or_default();
                            Self::response("200 OK", "application/json", &json_body)
                        }
                        Err(err) => {
                            let err_json = serde_json::json!({"error": err.to_string()});
                            Self::response(
                                "500 Internal Server Error",
                                "application/json",
                                &err_json.to_string(),
                            )
                        }
                    }
                }
            }
            ("GET", "/telemetry/breakdown") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let query_str = raw_path.split_once('?').map(|(_, q)| q).unwrap_or("");
                    let filter = Self::parse_telemetry_filter(query_str);
                    let map = Self::parse_query_map(query_str);
                    let dimension = map
                        .get("dimension")
                        .map(|s| s.as_str())
                        .unwrap_or("provider");
                    match self.telemetry_store.query_breakdown(&filter, dimension) {
                        Ok(breakdown) => {
                            let json_body = serde_json::to_string(&breakdown).unwrap_or_default();
                            Self::response("200 OK", "application/json", &json_body)
                        }
                        Err(err) => {
                            let err_json = serde_json::json!({"error": err.to_string()});
                            Self::response(
                                "500 Internal Server Error",
                                "application/json",
                                &err_json.to_string(),
                            )
                        }
                    }
                }
            }
            ("GET", "/telemetry/requests") => {
                if !authorized {
                    Self::response(
                        "401 Unauthorized",
                        "application/json",
                        r#"{"error":"unauthorized"}"#,
                    )
                } else {
                    let query_str = raw_path.split_once('?').map(|(_, q)| q).unwrap_or("");
                    let filter = Self::parse_telemetry_filter(query_str);
                    let map = Self::parse_query_map(query_str);
                    let limit = map
                        .get("limit")
                        .and_then(|s| s.parse::<usize>().ok())
                        .unwrap_or(50);
                    let offset = map
                        .get("offset")
                        .and_then(|s| s.parse::<usize>().ok())
                        .unwrap_or(0);
                    let sort = map.get("sort").map(|s| s.as_str());
                    match self
                        .telemetry_store
                        .query_requests(&filter, limit, offset, sort)
                    {
                        Ok(reqs_resp) => {
                            let json_body = serde_json::to_string(&reqs_resp).unwrap_or_default();
                            Self::response("200 OK", "application/json", &json_body)
                        }
                        Err(err) => {
                            let err_json = serde_json::json!({"error": err.to_string()});
                            Self::response(
                                "500 Internal Server Error",
                                "application/json",
                                &err_json.to_string(),
                            )
                        }
                    }
                }
            }
            _ => Self::response(
                "404 Not Found",
                "application/json",
                r#"{"error":"not_found"}"#,
            ),
        };

        stream.write_all(&response_bytes)?;
        stream.flush()?;
        Ok(should_stop)
    }

    fn parse_query_map(query_str: &str) -> HashMap<String, String> {
        let mut map = HashMap::new();
        for pair in query_str.split('&') {
            if pair.is_empty() {
                continue;
            }
            if let Some((k, v)) = pair.split_once('=') {
                map.insert(k.to_string(), v.to_string());
            } else {
                map.insert(pair.to_string(), String::new());
            }
        }
        map
    }

    pub fn infer_agent_name(headers: &str, requested_model: Option<&str>) -> String {
        // 1. Explicit custom headers take top priority
        for line in headers.lines() {
            let trimmed = line.trim();
            let lower = trimmed.to_lowercase();
            if lower.starts_with("x-agent-name:")
                || lower.starts_with("x-agent:")
                || lower.starts_with("x-tomo-agent:")
                || lower.starts_with("x-client-name:")
                || lower.starts_with("x-requested-by:")
            {
                if let Some((_, val)) = trimmed.split_once(':') {
                    let v = val.trim();
                    if !v.is_empty() {
                        return v.to_string();
                    }
                }
            }
        }

        // 2. User-Agent inspection
        for line in headers.lines() {
            let trimmed = line.trim();
            let lower = trimmed.to_lowercase();
            if lower.starts_with("user-agent:") {
                if let Some((_, val)) = trimmed.split_once(':') {
                    let ua = val.trim();
                    let ua_lower = ua.to_lowercase();
                    if ua_lower.contains("pi-coding-agent")
                        || ua_lower.contains("@earendil-works/pi")
                        || ua_lower.contains("pi-ai")
                        || ua_lower.starts_with("pi/")
                        || ua_lower.starts_with("pi ")
                        || ua_lower.starts_with("pi(")
                        || ua_lower.contains("pi (")
                        || ua_lower == "pi"
                    {
                        return "Pi".into();
                    }
                    if ua_lower.contains("hermes") {
                        return "Hermes".into();
                    }
                    if ua_lower.contains("claude-code") || ua_lower.contains("@anthropic-ai/claude-code") {
                        return "Claude Code".into();
                    }
                    if ua_lower.contains("cursor") {
                        return "Cursor".into();
                    }
                    if ua_lower.contains("continue") {
                        return "Continue".into();
                    }
                    if ua_lower.contains("opencode") {
                        return "OpenCode".into();
                    }
                    if ua_lower.contains("aider") {
                        return "Aider".into();
                    }
                    if ua_lower.contains("roo-cline") || ua_lower.contains("roo-code") {
                        return "Roo Code".into();
                    }
                    if ua_lower.contains("cline") {
                        return "Cline".into();
                    }
                    if ua_lower.contains("deepseek-harness") || ua_lower.contains("dsh") {
                        return "DSH".into();
                    }
                    if ua_lower.contains("antigravity") || ua_lower.contains("agy") {
                        return "Antigravity".into();
                    }
                    if ua_lower.contains("codex") {
                        return "Codex".into();
                    }
                    if ua_lower.contains("curl") {
                        return "cURL".into();
                    }
                    if ua_lower.contains("postman") {
                        return "Postman".into();
                    }
                    if ua_lower.contains("insomnia") {
                        return "Insomnia".into();
                    }
                    if !ua.is_empty() {
                        let product = ua.split('/').next().unwrap_or(ua).trim();
                        if !product.is_empty() && product.len() <= 24 {
                            return product.to_string();
                        }
                    }
                }
            }
        }

        // 3. Model prefix check
        if let Some(m) = requested_model {
            let lower = m.to_lowercase();
            if lower.starts_with("pi:") || lower.starts_with("pi/") {
                return "Pi".into();
            }
            if lower.starts_with("hermes:") || lower.starts_with("hermes/") {
                return "Hermes".into();
            }
            if lower.starts_with("cursor:") || lower.starts_with("cursor/") {
                return "Cursor".into();
            }
        }

        "API Client".into()
    }

    fn parse_telemetry_filter(query_str: &str) -> TelemetryQueryFilter {
        let map = Self::parse_query_map(query_str);
        TelemetryQueryFilter {
            from: map.get("from").and_then(|s| s.parse::<i64>().ok()),
            to: map.get("to").and_then(|s| s.parse::<i64>().ok()),
            tz_offset_minutes: map
                .get("tz_offset_minutes")
                .or_else(|| map.get("timezoneOffset"))
                .and_then(|s| s.parse::<i32>().ok()),
            agent: map.get("agent").cloned().filter(|s| !s.is_empty()),
            provider: map.get("provider").cloned().filter(|s| !s.is_empty()),
            account: map.get("account").cloned().filter(|s| !s.is_empty()),
            model: map.get("model").cloned().filter(|s| !s.is_empty()),
            status: map.get("status").cloned().filter(|s| !s.is_empty()),
            fidelity: map.get("fidelity").cloned().filter(|s| !s.is_empty()),
        }
    }

    fn decode_body(raw_body: &str) -> String {
        let trimmed = raw_body.trim();
        if trimmed.starts_with('{') && trimmed.ends_with('}') {
            return trimmed.to_string();
        }
        if let Some(start) = trimmed.find('{') {
            if let Some(end) = trimmed.rfind('}') {
                if start <= end {
                    return trimmed[start..=end].to_string();
                }
            }
        }
        trimmed.to_string()
    }

    fn sanitize_messages_sequence(raw_messages: Vec<serde_json::Value>) -> Vec<serde_json::Value> {
        let mut normalized = Vec::new();

        for mut msg in raw_messages {
            let role = msg
                .get("role")
                .and_then(|r| r.as_str())
                .unwrap_or("user")
                .to_string();

            // 1. Normalize developer -> system
            if role == "developer" {
                msg["role"] = serde_json::json!("system");
            }

            // 2. Filter empty assistant messages without tool_calls
            let effective_role = msg.get("role").and_then(|r| r.as_str()).unwrap_or("user");
            let has_tool_calls = msg
                .get("tool_calls")
                .and_then(|tc| tc.as_array())
                .map(|a| !a.is_empty())
                .unwrap_or(false);

            if effective_role == "assistant" && !has_tool_calls {
                if let Some(c) = msg.get("content").and_then(|c| c.as_str()) {
                    let t = c.trim();
                    if t.is_empty() || t == "(empty)" || t == "empty" {
                        continue;
                    }
                } else if msg.get("content").is_none() || msg["content"].is_null() {
                    continue;
                }
            } else if msg.get("content").is_none() || msg["content"].is_null() {
                msg["content"] = serde_json::json!("");
            }

            normalized.push(msg);
        }

        // 3. Validate and fix tool message sequencing to prevent "Messages with role 'tool' must be a response to a preceding message with 'tool_calls'"
        let mut result = Vec::new();
        let mut pending_tool_ids = std::collections::HashSet::new();

        for msg in normalized {
            let role = msg.get("role").and_then(|r| r.as_str()).unwrap_or("user");

            if role == "assistant" {
                pending_tool_ids.clear();
                if let Some(tool_calls) = msg.get("tool_calls").and_then(|tc| tc.as_array()) {
                    for tc in tool_calls {
                        if let Some(id) = tc.get("id").and_then(|i| i.as_str()) {
                            pending_tool_ids.insert(id.to_string());
                        }
                    }
                }
                result.push(msg);
            } else if role == "tool" || role == "function" {
                let tool_id = msg
                    .get("tool_call_id")
                    .and_then(|i| i.as_str())
                    .unwrap_or("");
                if !tool_id.is_empty() && pending_tool_ids.contains(tool_id) {
                    result.push(msg);
                } else {
                    // Orphaned tool response: convert to user message with tool prefix to preserve context and satisfy API constraints
                    let content_str = if let Some(s) = msg.get("content").and_then(|c| c.as_str()) {
                        s.to_string()
                    } else {
                        msg.get("content")
                            .map(|c| c.to_string())
                            .unwrap_or_default()
                    };
                    let converted_content = if content_str.trim().is_empty() {
                        "[工具输出]".to_string()
                    } else {
                        format!("[工具输出]: {content_str}")
                    };
                    result.push(serde_json::json!({
                        "role": "user",
                        "content": converted_content
                    }));
                }
            } else {
                pending_tool_ids.clear();
                result.push(msg);
            }
        }

        if result.is_empty() {
            result.push(serde_json::json!({"role": "user", "content": "Hello"}));
        }

        result
    }

    fn proxy_chat_completions(
        &self,
        headers: &str,
        body: &str,
        stream: &mut TcpStream,
    ) -> std::io::Result<bool> {
        let clean_json = Self::decode_body(body);
        let raw_req: serde_json::Value = match serde_json::from_str(&clean_json) {
            Ok(v) => v,
            Err(e) => {
                eprintln!(
                    "[Gateway] Error parsing JSON body: {:?}, raw: {:?}",
                    e, body
                );
                let resp = Self::response(
                    "400 Bad Request",
                    "application/json",
                    &format!(
                        r#"{{"error":{{"message":"JSON parse error: {}","type":"invalid_request_error"}}}}"#,
                        e
                    ),
                );
                stream.write_all(&resp)?;
                stream.flush()?;
                return Ok(true);
            }
        };

        let Some(requested_model) = raw_req
            .get("model")
            .and_then(|model| model.as_str())
            .map(str::trim)
            .filter(|model| !model.is_empty())
        else {
            let response = Self::response(
                "400 Bad Request",
                "application/json",
                r#"{"error":{"message":"model is required; select a model exported by /v1/models","type":"invalid_request_error"}}"#,
            );
            stream.write_all(&response)?;
            stream.flush()?;
            return Ok(true);
        };
        let agent = Self::infer_agent_name(headers, Some(requested_model));
        let is_stream = raw_req
            .get("stream")
            .and_then(|s| s.as_bool())
            .unwrap_or(false);
        let start_time = std::time::Instant::now();
        let now_unix = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        // Format current time "HH:MM:SS" in Local (UTC+8)
        let time_str = {
            let total_sec = now_unix % 86400;
            let h = (total_sec / 3600 + 8) % 24;
            let m = (total_sec % 3600) / 60;
            let s = total_sec % 60;
            format!("{:02}:{:02}:{:02}", h, m, s)
        };

        let raw_messages = raw_req
            .get("messages")
            .and_then(|m| m.as_array())
            .cloned()
            .unwrap_or_default();
        let clean_messages = Self::sanitize_messages_sequence(raw_messages);
        let input_tokens = (body.len() / 4).max(1);
        self.total_input_tokens
            .fetch_add(input_tokens, Ordering::Relaxed);

        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
        let settings = GatewaySettings::load_for_home(&home);
        let max_retries = if settings.allow_failover {
            settings.max_failover_retries
        } else {
            0
        };
        let mut exclusions = Vec::new();
        let mut retry_count = 0;

        let upstream = loop {
            match Self::resolve_upstream_endpoint_with_exclusions(requested_model, &exclusions) {
                Ok(u) => {
                    let is_consolidated = u.routing_mode == "consolidated" || u.routing_mode == "pinned";
                    if let Some(codex_home) = u.codex_home.clone() {
                        match self.proxy_codex_http(
                            &agent,
                            requested_model,
                            &u,
                            &codex_home,
                            &raw_req,
                            &clean_messages,
                            is_stream,
                            now_unix,
                            &time_str,
                            start_time,
                            stream,
                        )? {
                            ProxyCallResult::Completed => return Ok(true),
                            ProxyCallResult::RetryableFailover(err_msg) => {
                                let can_retry = (is_consolidated && retry_count < max_retries) || u.routing_mode == "pinned";
                                if can_retry {
                                    if u.routing_mode == "pinned" {
                                        GatewaySettings::persist_fallback_to_smooth(&home, u.provider_key());
                                    }
                                    if let Ok(mut state) = AccountDynamicState::global().lock() {
                                        state.mark_cooldown(
                                            &u.connection_id,
                                            std::time::Duration::from_secs(settings.cooldown_seconds),
                                        );
                                    }
                                    exclusions.push(u.connection_id.clone());
                                    retry_count += 1;
                                    continue;
                                }
                                Self::write_gateway_error(stream, requested_model, is_stream, now_unix, &err_msg)?;
                                return Ok(true);
                            }
                        }
                    }

                    if u.provider_name == "Google Gemini" {
                        match self.proxy_gemini_oauth(
                            &agent,
                            requested_model,
                            &u,
                            &raw_req,
                            &clean_messages,
                            is_stream,
                            now_unix,
                            &time_str,
                            start_time,
                            stream,
                        )? {
                            ProxyCallResult::Completed => return Ok(true),
                            ProxyCallResult::RetryableFailover(err_msg) => {
                                let can_retry = (is_consolidated && retry_count < max_retries) || u.routing_mode == "pinned";
                                if can_retry {
                                    if u.routing_mode == "pinned" {
                                        GatewaySettings::persist_fallback_to_smooth(&home, u.provider_key());
                                    }
                                    if let Ok(mut state) = AccountDynamicState::global().lock() {
                                        state.mark_cooldown(
                                            &u.connection_id,
                                            std::time::Duration::from_secs(settings.cooldown_seconds),
                                        );
                                    }
                                    exclusions.push(u.connection_id.clone());
                                    retry_count += 1;
                                    continue;
                                }
                                Self::write_gateway_error(stream, requested_model, is_stream, now_unix, &err_msg)?;
                                return Ok(true);
                            }
                        }
                    }

                    let mut payload = serde_json::json!({
                        "model": u.target_model,
                        "messages": clean_messages,
                        "stream": is_stream,
                    });

                    if let Some(t) = raw_req.get("temperature") {
                        payload["temperature"] = t.clone();
                    }
                    if let Some(p) = raw_req.get("top_p") {
                        payload["top_p"] = p.clone();
                    }
                    if let Some(max) = raw_req
                        .get("max_tokens")
                        .or_else(|| raw_req.get("max_completion_tokens"))
                    {
                        payload["max_tokens"] = max.clone();
                    }
                    if let Some(tools) = raw_req.get("tools") {
                        payload["tools"] = tools.clone();
                    }
                    if let Some(tc) = raw_req.get("tool_choice") {
                        payload["tool_choice"] = tc.clone();
                    }
                    if let Some(re) = raw_req.get("reasoning_effort") {
                        payload["reasoning_effort"] = re.clone();
                    }
                    if let Some(th) = raw_req.get("thinking") {
                        payload["thinking"] = th.clone();
                    }

                    let payload_str = payload.to_string();

                    let mut cmd = std::process::Command::new("curl");
                    cmd.arg("-s")
                        .arg("-N")
                        .arg("-X")
                        .arg("POST")
                        .arg(&u.url)
                        .arg("-H")
                        .arg(format!("Authorization: {}", u.auth_header))
                        .arg("-H")
                        .arg("Content-Type: application/json")
                        .arg("-d")
                        .arg(&payload_str)
                        .stdout(std::process::Stdio::piped())
                        .stderr(std::process::Stdio::null());
                    for (name, value) in &u.extra_headers {
                        cmd.arg("-H").arg(format!("{name}: {value}"));
                    }

                    let mut child = match cmd.spawn() {
                        Ok(c) => c,
                        Err(e) => {
                            let can_retry = (is_consolidated && retry_count < max_retries) || u.routing_mode == "pinned";
                            if can_retry {
                                if u.routing_mode == "pinned" {
                                    GatewaySettings::persist_fallback_to_smooth(&home, u.provider_key());
                                }
                                if let Ok(mut state) = AccountDynamicState::global().lock() {
                                    state.mark_cooldown(
                                        &u.connection_id,
                                        std::time::Duration::from_secs(settings.cooldown_seconds),
                                    );
                                }
                                exclusions.push(u.connection_id.clone());
                                retry_count += 1;
                                continue;
                            }
                            let resp = Self::response(
                                "502 Bad Gateway",
                                "application/json",
                                &format!(
                                    r#"{{"error":{{"message":"Failed to spawn upstream process: {}","type":"upstream_error"}}}}"#,
                                    e
                                ),
                            );
                            stream.write_all(&resp)?;
                            stream.flush()?;
                            return Ok(true);
                        }
                    };

                    let stdout = match child.stdout.take() {
                        Some(s) => s,
                        None => {
                            let can_retry = (is_consolidated && retry_count < max_retries) || u.routing_mode == "pinned";
                            if can_retry {
                                if u.routing_mode == "pinned" {
                                    GatewaySettings::persist_fallback_to_smooth(&home, u.provider_key());
                                }
                                if let Ok(mut state) = AccountDynamicState::global().lock() {
                                    state.mark_cooldown(
                                        &u.connection_id,
                                        std::time::Duration::from_secs(settings.cooldown_seconds),
                                    );
                                }
                                exclusions.push(u.connection_id.clone());
                                retry_count += 1;
                                continue;
                            }
                            let resp = Self::response(
                                "502 Bad Gateway",
                                "application/json",
                                r#"{"error":{"message":"Failed to capture upstream process stdout","type":"upstream_error"}}"#,
                            );
                            stream.write_all(&resp)?;
                            stream.flush()?;
                            return Ok(true);
                        }
                    };

                    use std::io::BufRead;
                    let mut reader = std::io::BufReader::new(stdout);
                    let mut first_line = String::new();
                    match reader.read_line(&mut first_line) {
                        Ok(0) => {
                            let _ = child.wait();
                            let can_retry = (is_consolidated && retry_count < max_retries) || u.routing_mode == "pinned";
                            if can_retry {
                                if u.routing_mode == "pinned" {
                                    GatewaySettings::persist_fallback_to_smooth(&home, u.provider_key());
                                }
                                if let Ok(mut state) = AccountDynamicState::global().lock() {
                                    state.mark_cooldown(
                                        &u.connection_id,
                                        std::time::Duration::from_secs(settings.cooldown_seconds),
                                    );
                                }
                                exclusions.push(u.connection_id.clone());
                                retry_count += 1;
                                continue;
                            }
                        }
                        Ok(_) => {
                            let trimmed = first_line.trim();
                            let is_err = (trimmed.starts_with('{') || trimmed.starts_with('['))
                                && (trimmed.contains("\"error\"") || trimmed.contains("\"message\""));
                            let can_retry = (is_consolidated && retry_count < max_retries) || u.routing_mode == "pinned";
                            if is_err && can_retry {
                                let _ = child.kill();
                                let _ = child.wait();
                                if u.routing_mode == "pinned" {
                                    GatewaySettings::persist_fallback_to_smooth(&home, u.provider_key());
                                }
                                if let Ok(mut state) = AccountDynamicState::global().lock() {
                                    state.mark_cooldown(
                                        &u.connection_id,
                                        std::time::Duration::from_secs(settings.cooldown_seconds),
                                    );
                                }
                                exclusions.push(u.connection_id.clone());
                                retry_count += 1;
                                continue;
                            }
                        }
                        Err(_) => {
                            let _ = child.wait();
                            let can_retry = (is_consolidated && retry_count < max_retries) || u.routing_mode == "pinned";
                            if can_retry {
                                if u.routing_mode == "pinned" {
                                    GatewaySettings::persist_fallback_to_smooth(&home, u.provider_key());
                                }
                                if let Ok(mut state) = AccountDynamicState::global().lock() {
                                    state.mark_cooldown(
                                        &u.connection_id,
                                        std::time::Duration::from_secs(settings.cooldown_seconds),
                                    );
                                }
                                exclusions.push(u.connection_id.clone());
                                retry_count += 1;
                                continue;
                            }
                        }
                    }

                    // Pre-TTFT passed: downstream headers will now be sent with this upstream endpoint
                    let header_sent = true;
                    let ttft_ms = start_time.elapsed().as_millis() as u64;
                    if is_stream {
                        let hdr = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS, HEAD\r\nAccess-Control-Allow-Headers: *\r\nx-tomo-routed-account: {}\r\nx-tomo-quota-score: {}\r\nx-tomo-routing-mode: {}\r\nConnection: close\r\n\r\n",
                            u.connection_id, u.quota_score, u.routing_mode
                        );
                        stream.write_all(hdr.as_bytes())?;
                    } else {
                        let hdr = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS, HEAD\r\nAccess-Control-Allow-Headers: *\r\nx-tomo-routed-account: {}\r\nx-tomo-quota-score: {}\r\nx-tomo-routing-mode: {}\r\nConnection: close\r\n\r\n",
                            u.connection_id, u.quota_score, u.routing_mode
                        );
                        stream.write_all(hdr.as_bytes())?;
                    }

                    let mut emitted_done = false;
                    let mut emitted_any_data = false;
                    let mut output_chars = 0;

                    if !first_line.is_empty() {
                        let trimmed = first_line.trim();
                        if is_stream {
                            if (trimmed.starts_with('{') || trimmed.starts_with('['))
                                && trimmed.contains("\"error\"")
                            {
                                let err_msg_opt =
                                    if let Ok(err_json) = serde_json::from_str::<serde_json::Value>(trimmed) {
                                        let err_obj = if let Some(arr) = err_json.as_array() {
                                            arr.first().and_then(|item| item.get("error"))
                                        } else {
                                            err_json.get("error")
                                        };
                                        err_obj
                                            .and_then(|e| e.get("message"))
                                            .and_then(|m| m.as_str())
                                            .map(|s| s.to_string())
                                    } else {
                                        None
                                    };

                                let msg = err_msg_opt.unwrap_or_else(|| "上游模型响应异常".to_string());
                                let sse_err = format!(
                                    "data: {{\"id\":\"resp_err\",\"object\":\"chat.completion.chunk\",\"created\":{},\"model\":\"{}\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"[提示] {}\"}},\"finish_reason\":null}}]}}\n\n",
                                    now_unix, requested_model, msg
                                );
                                stream.write_all(sse_err.as_bytes())?;
                                let sse_stop = format!(
                                    "data: {{\"id\":\"resp_stop\",\"object\":\"chat.completion.chunk\",\"created\":{},\"model\":\"{}\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n",
                                    now_unix, requested_model
                                );
                                stream.write_all(sse_stop.as_bytes())?;
                                stream.flush()?;
                                emitted_any_data = true;
                                emitted_done = true;
                            } else {
                                if trimmed.starts_with("data:") {
                                    emitted_any_data = true;
                                    output_chars += trimmed.len();
                                }
                                if trimmed.contains("[DONE]") {
                                    emitted_done = true;
                                }
                                stream.write_all(first_line.as_bytes())?;
                                stream.flush()?;
                            }
                        } else {
                            stream.write_all(first_line.as_bytes())?;
                            stream.flush()?;
                        }
                    }

                    if !emitted_done {
                        let mut line_buf = String::new();
                        while let Ok(n) = reader.read_line(&mut line_buf) {
                            if n == 0 {
                                break;
                            }
                            let trimmed = line_buf.trim();
                            if is_stream {
                                if (trimmed.starts_with('{') || trimmed.starts_with('['))
                                    && trimmed.contains("\"error\"")
                                {
                                    let err_msg_opt = if let Ok(err_json) = serde_json::from_str::<serde_json::Value>(trimmed) {
                                        let err_obj = if let Some(arr) = err_json.as_array() {
                                            arr.first().and_then(|item| item.get("error"))
                                        } else {
                                            err_json.get("error")
                                        };
                                        err_obj
                                            .and_then(|e| e.get("message"))
                                            .and_then(|m| m.as_str())
                                            .map(|s| s.to_string())
                                    } else {
                                        None
                                    };

                                    let msg = err_msg_opt.unwrap_or_else(|| "上游模型响应异常".to_string());
                                    let sse_err = format!(
                                        "data: {{\"id\":\"resp_err\",\"object\":\"chat.completion.chunk\",\"created\":{},\"model\":\"{}\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"[提示] {}\"}},\"finish_reason\":null}}]}}\n\n",
                                        now_unix, requested_model, msg
                                    );
                                    stream.write_all(sse_err.as_bytes())?;
                                    let sse_stop = format!(
                                        "data: {{\"id\":\"resp_stop\",\"object\":\"chat.completion.chunk\",\"created\":{},\"model\":\"{}\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n",
                                        now_unix, requested_model
                                    );
                                    stream.write_all(sse_stop.as_bytes())?;
                                    stream.flush()?;
                                    emitted_any_data = true;
                                    emitted_done = true;
                                    line_buf.clear();
                                    break;
                                }

                                if trimmed.starts_with("data:") {
                                    emitted_any_data = true;
                                    output_chars += trimmed.len();
                                }
                                if trimmed.contains("[DONE]") {
                                    emitted_done = true;
                                }
                            }

                            stream.write_all(line_buf.as_bytes())?;
                            stream.flush()?;
                            line_buf.clear();
                        }
                    }

                    let _ = child.wait();

                    let latency_ms = start_time.elapsed().as_millis() as u64;
                    let output_tokens = (output_chars / 4).max(12);
                    self.total_output_tokens
                        .fetch_add(output_tokens, Ordering::Relaxed);

                    if is_stream {
                        if !header_sent || !emitted_any_data {
                            if !header_sent {
                                let hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS, HEAD\r\nAccess-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n";
                                stream.write_all(hdr.as_bytes())?;
                            }
                            let error = format!(
                                "data: {{\"id\":\"resp_upstream_error\",\"object\":\"chat.completion.chunk\",\"created\":{},\"model\":\"{}\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"[网关错误] 选定账号的上游未返回有效响应；请求未回退或降级。\"}},\"finish_reason\":null}}]}}\n\n",
                                now_unix, requested_model
                            );
                            stream.write_all(error.as_bytes())?;
                            stream.flush()?;
                        }

                        if !emitted_done {
                            let finish_event = format!(
                                "data: {{\"id\":\"resp_finish\",\"object\":\"chat.completion.chunk\",\"created\":{},\"model\":\"{}\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n",
                                now_unix, requested_model
                            );
                            stream.write_all(finish_event.as_bytes())?;
                            stream.flush()?;
                        }
                    }

                    break (u, latency_ms, ttft_ms, output_tokens);
                }
                Err(err_msg) => {
                    // Strict isolation: Return error immediately, NEVER fallback to another paid provider!
                    let hdr = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS, HEAD\r\nAccess-Control-Allow-Headers: *\r\nConnection: close\r\n\r\n";
                    stream.write_all(hdr.as_bytes())?;
                    let sse_err = format!(
                        "data: {{\"id\":\"resp_err\",\"object\":\"chat.completion.chunk\",\"created\":{},\"model\":\"{}\",\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"[提示] {}\"}},\"finish_reason\":null}}]}}\n\n",
                        now_unix, requested_model, err_msg
                    );
                    stream.write_all(sse_err.as_bytes())?;
                    let finish = format!(
                        "data: {{\"id\":\"resp_finish\",\"object\":\"chat.completion.chunk\",\"created\":{},\"model\":\"{}\",\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n",
                        now_unix, requested_model
                    );
                    stream.write_all(finish.as_bytes())?;
                    stream.flush()?;
                    return Ok(true);
                }
            }
        };

        let (upstream, latency_ms, ttft_ms, output_tokens) = upstream;

        // Save request record to recent_requests deque
        let record = GatewayRequestRecord {
            id: format!("req_{}_{}", now_unix, requested_model.replace(' ', "_")),
            time: time_str,
            agent: agent.clone(),
            ingress_protocol: "OpenAI Chat".into(),
            model_alias: requested_model.to_string(),
            target_provider: upstream.provider_name.clone(),
            target_model: upstream.target_model.clone(),
            latency_ms,
            ttft_ms: if ttft_ms > 0 { ttft_ms } else { latency_ms / 3 },
            tokens: input_tokens + output_tokens,
            fidelity: "100%".into(),
            status: "200 OK".into(),
        };

        if let Ok(mut lock) = self.recent_requests.lock() {
            lock.push_front(record);
            if lock.len() > 50 {
                lock.pop_back();
            }
        }

        self.telemetry_store.record_event(TelemetryEvent {
            id: format!("req_{}_{}", now_unix, requested_model.replace(' ', "_")),
            timestamp: (now_unix * 1000) as i64,
            agent: agent.clone(),
            ingress_protocol: "OpenAI Chat".into(),
            provider: upstream.provider_name.clone(),
            account: upstream._account_name.clone(),
            model_alias: requested_model.to_string(),
            target_model: upstream.target_model.clone(),
            input_tokens: Some(input_tokens as i64),
            output_tokens: Some(output_tokens as i64),
            cache_read_tokens: None,
            cache_write_tokens: None,
            total_tokens: Some((input_tokens + output_tokens) as i64),
            latency_ms: latency_ms as i64,
            ttft_ms: (if ttft_ms > 0 { ttft_ms } else { latency_ms / 3 }) as i64,
            status_code: 200,
            status: "success".into(),
            error_category: None,
            fidelity: "actual".into(),
            is_stream,
            tool_calls_count: 0,
            estimated_cost: None,
            currency: None,
        });

        Ok(true)
    }

    /// Translate OpenAI Chat Completions to Antigravity Cloud Code's OAuth-only
    /// `GenerateContentRequest` envelope.  This includes function tools: they
    /// are converted into Gemini `functionDeclarations`, never routed to a
    /// different provider.
    fn proxy_gemini_oauth(
        &self,
        agent: &str,
        requested_model: &str,
        upstream: &UpstreamEndpoint,
        raw_req: &serde_json::Value,
        messages: &[serde_json::Value],
        is_stream: bool,
        now_unix: u64,
        time_str: &str,
        start_time: std::time::Instant,
        stream: &mut TcpStream,
    ) -> std::io::Result<ProxyCallResult> {
        let mut system_parts = Vec::new();
        let mut contents = Vec::new();
        let mut replayed_gemini_call_ids = std::collections::HashSet::new();
        let mut skipped_gemini_call_ids = std::collections::HashSet::new();
        for message in messages {
            let role = message
                .get("role")
                .and_then(|value| value.as_str())
                .unwrap_or("user");
            if role == "system" {
                if let Some(text) = Self::message_text(message.get("content")) {
                    if !text.trim().is_empty() {
                        system_parts.push(serde_json::json!({"text": text}));
                    }
                }
                continue;
            }

            let mut parts = Vec::new();
            if let Some(text) = Self::message_text(message.get("content")) {
                if !text.trim().is_empty() {
                    parts.push(serde_json::json!({"text": text}));
                }
            }
            // An attachment travels as a Gemini `inlineData` part. Only a
            // `data:` URL can be inlined; a remote URL has no Cloud Code
            // equivalent here, so it is skipped rather than sent as text.
            parts.extend(Self::gemini_inline_data_parts(message.get("content")));
            if role == "assistant" {
                if let Some(tool_calls) =
                    message.get("tool_calls").and_then(|value| value.as_array())
                {
                    for call in tool_calls {
                        let Some(function) = call.get("function") else {
                            continue;
                        };
                        let Some(name) = function.get("name").and_then(|value| value.as_str())
                        else {
                            continue;
                        };
                        let args = function
                            .get("arguments")
                            .and_then(|value| value.as_str())
                            .and_then(|value| serde_json::from_str::<serde_json::Value>(value).ok())
                            .filter(|value| value.is_object())
                            .unwrap_or_else(|| serde_json::json!({}));
                        let native_call = serde_json::json!({"name": name, "args": args});
                        // Cloud Code returns a thought signature with some
                        // function calls. Replaying it is required when the
                        // client submits that call's tool result.
                        let mut native_part = serde_json::json!({"functionCall": native_call});
                        let signature = function
                            .get("thought_signature")
                            .or_else(|| function.get("thoughtSignature"))
                            .and_then(|value| value.as_str())
                            .map(str::to_string)
                            .or_else(|| {
                                call.get("id")
                                    .and_then(|value| value.as_str())
                                    .and_then(|id| {
                                        self.gemini_thought_signature_for_call(id, name, &args)
                                    })
                            })
                            .or_else(|| self.gemini_thought_signature_for_call("", name, &args));
                        if let Some(signature) = signature {
                            native_part["thoughtSignature"] = serde_json::json!(signature);
                            if let Some(call_id) = call.get("id").and_then(|value| value.as_str()) {
                                replayed_gemini_call_ids.insert(call_id.to_string());
                            }
                            parts.push(native_part);
                        } else {
                            // A conversation created before this Gateway started
                            // may contain a Gemini tool call whose opaque thought
                            // signature is no longer recoverable. Never invent a
                            // signature: replaying that part would make Gemini
                            // reject the entire request. Skip this obsolete call
                            // and its paired result instead of leaking an internal
                            // compatibility marker into the user's conversation.
                            if let Some(call_id) = call.get("id").and_then(|value| value.as_str()) {
                                skipped_gemini_call_ids.insert(call_id.to_string());
                            }
                        }
                    }
                }
            } else if role == "tool" {
                let call_id = message
                    .get("tool_call_id")
                    .and_then(|value| value.as_str())
                    .unwrap_or("");
                if skipped_gemini_call_ids.contains(call_id) {
                    continue;
                }
                if !replayed_gemini_call_ids.contains(call_id) {
                    // A standalone tool result has no replayable signed
                    // functionCall in this request window. It cannot form a
                    // valid Gemini turn, so omit it rather than presenting the
                    // result as user text.
                    continue;
                }
                let Some(name) = Self::openai_tool_name_for_call(messages, call_id) else {
                    Self::write_gateway_error(
                        stream,
                        requested_model,
                        is_stream,
                        now_unix,
                        "Gemini 工具结果缺少对应的工具名称。请求未回退到其他供应商。",
                    )?;
                    return Ok(ProxyCallResult::Completed);
                };
                let response = Self::message_text(message.get("content"))
                    .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
                    .unwrap_or_else(|| serde_json::json!({"result": Self::message_text(message.get("content")).unwrap_or_default()}));
                let response = Self::gemini_function_response_object(response);
                parts.push(
                    serde_json::json!({"functionResponse": {"name": name, "response": response}}),
                );
            }
            if !parts.is_empty() {
                contents.push(serde_json::json!({
                    "role": if role == "assistant" { "model" } else { "user" },
                    "parts": parts
                }));
            }
        }
        if contents.is_empty() {
            Self::write_gateway_error(
                stream,
                requested_model,
                is_stream,
                now_unix,
                "请求中没有可发送给 Gemini 的文本内容。",
            )?;
            return Ok(ProxyCallResult::Completed);
        }

        let mut generation_request = serde_json::json!({"contents": contents});
        if !system_parts.is_empty() {
            generation_request["systemInstruction"] = serde_json::json!({"parts": system_parts});
        }
        let mut generation = serde_json::Map::new();
        if let Some(value) = raw_req.get("temperature") {
            generation.insert("temperature".into(), value.clone());
        }
        if let Some(value) = raw_req.get("top_p") {
            generation.insert("topP".into(), value.clone());
        }
        if let Some(value) = raw_req
            .get("max_tokens")
            .or_else(|| raw_req.get("max_completion_tokens"))
        {
            generation.insert("maxOutputTokens".into(), value.clone());
        }
        if let Some(budget) = Self::gemini_thinking_budget(raw_req) {
            generation.insert(
                "thinkingConfig".into(),
                serde_json::json!({
                    "thinkingBudget": budget
                }),
            );
        }
        if !generation.is_empty() {
            generation_request["generationConfig"] = serde_json::Value::Object(generation);
        }
        if let Some(tools) = Self::openai_tools_to_gemini(raw_req) {
            generation_request["tools"] = tools;
        }
        if let Some(tool_config) = Self::openai_tool_choice_to_gemini(raw_req.get("tool_choice")) {
            generation_request["toolConfig"] = tool_config;
        }

        let project = upstream
            .project
            .as_deref()
            .filter(|value| !value.trim().is_empty());
        let Some(project) = project else {
            Self::write_gateway_error(
                stream,
                requested_model,
                is_stream,
                now_unix,
                "Google OAuth 账号缺少 Cloud Code 项目，无法调用 Antigravity。",
            )?;
            return Ok(ProxyCallResult::Completed);
        };
        let payload = Self::cloud_code_generate_payload(
            project,
            &upstream.target_model,
            generation_request,
            &format!("codexling-{now_unix}"),
        );

        let output = match Self::run_gemini_cloud_code_request(upstream, &payload, false) {
            Ok(output) if output.status.success() => output,
            Ok(output) => {
                let configured_route_error = Self::curl_failure_message(&output);
                match Self::run_gemini_cloud_code_request(upstream, &payload, true) {
                    Ok(direct_output) if direct_output.status.success() => direct_output,
                    Ok(direct_output) => {
                        let message = format!(
                            "Gemini OAuth 上游请求失败（配置网络：{configured_route_error}；直连：{}）",
                            Self::curl_failure_message(&direct_output)
                        );
                        Self::log_gateway_error(&message);
                        if upstream.routing_mode == "consolidated" || upstream.routing_mode == "pinned" {
                            return Ok(ProxyCallResult::RetryableFailover(message));
                        }
                        Self::write_gateway_error(
                            stream,
                            requested_model,
                            is_stream,
                            now_unix,
                            &message,
                        )?;
                        return Ok(ProxyCallResult::Completed);
                    }
                    Err(error) => {
                        let message = format!(
                            "Gemini OAuth 上游请求失败（配置网络：{configured_route_error}；直连：{error}）"
                        );
                        Self::log_gateway_error(&message);
                        if upstream.routing_mode == "consolidated" || upstream.routing_mode == "pinned" {
                            return Ok(ProxyCallResult::RetryableFailover(message));
                        }
                        Self::write_gateway_error(
                            stream,
                            requested_model,
                            is_stream,
                            now_unix,
                            &message,
                        )?;
                        return Ok(ProxyCallResult::Completed);
                    }
                }
            }
            Err(error) => match Self::run_gemini_cloud_code_request(upstream, &payload, true) {
                Ok(direct_output) if direct_output.status.success() => direct_output,
                Ok(direct_output) => {
                    let message = format!(
                        "Gemini OAuth 上游请求失败（配置网络：{error}；直连：{}）",
                        Self::curl_failure_message(&direct_output)
                    );
                    Self::log_gateway_error(&message);
                    if upstream.routing_mode == "consolidated" || upstream.routing_mode == "pinned" {
                        return Ok(ProxyCallResult::RetryableFailover(message));
                    }
                    Self::write_gateway_error(
                        stream,
                        requested_model,
                        is_stream,
                        now_unix,
                        &message,
                    )?;
                    return Ok(ProxyCallResult::Completed);
                }
                Err(direct_error) => {
                    let message = format!(
                        "Gemini OAuth 上游请求失败（配置网络：{error}；直连：{direct_error}）"
                    );
                    Self::log_gateway_error(&message);
                    if upstream.routing_mode == "consolidated" || upstream.routing_mode == "pinned" {
                        return Ok(ProxyCallResult::RetryableFailover(message));
                    }
                    Self::write_gateway_error(
                        stream,
                        requested_model,
                        is_stream,
                        now_unix,
                        &message,
                    )?;
                    return Ok(ProxyCallResult::Completed);
                }
            },
        };
        let body: serde_json::Value = match serde_json::from_slice(&output.stdout) {
            Ok(body) => body,
            Err(_) => {
                let err_msg = "Gemini OAuth 上游返回了无效响应。";
                if upstream.routing_mode == "consolidated" || upstream.routing_mode == "pinned" {
                    return Ok(ProxyCallResult::RetryableFailover(err_msg.to_string()));
                }
                Self::write_gateway_error(
                    stream,
                    requested_model,
                    is_stream,
                    now_unix,
                    err_msg,
                )?;
                return Ok(ProxyCallResult::Completed);
            }
        };
        if let Some(message) = body
            .get("error")
            .and_then(|error| error.get("message"))
            .and_then(|value| value.as_str())
        {
            let formatted = format!("Gemini OAuth 请求失败：{message}");
            if upstream.routing_mode == "consolidated" || upstream.routing_mode == "pinned" {
                return Ok(ProxyCallResult::RetryableFailover(formatted));
            }
            Self::write_gateway_error(
                stream,
                requested_model,
                is_stream,
                now_unix,
                &formatted,
            )?;
            return Ok(ProxyCallResult::Completed);
        }
        let message = self.cloud_code_response_message(&body);
        let Some(message) = message else {
            let err_msg = "Gemini OAuth 上游未返回文本或工具调用结果。";
            if upstream.routing_mode == "consolidated" || upstream.routing_mode == "pinned" {
                return Ok(ProxyCallResult::RetryableFailover(err_msg.to_string()));
            }
            Self::write_gateway_error(
                stream,
                requested_model,
                is_stream,
                now_unix,
                err_msg,
            )?;
            return Ok(ProxyCallResult::Completed);
        };
        let latency_ms = start_time.elapsed().as_millis() as u64;
        let answer_len = message
            .get("content")
            .and_then(|value| value.as_str())
            .map(str::len)
            .unwrap_or(0);
        // Prefer the real token usage reported by Gemini's usageMetadata.
        // Only fall back to character-length estimates when the upstream
        // envelope omits it, and label the fidelity accordingly so the UI
        // never presents an estimate as measured data.
        let (usage_input, usage_output, usage_cache_read, usage_total, usage_fidelity) =
            match Self::gemini_usage_metadata(&body) {
                Some((input, output, cache_read, total)) => {
                    (Some(input), Some(output), cache_read, Some(total), "actual")
                }
                None => (
                    Some((messages.len() * 10) as i64),
                    Some(((answer_len / 4).max(1)) as i64),
                    None,
                    Some(((messages.len() * 10) + (answer_len / 4).max(1)) as i64),
                    "estimated",
                ),
            };
        self.total_output_tokens
            .fetch_add(usage_output.unwrap_or(0).max(1) as usize, Ordering::Relaxed);
        let model = serde_json::to_string(requested_model).unwrap_or_else(|_| "\"google\"".into());
        let message_json = serde_json::to_string(&message)
            .unwrap_or_else(|_| "{\"role\":\"assistant\",\"content\":\"\"}".into());
        let tool_calls = message.get("tool_calls").cloned();
        let has_tools = tool_calls.is_some();
        let reasoning = message.get("reasoning_content").and_then(|v| v.as_str());
        let content = message.get("content").and_then(|v| v.as_str());

        let response = if is_stream {
            let mut sse_chunks = Vec::new();
            if let Some(reasoning_text) = reasoning {
                if !reasoning_text.trim().is_empty() {
                    let r_json = serde_json::to_string(reasoning_text).unwrap_or_else(|_| "\"\"".into());
                    sse_chunks.push(format!(
                        "data: {{\"id\":\"gemini_oauth\",\"object\":\"chat.completion.chunk\",\"created\":{now_unix},\"model\":{model},\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"reasoning_content\":{r_json}}},\"finish_reason\":null}}]}}\n\n"
                    ));
                }
            }
            if let Some(content_text) = content {
                if !content_text.is_empty() {
                    let c_json = serde_json::to_string(content_text).unwrap_or_else(|_| "\"\"".into());
                    sse_chunks.push(format!(
                        "data: {{\"id\":\"gemini_oauth\",\"object\":\"chat.completion.chunk\",\"created\":{now_unix},\"model\":{model},\"choices\":[{{\"index\":0,\"delta\":{{\"content\":{c_json}}},\"finish_reason\":null}}]}}\n\n"
                    ));
                }
            }
            let finish_reason = if let Some(ref tc) = tool_calls {
                let tc_json = serde_json::to_string(tc).unwrap_or_else(|_| "[]".into());
                sse_chunks.push(format!(
                    "data: {{\"id\":\"gemini_oauth\",\"object\":\"chat.completion.chunk\",\"created\":{now_unix},\"model\":{model},\"choices\":[{{\"index\":0,\"delta\":{{\"tool_calls\":{tc_json}}},\"finish_reason\":null}}]}}\n\n"
                ));
                "tool_calls"
            } else {
                "stop"
            };
            sse_chunks.push(format!(
                "data: {{\"id\":\"gemini_oauth\",\"object\":\"chat.completion.chunk\",\"created\":{now_unix},\"model\":{model},\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{finish_reason}\"}}]}}\n\ndata: [DONE]\n\n"
            ));

            let mut body_str = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nAccess-Control-Allow-Origin: *\r\nx-tomo-routed-account: {}\r\nx-tomo-quota-score: {}\r\nx-tomo-routing-mode: {}\r\nConnection: close\r\n\r\n",
                upstream.connection_id, upstream.quota_score, upstream.routing_mode
            );
            body_str.push_str(&sse_chunks.concat());
            body_str
        } else {
            let finish_reason = if tool_calls.is_some() {
                "tool_calls"
            } else {
                "stop"
            };
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nx-tomo-routed-account: {}\r\nx-tomo-quota-score: {}\r\nx-tomo-routing-mode: {}\r\nConnection: close\r\n\r\n{{\"id\":\"gemini_oauth\",\"object\":\"chat.completion\",\"created\":{now_unix},\"model\":{model},\"choices\":[{{\"index\":0,\"message\":{message_json},\"finish_reason\":\"{finish_reason}\"}}]}}",
                upstream.connection_id, upstream.quota_score, upstream.routing_mode
            )
        };
        stream.write_all(response.as_bytes())?;
        stream.flush()?;
        if let Ok(mut records) = self.recent_requests.lock() {
            records.push_front(GatewayRequestRecord {
                id: format!("req_{}_{}", now_unix, requested_model.replace(' ', "_")),
                time: time_str.into(),
                agent: agent.to_string(),
                ingress_protocol: "OpenAI Chat".into(),
                model_alias: requested_model.into(),
                target_provider: "Google Gemini".into(),
                target_model: upstream.target_model.clone(),
                latency_ms,
                ttft_ms: latency_ms,
                tokens: usage_output.unwrap_or(0).max(1) as usize,
                fidelity: "OAuth native".into(),
                status: "200 OK".into(),
            });
        }
        self.telemetry_store.record_event(TelemetryEvent {
            id: format!("req_{}_{}", now_unix, requested_model.replace(' ', "_")),
            timestamp: (now_unix * 1000) as i64,
            agent: agent.to_string(),
            ingress_protocol: "OpenAI Chat".into(),
            provider: "Google Gemini".into(),
            account: upstream._account_name.clone(),
            model_alias: requested_model.into(),
            target_model: upstream.target_model.clone(),
            input_tokens: usage_input,
            output_tokens: usage_output,
            cache_read_tokens: usage_cache_read,
            cache_write_tokens: None,
            total_tokens: usage_total,
            latency_ms: latency_ms as i64,
            ttft_ms: latency_ms as i64,
            status_code: 200,
            status: "success".into(),
            error_category: None,
            fidelity: usage_fidelity.into(),
            is_stream,
            tool_calls_count: if has_tools { 1 } else { 0 },
            estimated_cost: None,
            currency: None,
        });
        Ok(ProxyCallResult::Completed)
    }

    pub(crate) fn cloud_code_generate_payload(
        project: &str,
        model: &str,
        request: serde_json::Value,
        request_id: &str,
    ) -> serde_json::Value {
        serde_json::json!({
            "project": project,
            "model": model,
            "request": request,
            "requestId": request_id,
            "userAgent": "Tomo Gateway"
        })
    }

    /// Cloud Code wraps the native Vertex/Gemini response in `response`, while
    /// a few compatible deployments return the native payload directly.
    #[cfg(test)]
    fn cloud_code_response_text(body: &serde_json::Value) -> Option<String> {
        body.pointer("/response/candidates/0/content/parts")
            .or_else(|| body.pointer("/candidates/0/content/parts"))
            .and_then(|value| value.as_array())
            .map(|parts| {
                parts
                    .iter()
                    .filter_map(|part| part.get("text").and_then(|text| text.as_str()))
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .filter(|text| !text.trim().is_empty())
    }

    fn openai_tools_to_gemini(raw_req: &serde_json::Value) -> Option<serde_json::Value> {
        let declarations = raw_req
            .get("tools")?
            .as_array()?
            .iter()
            .filter_map(|tool| {
                let function = tool.get("function")?;
                let name = function.get("name")?.as_str()?;
                let mut declaration = serde_json::Map::new();
                declaration.insert("name".into(), serde_json::Value::String(name.into()));
                if let Some(description) = function.get("description") {
                    declaration.insert("description".into(), description.clone());
                }
                declaration.insert(
                    "parameters".into(),
                    Self::normalize_tool_schema(function.get("parameters")),
                );
                Some(serde_json::Value::Object(declaration))
            })
            .collect::<Vec<_>>();
        (!declarations.is_empty())
            .then(|| serde_json::json!([{"functionDeclarations": declarations}]))
    }

    /// Gemini's `FunctionResponse.response` is a protobuf Struct, so its
    /// top-level value must be a JSON object. OpenAI-compatible clients such
    /// as DSH can legitimately return an array, string, number or boolean as
    /// a tool result. Keep that value intact under `result` instead of sending
    /// an invalid protobuf payload upstream.
    fn gemini_function_response_object(response: serde_json::Value) -> serde_json::Value {
        if response.is_object() {
            response
        } else {
            serde_json::json!({"result": response})
        }
    }

    /// Hermes can expose third-party custom tools with OpenAI-flavoured schema
    /// extensions (or an older `$schema` declaration).  Cloud Code forwards
    /// Claude tools to a Draft 2020-12 validator, which rejects an entire
    /// request when one tool is malformed.  Keep the portable JSON Schema
    /// subset and discard only non-standard/invalid extensions.
    fn normalize_tool_schema(schema: Option<&serde_json::Value>) -> serde_json::Value {
        fn normalize(value: &serde_json::Value) -> Option<serde_json::Value> {
            if value.is_boolean() {
                return Some(value.clone());
            }
            let object = value.as_object()?;
            let mut result = serde_json::Map::new();

            if let Some(description) = object.get("description").and_then(|v| v.as_str()) {
                result.insert("description".into(), serde_json::json!(description));
            }
            if let Some(title) = object.get("title").and_then(|v| v.as_str()) {
                result.insert("title".into(), serde_json::json!(title));
            }
            if let Some(reference) = object.get("$ref").and_then(|v| v.as_str()) {
                result.insert("$ref".into(), serde_json::json!(reference));
            }
            if let Some(kind) = object.get("type") {
                let valid_kind = |kind: &str| {
                    matches!(
                        kind,
                        "object" | "array" | "string" | "number" | "integer" | "boolean" | "null"
                    )
                };
                if let Some(kind) = kind.as_str().filter(|kind| valid_kind(kind)) {
                    result.insert("type".into(), serde_json::json!(kind));
                } else if let Some(kinds) = kind.as_array() {
                    let kinds = kinds
                        .iter()
                        .filter_map(|value| value.as_str())
                        .filter(|kind| valid_kind(kind))
                        .collect::<Vec<_>>();
                    if !kinds.is_empty() {
                        result.insert("type".into(), serde_json::json!(kinds));
                    }
                }
            }
            if let Some(properties) = object.get("properties").and_then(|v| v.as_object()) {
                let properties = properties
                    .iter()
                    .filter_map(|(name, value)| normalize(value).map(|value| (name.clone(), value)))
                    .collect::<serde_json::Map<_, _>>();
                result.insert("properties".into(), serde_json::Value::Object(properties));
            }
            if let Some(required) = object.get("required").and_then(|v| v.as_array()) {
                let required = required
                    .iter()
                    .filter_map(|value| value.as_str())
                    .collect::<Vec<_>>();
                result.insert("required".into(), serde_json::json!(required));
            }
            if let Some(items) = object.get("items").and_then(normalize) {
                result.insert("items".into(), items);
            }
            if let Some(additional) = object.get("additionalProperties").and_then(normalize) {
                result.insert("additionalProperties".into(), additional);
            }
            for keyword in ["allOf", "anyOf", "oneOf"] {
                if let Some(values) = object.get(keyword).and_then(|value| value.as_array()) {
                    let values = values.iter().filter_map(normalize).collect::<Vec<_>>();
                    if !values.is_empty() {
                        result.insert(keyword.into(), serde_json::Value::Array(values));
                    }
                }
            }
            if let Some(values) = object.get("enum").and_then(|value| value.as_array()) {
                result.insert("enum".into(), serde_json::Value::Array(values.clone()));
            }
            for keyword in [
                "const",
                "default",
                "minimum",
                "maximum",
                "exclusiveMinimum",
                "exclusiveMaximum",
                "multipleOf",
                "minLength",
                "maxLength",
                "pattern",
                "format",
                "minItems",
                "maxItems",
                "uniqueItems",
                "minProperties",
                "maxProperties",
            ] {
                if let Some(value) = object.get(keyword) {
                    result.insert(keyword.into(), value.clone());
                }
            }
            Some(serde_json::Value::Object(result))
        }

        let mut normalized = schema
            .and_then(normalize)
            .unwrap_or_else(|| serde_json::json!({}));
        if !normalized.is_object() {
            normalized = serde_json::json!({});
        }
        // Function arguments are always an object for the Gemini/Claude tool
        // bridge.  A malformed top-level `type` must not poison all tools.
        if normalized.get("type").is_none() {
            normalized["type"] = serde_json::json!("object");
        }
        normalized
    }

    fn openai_tool_choice_to_gemini(
        choice: Option<&serde_json::Value>,
    ) -> Option<serde_json::Value> {
        let choice = choice?;
        let mut config = serde_json::Map::new();
        if let Some(name) = choice
            .pointer("/function/name")
            .and_then(|value| value.as_str())
        {
            config.insert("mode".into(), serde_json::json!("ANY"));
            config.insert("allowedFunctionNames".into(), serde_json::json!([name]));
        } else {
            match choice.as_str() {
                Some("none") => {
                    config.insert("mode".into(), serde_json::json!("NONE"));
                }
                Some("required") => {
                    config.insert("mode".into(), serde_json::json!("ANY"));
                }
                Some("auto") | None => return None,
                Some(_) => return None,
            }
        }
        Some(serde_json::json!({"functionCallingConfig": config}))
    }

    fn openai_tool_name_for_call(messages: &[serde_json::Value], call_id: &str) -> Option<String> {
        messages.iter().rev().find_map(|message| {
            message
                .get("tool_calls")?
                .as_array()?
                .iter()
                .find_map(|call| {
                    (call.get("id").and_then(|value| value.as_str()) == Some(call_id))
                        .then(|| {
                            call.pointer("/function/name")
                                .and_then(|value| value.as_str())
                                .map(str::to_string)
                        })
                        .flatten()
                })
        })
    }

    /// Sends the OAuth Cloud Code request through the inherited network route
    /// or, on retry, directly. It deliberately never places credentials in
    /// returned diagnostics.
    pub(crate) fn run_gemini_cloud_code_request(
        upstream: &UpstreamEndpoint,
        payload: &serde_json::Value,
        bypass_proxy: bool,
    ) -> Result<std::process::Output, String> {
        let mut command = std::process::Command::new("curl");
        command
            .arg("-sS")
            // HTTP 4xx/5xx must be an actionable failure too. Without this,
            // curl exits successfully for a body-less 502 and the Gateway
            // cannot perform its direct-network retry.
            .arg("--fail-with-body")
            .arg("--connect-timeout")
            .arg("5")
            .arg("--max-time")
            .arg("90")
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
            .arg(r#"Client-Metadata: {"ideType":"ANTIGRAVITY"}"#)
            .arg("--data-binary")
            .arg("@-")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        if bypass_proxy {
            command.arg("--noproxy").arg("*");
        } else if let Some(proxy) = Self::gemini_proxy_override() {
            command.arg("--proxy").arg(proxy);
        }
        for (name, value) in &upstream.extra_headers {
            command.arg("-H").arg(format!("{name}: {value}"));
        }
        let mut child = command
            .spawn()
            .map_err(|error| format!("无法启动 Gemini OAuth 请求：{error}"))?;
        if let Some(mut stdin) = child.stdin.take() {
            use std::io::Write;
            let _ = stdin.write_all(payload.to_string().as_bytes());
        }
        child
            .wait_with_output()
            .map_err(|error| format!("等待 Gemini OAuth 响应失败：{error}"))
    }

    fn curl_failure_message(output: &std::process::Output) -> String {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let transport = stderr.trim();
        let upstream = Self::gemini_upstream_error_summary(&output.stdout);
        match (upstream, transport.is_empty()) {
            (Some(upstream), false) => format!(
                "{upstream}；传输详情：{}",
                Self::diagnostic_excerpt(transport, 240)
            ),
            (Some(upstream), true) => upstream,
            (None, false) => Self::diagnostic_excerpt(transport, 400),
            (None, true) => format!("curl 退出码 {:?}", output.status.code()),
        }
    }

    /// A provider-specific route avoids forcing every GUI application onto
    /// SOCKS just because one Google endpoint is unstable over HTTP CONNECT.
    fn gemini_proxy_override() -> Option<String> {
        if let Some(proxy) = std::env::var("CODEXLING_GEMINI_PROXY")
            .ok()
            .and_then(|value| Self::validated_proxy_url(&value, false))
        {
            return Some(proxy);
        }

        // A SOCKS proxy advertised by the host is safer for Cloud Code when
        // its DNS is resolved by the proxy. Curl otherwise prefers HTTPS_PROXY
        // (HTTP CONNECT), which is unreliable for some local proxy clients.
        for key in ["all_proxy", "ALL_PROXY"] {
            if let Some(proxy) = std::env::var(key)
                .ok()
                .and_then(|value| Self::validated_proxy_url(&value, true))
            {
                return Some(proxy);
            }
        }

        None
    }

    fn validated_proxy_url(value: &str, prefer_remote_dns: bool) -> Option<String> {
        let value = value.trim();
        if value.is_empty() || value.chars().any(char::is_whitespace) {
            return None;
        }
        if prefer_remote_dns {
            if let Some(address) = value.strip_prefix("socks5://") {
                return Some(format!("socks5h://{address}"));
            }
            if value.starts_with("socks5h://") {
                return Some(value.to_string());
            }
            return None;
        }
        ["http://", "https://", "socks5://", "socks5h://"]
            .iter()
            .any(|scheme| value.starts_with(scheme))
            .then(|| value.to_string())
    }

    /// Extracts the useful, non-secret portion of Google's error response.
    /// OAuth credentials live in request headers and must never be copied into
    /// diagnostics, so only known error fields are read from JSON responses.
    fn gemini_upstream_error_summary(stdout: &[u8]) -> Option<String> {
        let body = String::from_utf8_lossy(stdout);
        let body = body.trim();
        if body.is_empty() {
            return None;
        }

        let Ok(value) = serde_json::from_str::<serde_json::Value>(body) else {
            // Reverse proxies sometimes return a short plain-text/HTML error.
            // Strip markup to make it readable while keeping the excerpt small.
            let mut text = String::with_capacity(body.len().min(320));
            let mut inside_tag = false;
            for character in body.chars() {
                match character {
                    '<' => inside_tag = true,
                    '>' => inside_tag = false,
                    _ if !inside_tag => text.push(character),
                    _ => {}
                }
            }
            let excerpt = Self::diagnostic_excerpt(&text, 280);
            return (!excerpt.is_empty()).then(|| format!("上游响应：{excerpt}"));
        };

        let error = value.get("error").unwrap_or(&value);
        let mut fields = Vec::new();
        if let Some(code) = error.get("code").and_then(|item| item.as_i64()) {
            fields.push(format!("HTTP {code}"));
        }
        if let Some(status) = error.get("status").and_then(|item| item.as_str()) {
            fields.push(Self::diagnostic_excerpt(status, 80));
        }
        if let Some(message) = error
            .get("message")
            .and_then(|item| item.as_str())
            .or_else(|| error.as_str())
        {
            fields.push(Self::diagnostic_excerpt(message, 360));
        }
        if let Some(description) = value
            .get("error_description")
            .and_then(|item| item.as_str())
        {
            fields.push(Self::diagnostic_excerpt(description, 240));
        }

        let mut reasons = Vec::new();
        if let Some(details) = error.get("details").and_then(|item| item.as_array()) {
            for detail in details {
                for key in ["reason", "status", "message", "description", "retryDelay"] {
                    if let Some(item) = detail.get(key).and_then(|item| item.as_str()) {
                        let item = Self::diagnostic_excerpt(item, 160);
                        if !item.is_empty() && !reasons.contains(&item) {
                            reasons.push(item);
                        }
                    }
                }
                if let Some(violations) = detail.get("violations").and_then(|item| item.as_array()) {
                    for violation in violations {
                        if let Some(description) = violation
                            .get("description")
                            .and_then(|item| item.as_str())
                        {
                            let description = Self::diagnostic_excerpt(description, 200);
                            if !description.is_empty() && !reasons.contains(&description) {
                                reasons.push(description);
                            }
                        }
                    }
                }
            }
        }
        if !reasons.is_empty() {
            fields.push(format!("原因：{}", reasons.join(" / ")));
        }

        if fields.is_empty() {
            Some("上游返回了 JSON 错误，但未包含标准 error/message 字段".into())
        } else {
            Some(format!("上游响应：{}", fields.join(" · ")))
        }
    }

    fn diagnostic_excerpt(value: &str, limit: usize) -> String {
        let words = value.split_whitespace().collect::<Vec<_>>();
        let mut safe_words: Vec<String> = Vec::with_capacity(words.len());
        let mut redact_words = 0usize;
        for word in words {
            if redact_words > 0 {
                redact_words -= 1;
                continue;
            }
            let lower = word.to_ascii_lowercase();
            if lower == "bearer" {
                safe_words.push("Bearer [REDACTED]".into());
                redact_words = 1;
                continue;
            }
            let sensitive_key = [
                "authorization",
                "access_token",
                "refresh_token",
                "client_secret",
                "api_key",
            ]
            .iter()
            .any(|key| {
                lower == *key
                    || lower == format!("{key}:")
                    || lower.starts_with(&format!("{key}="))
            });
            if sensitive_key {
                if let Some((key, _)) = word.split_once('=') {
                    safe_words.push(format!("{key}=[REDACTED]"));
                } else {
                    safe_words.push(format!("{word} [REDACTED]"));
                    redact_words = if lower.starts_with("authorization") { 2 } else { 1 };
                }
                continue;
            }
            safe_words.push(word.into());
        }
        let normalized = safe_words.join(" ");
        let mut excerpt: String = normalized.chars().take(limit).collect();
        if normalized.chars().count() > limit {
            excerpt.push('…');
        }
        excerpt
    }

    fn log_gateway_error(message: &str) {
        use std::io::Write;
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
        let directory = std::path::Path::new(&home).join("Library/Application Support/Tomo");
        if std::fs::create_dir_all(&directory).is_err() {
            return;
        }
        let path = directory.join("gateway.log");
        if std::fs::metadata(&path)
            .map(|metadata| metadata.len() > 512 * 1024)
            .unwrap_or(false)
        {
            let _ = std::fs::write(&path, "");
        }
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let timestamp = Self::current_unix_seconds();
            let _ = writeln!(file, "[{timestamp}] {message}");
        }
    }

    /// Pi and Hermes may recreate OpenAI-compatible tool-call IDs when they
    /// reconstruct a conversation. Gemini requires the original thought
    /// signature nevertheless, so retain it under both the generated ID and
    /// a stable function-name/arguments key.
    fn gemini_thought_signature_key(name: &str, args: &serde_json::Value) -> String {
        let arguments = serde_json::to_string(args).unwrap_or_else(|_| "{}".into());
        format!("function:{name}:{arguments}")
    }

    fn gemini_thought_signature_for_call(
        &self,
        call_id: &str,
        name: &str,
        args: &serde_json::Value,
    ) -> Option<String> {
        let cache = self.gemini_thought_signatures.lock().ok()?;
        cache.get(call_id).cloned().or_else(|| {
            cache
                .get(&Self::gemini_thought_signature_key(name, args))
                .cloned()
        })
    }

    fn cloud_code_response_message(&self, body: &serde_json::Value) -> Option<serde_json::Value> {
        let parts = body
            .pointer("/response/candidates/0/content/parts")
            .or_else(|| body.pointer("/candidates/0/content/parts"))?
            .as_array()?;
        let mut reasoning_parts = Vec::new();
        let mut text_parts = Vec::new();
        for part in parts {
            if let Some(text) = part.get("text").and_then(|text| text.as_str()) {
                let is_thought = part.get("thought").and_then(|t| t.as_bool()).unwrap_or(false);
                if is_thought {
                    reasoning_parts.push(text);
                } else {
                    text_parts.push(text);
                }
            }
        }
        let reasoning = reasoning_parts.join("\n");
        let text = text_parts.join("\n");
        let mut tool_calls = Vec::new();
        for part in parts {
            let Some(call) = part.get("functionCall") else {
                continue;
            };
            let Some(name) = call.get("name").and_then(|value| value.as_str()) else {
                continue;
            };
            let args = call
                .get("args")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));
            let Some(arguments) = serde_json::to_string(&args).ok() else {
                continue;
            };
            let mut function = serde_json::json!({"name":name,"arguments":arguments});
            let call_id = format!(
                "call_gemini_{}",
                self.total_tool_calls.fetch_add(1, Ordering::Relaxed)
            );
            if let Some(signature) = part
                .get("thoughtSignature")
                .or_else(|| part.get("thought_signature"))
                .or_else(|| call.get("thoughtSignature"))
                .or_else(|| call.get("thought_signature"))
                .and_then(|value| value.as_str())
            {
                // This vendor extension is ignored by ordinary OpenAI
                // providers but preserves this Gemini call's required state.
                function["thought_signature"] = serde_json::json!(signature);
                if let Ok(mut cache) = self.gemini_thought_signatures.lock() {
                    if cache.len() >= 1024 {
                        cache.clear();
                    }
                    cache.insert(call_id.clone(), signature.to_string());
                    cache.insert(
                        Self::gemini_thought_signature_key(name, &args),
                        signature.to_string(),
                    );
                }
            }
            let index = tool_calls.len();
            tool_calls.push(serde_json::json!({"index": index, "id": call_id, "type":"function", "function":function}));
        }
        if text.trim().is_empty() && tool_calls.is_empty() && reasoning.trim().is_empty() {
            return None;
        }
        let mut message = serde_json::json!({"role":"assistant", "content": if text.trim().is_empty() { serde_json::Value::Null } else { serde_json::Value::String(text) }});
        if !reasoning.trim().is_empty() {
            message["reasoning_content"] = serde_json::Value::String(reasoning);
        }
        if !tool_calls.is_empty() {
            message["tool_calls"] = serde_json::Value::Array(tool_calls);
        }
        Some(message)
    }

    /// Extract or map an incoming thinking/reasoning budget for Gemini's `thinkingConfig`.
    /// Supports OpenAI's `reasoning_effort` ("none" -> 0, "low" -> 1024, "medium" -> 2048, "high" -> 8192),
    /// Anthropic's `thinking` object ({"type":"disabled"} -> 0, {"budget_tokens":N} -> N),
    /// and Gemini native `thinking_budget` / `thinkingBudget` / `thinkingConfig.thinkingBudget`.
    pub(crate) fn gemini_thinking_budget(raw_req: &serde_json::Value) -> Option<i64> {
        // 1. OpenAI reasoning_effort
        if let Some(re) = raw_req.get("reasoning_effort") {
            if let Some(s) = re.as_str() {
                let trimmed = s.trim().to_lowercase();
                match trimmed.as_str() {
                    "none" | "off" | "disabled" => return Some(0),
                    "low" => return Some(1024),
                    "medium" => return Some(2048),
                    "high" => return Some(8192),
                    _ => {
                        if let Ok(num) = trimmed.parse::<i64>() {
                            return Some(num);
                        }
                    }
                }
            } else if let Some(num) = re.as_i64() {
                return Some(num);
            }
        }

        // 2. Anthropic thinking block
        if let Some(th) = raw_req.get("thinking") {
            if let Some(obj) = th.as_object() {
                if let Some(t) = obj.get("type").and_then(|v| v.as_str()) {
                    if t.eq_ignore_ascii_case("disabled") {
                        return Some(0);
                    }
                }
                if let Some(budget) = obj.get("budget_tokens").and_then(|v| v.as_i64()) {
                    return Some(budget);
                }
            } else if let Some(b) = th.as_bool() {
                if !b {
                    return Some(0);
                }
            }
        }

        // 3. Direct thinking_budget / thinkingBudget
        if let Some(tb) = raw_req.get("thinking_budget").or_else(|| raw_req.get("thinkingBudget")) {
            if let Some(num) = tb.as_i64() {
                return Some(num);
            } else if let Some(s) = tb.as_str() {
                if let Ok(num) = s.trim().parse::<i64>() {
                    return Some(num);
                }
            }
        }

        // 4. Nested thinkingConfig / thinking_config
        if let Some(num) = raw_req
            .pointer("/thinkingConfig/thinkingBudget")
            .or_else(|| raw_req.pointer("/thinking_config/thinking_budget"))
            .and_then(|v| v.as_i64())
        {
            return Some(num);
        }

        None
    }

    /// Extract the real token usage from a Gemini `GenerateContentResponse`.
    /// Cloud Code wraps the response in an outer `response` object; plain
    /// Gemini API responses carry `usageMetadata` at the top level.
    /// Returns (input, output, cache_read, total) where `input` is the raw
    /// `promptTokenCount` (already includes cached tokens) and `output`
    /// combines `candidatesTokenCount` with hidden `thoughtsTokenCount`.
    fn gemini_usage_metadata(
        body: &serde_json::Value,
    ) -> Option<(i64, i64, Option<i64>, i64)> {
        let usage = body
            .pointer("/response/usageMetadata")
            .or_else(|| body.pointer("/usageMetadata"))?;
        let input = usage.get("promptTokenCount").and_then(|v| v.as_i64())?;
        let candidates = usage
            .get("candidatesTokenCount")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let thoughts = usage
            .get("thoughtsTokenCount")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let cache_read = usage
            .get("cachedContentTokenCount")
            .and_then(|v| v.as_i64())
            .filter(|value| *value > 0);
        let total = usage
            .get("totalTokenCount")
            .and_then(|v| v.as_i64())
            .unwrap_or(input + candidates + thoughts);
        Some((input, candidates + thoughts, cache_read, total))
    }

    /// Bridge an OpenAI / Codex subscription directly through OpenAI's native
    /// Responses API over HTTP/SSE (`https://chatgpt.com/backend-api/codex/responses`).
    /// This bypasses any requirement for a local `codex` CLI binary and supports
    /// native SSE streaming directly from OpenAI.
    fn proxy_codex_http(
        &self,
        agent: &str,
        requested_model: &str,
        upstream: &UpstreamEndpoint,
        codex_home: &str,
        raw_req: &serde_json::Value,
        messages: &[serde_json::Value],
        is_stream: bool,
        now_unix: u64,
        time_str: &str,
        start_time: std::time::Instant,
        stream: &mut TcpStream,
    ) -> std::io::Result<ProxyCallResult> {
        let target_model = &upstream.target_model;
        let account_name = &upstream._account_name;

        let access_token = match Self::codex_oauth_access_token(codex_home) {
            Ok(token) => token,
            Err(error) => {
                Self::write_gateway_error(
                    stream,
                    requested_model,
                    is_stream,
                    now_unix,
                    &error,
                )?;
                return Ok(ProxyCallResult::Completed);
            }
        };

        let mut input = Vec::new();
        let mut instructions: Option<String> = None;

        for message in messages {
            let role = message
                .get("role")
                .and_then(|value| value.as_str())
                .unwrap_or("user");
            let content = message.get("content");

            if role == "system" || role == "developer" {
                if let Some(text) = Self::message_text(content) {
                    if !text.trim().is_empty() {
                        if instructions.is_none() {
                            instructions = Some(text);
                        } else {
                            input.push(serde_json::json!({
                                "type": "message",
                                "role": "developer",
                                "content": [{"type": "input_text", "text": text}]
                            }));
                        }
                    }
                }
            } else if role == "user" {
                // Images are collected beside the text: `message_text` sees
                // only text parts, so an attachment would otherwise be dropped
                // and the model would answer about an image it never received.
                let parts = Self::codex_user_content_parts(content);
                if !parts.is_empty() {
                    input.push(serde_json::json!({
                        "type": "message",
                        "role": "user",
                        "content": parts
                    }));
                }
            } else if role == "assistant" {
                let mut parts = Vec::new();
                if let Some(text) = Self::message_text(content) {
                    if !text.trim().is_empty() {
                        parts.push(serde_json::json!({"type": "output_text", "text": text}));
                    }
                }
                if !parts.is_empty() {
                    input.push(serde_json::json!({
                        "type": "message",
                        "role": "assistant",
                        "content": parts
                    }));
                }
            } else if role == "tool" {
                if let Some(call_id) = message.get("tool_call_id").and_then(|v| v.as_str()) {
                    let output_text = Self::message_text(content).unwrap_or_default();
                    input.push(serde_json::json!({
                        "type": "function_call_output",
                        "call_id": call_id,
                        "output": output_text
                    }));
                }
            }
        }

        if input.is_empty() && instructions.is_none() {
            Self::write_gateway_error(
                stream,
                requested_model,
                is_stream,
                now_unix,
                "请求中没有可发送给 Codex 的文本内容。",
            )?;
            return Ok(ProxyCallResult::Completed);
        }

        let mut payload = serde_json::json!({
            "model": target_model,
            "store": false,
            "stream": true,
            "input": input,
        });

        if let Some(inst) = instructions {
            payload["instructions"] = serde_json::json!(inst);
        }

        // Note: OpenAI Codex backend-api/codex/responses rejects `temperature` and `max_output_tokens`
        // with "Unsupported parameter: ..." (HTTP 400). Do not forward them.

        if let Some(tools) = raw_req.get("tools").and_then(|v| v.as_array()) {
            let mut responses_tools = Vec::new();
            for tool in tools {
                if let Some(func) = tool.get("function") {
                    let name = func.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    let desc = func.get("description");
                    let params = func.get("parameters").cloned().unwrap_or(serde_json::json!({}));
                    let mut t = serde_json::json!({
                        "type": "function",
                        "name": name,
                        "parameters": params,
                    });
                    if let Some(d) = desc {
                        t["description"] = d.clone();
                    }
                    responses_tools.push(t);
                }
            }
            if !responses_tools.is_empty() {
                payload["tools"] = serde_json::Value::Array(responses_tools);
            }
        }
        if let Some(re) = raw_req.get("reasoning_effort").and_then(|v| v.as_str()) {
            payload["reasoning"] = serde_json::json!({
                "effort": re
            });
        }

        let execute_stream = |token_to_use: &str| -> std::io::Result<(std::process::Child, std::process::ChildStdout)> {
            let mut cmd = std::process::Command::new("curl");
            cmd.arg("-sN")
                .arg("--connect-timeout")
                .arg("10")
                .arg("--max-time")
                .arg("300")
                .arg("-X")
                .arg("POST")
                .arg("https://chatgpt.com/backend-api/codex/responses")
                .arg("-H")
                .arg(format!("Authorization: Bearer {token_to_use}"))
                .arg("-H")
                .arg("Content-Type: application/json")
                .arg("-H")
                .arg("Accept: text/event-stream")
                .arg("-H")
                .arg("User-Agent: codex_cli_rs/0.153.4 (Macos; arm64) codex_exec")
                .arg("-H")
                .arg("OpenAI-Beta: responses_websockets=2026-02-06")
                .arg("--data-binary")
                .arg("@-")
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped());

            let mut child = cmd.spawn()?;
            if let Some(mut stdin) = child.stdin.take() {
                use std::io::Write;
                let _ = stdin.write_all(payload.to_string().as_bytes());
            }
            let stdout = child.stdout.take().ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::Other, "Failed to capture curl stdout")
            })?;
            Ok((child, stdout))
        };

        let (mut child, stdout) = match execute_stream(&access_token) {
            Ok(pair) => pair,
            Err(e) => {
                let err_msg = format!("无法启动网络连接：{e}");
                if upstream.routing_mode == "consolidated" || upstream.routing_mode == "pinned" {
                    return Ok(ProxyCallResult::RetryableFailover(err_msg));
                }
                Self::write_gateway_error(
                    stream,
                    requested_model,
                    is_stream,
                    now_unix,
                    &err_msg,
                )?;
                return Ok(ProxyCallResult::Completed);
            }
        };

        use std::io::{BufRead, BufReader, Write};
        let mut reader = BufReader::new(stdout);
        let mut first_line = String::new();
        let _ = reader.read_line(&mut first_line);

        let trimmed_first = first_line.trim();
        if trimmed_first.starts_with('{')
            && (trimmed_first.contains("\"detail\"") || trimmed_first.contains("\"error\""))
            && (trimmed_first.contains("Unauthorized") || trimmed_first.contains("token_expired"))
        {
            let _ = child.kill();
            if let Ok(new_token) = Self::force_refresh_codex_token(codex_home) {
                if let Ok((new_child, new_stdout)) = execute_stream(&new_token) {
                    child = new_child;
                    reader = BufReader::new(new_stdout);
                    first_line.clear();
                    let _ = reader.read_line(&mut first_line);
                }
            }
        }

        let trimmed_first = first_line.trim();
        if trimmed_first.starts_with('{')
            && (trimmed_first.contains("\"detail\"") || trimmed_first.contains("\"error\""))
        {
            let _ = child.kill();
            let err_msg = if let Ok(v) = serde_json::from_str::<serde_json::Value>(trimmed_first) {
                v.get("detail")
                    .and_then(|d| d.as_str())
                    .or_else(|| v.pointer("/error/message").and_then(|m| m.as_str()))
                    .unwrap_or(trimmed_first)
                    .to_string()
            } else {
                trimmed_first.to_string()
            };
            if upstream.routing_mode == "consolidated" || upstream.routing_mode == "pinned" {
                return Ok(ProxyCallResult::RetryableFailover(err_msg));
            }
            Self::write_gateway_error(
                stream,
                requested_model,
                is_stream,
                now_unix,
                &err_msg,
            )?;
            return Ok(ProxyCallResult::Completed);
        }

        let mut header_sent = false;
        let mut accumulated_text = String::new();
        let mut input_tokens = (messages.len() * 10) as i64;
        let mut output_tokens = 0i64;

        let mut process_data_line = |data_json: &str, s: &mut TcpStream| -> std::io::Result<()> {
            if let Ok(event) = serde_json::from_str::<serde_json::Value>(data_json) {
                let event_type = event.get("type").and_then(|v| v.as_str()).unwrap_or("");
                if event_type == "response.output_text.delta" {
                    if let Some(delta) = event.get("delta").and_then(|v| v.as_str()) {
                        accumulated_text.push_str(delta);
                        if is_stream {
                            if !header_sent {
                                let hdr = format!(
                                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nAccess-Control-Allow-Origin: *\r\nx-tomo-routed-account: {}\r\nx-tomo-quota-score: {}\r\nx-tomo-routing-mode: {}\r\nConnection: close\r\n\r\n",
                                    upstream.connection_id, upstream.quota_score, upstream.routing_mode
                                );
                                s.write_all(hdr.as_bytes())?;
                                header_sent = true;
                            }
                            let chunk = serde_json::json!({
                                "id": "resp_codex",
                                "object": "chat.completion.chunk",
                                "created": now_unix,
                                "model": requested_model,
                                "choices": [{
                                    "index": 0,
                                    "delta": {
                                        "role": "assistant",
                                        "content": delta
                                    },
                                    "finish_reason": serde_json::Value::Null
                                }]
                            });
                            s.write_all(format!("data: {chunk}\n\n").as_bytes())?;
                            s.flush()?;
                        }
                    }
                } else if event_type == "response.completed" {
                    if let Some(usage) = event.pointer("/response/usage") {
                        if let Some(in_t) = usage.get("input_tokens").and_then(|v| v.as_i64()) {
                            input_tokens = in_t;
                        }
                        if let Some(out_t) = usage.get("output_tokens").and_then(|v| v.as_i64()) {
                            output_tokens = out_t;
                        }
                    }
                }
            }
            Ok(())
        };

        if trimmed_first.starts_with("data:") {
            let data_part = trimmed_first[5..].trim();
            process_data_line(data_part, stream)?;
        }

        let mut line_buf = String::new();
        while let Ok(n) = reader.read_line(&mut line_buf) {
            if n == 0 {
                break;
            }
            let trimmed = line_buf.trim();
            if trimmed.starts_with("data:") {
                let data_part = trimmed[5..].trim();
                process_data_line(data_part, stream)?;
            }
            line_buf.clear();
        }

        let _ = child.wait();

        if is_stream {
            if !header_sent {
                let hdr = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nAccess-Control-Allow-Origin: *\r\nx-tomo-routed-account: {}\r\nx-tomo-quota-score: {}\r\nx-tomo-routing-mode: {}\r\nConnection: close\r\n\r\n",
                    upstream.connection_id, upstream.quota_score, upstream.routing_mode
                );
                stream.write_all(hdr.as_bytes())?;
            }
            let stop_chunk = serde_json::json!({
                "id": "resp_codex",
                "object": "chat.completion.chunk",
                "created": now_unix,
                "model": requested_model,
                "choices": [{
                    "index": 0,
                    "delta": {},
                    "finish_reason": "stop"
                }]
            });
            stream.write_all(format!("data: {stop_chunk}\n\ndata: [DONE]\n\n").as_bytes())?;
            stream.flush()?;
        } else {
            let resp = serde_json::json!({
                "id": "resp_codex",
                "object": "chat.completion",
                "created": now_unix,
                "model": requested_model,
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": accumulated_text
                    },
                    "finish_reason": "stop"
                }]
            });
            let body = resp.to_string();
            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nx-tomo-routed-account: {}\r\nx-tomo-quota-score: {}\r\nx-tomo-routing-mode: {}\r\nConnection: close\r\n\r\n{body}",
                body.len(),
                upstream.connection_id,
                upstream.quota_score,
                upstream.routing_mode
            );
            stream.write_all(header.as_bytes())?;
            stream.flush()?;
        }

        let latency_ms = start_time.elapsed().as_millis() as u64;
        if output_tokens == 0 {
            output_tokens = (accumulated_text.len() / 4).max(1) as i64;
        }

        if let Ok(mut lock) = self.recent_requests.lock() {
            lock.push_front(GatewayRequestRecord {
                id: format!("req_{}_{}", now_unix, requested_model.replace(' ', "_")),
                time: time_str.into(),
                agent: agent.to_string(),
                ingress_protocol: "OpenAI Chat".into(),
                model_alias: requested_model.into(),
                target_provider: "OpenAI / Codex".into(),
                target_model: target_model.into(),
                latency_ms,
                ttft_ms: latency_ms,
                tokens: output_tokens as usize,
                fidelity: "native".into(),
                status: "200 OK".into(),
            });
        }
        self.telemetry_store.record_event(TelemetryEvent {
            id: format!("req_{}_{}", now_unix, requested_model.replace(' ', "_")),
            timestamp: (now_unix * 1000) as i64,
            agent: agent.to_string(),
            ingress_protocol: "OpenAI Chat".into(),
            provider: "OpenAI / Codex".into(),
            account: account_name.into(),
            model_alias: requested_model.into(),
            target_model: target_model.into(),
            input_tokens: Some(input_tokens),
            output_tokens: Some(output_tokens),
            cache_read_tokens: None,
            cache_write_tokens: None,
            total_tokens: Some(input_tokens + output_tokens),
            latency_ms: latency_ms as i64,
            ttft_ms: latency_ms as i64,
            status_code: 200,
            status: "success".into(),
            error_category: None,
            fidelity: "native".into(),
            is_stream,
            tool_calls_count: 0,
            estimated_cost: None,
            currency: None,
        });
        Ok(ProxyCallResult::Completed)
    }

    pub(crate) fn codex_oauth_access_token(codex_home: &str) -> Result<String, String> {
        let home = std::path::Path::new(codex_home);
        let path = home.join("oauth_token.json");
        let raw = std::fs::read_to_string(&path)
            .map_err(|_| "Codex 账号会话文件不存在；请在 Tomo 中检查登录状态。".to_string())?;
        let token: serde_json::Value = serde_json::from_str(&raw)
            .map_err(|_| "Codex 账号会话文件格式无效。".to_string())?;

        let existing_access = token
            .get("accessToken")
            .and_then(|v| v.as_str())
            .filter(|v| !v.trim().is_empty())
            .map(str::to_string);

        if existing_access.is_some() && Self::codex_access_token_is_fresh(&token) {
            return Ok(existing_access.unwrap());
        }

        if let Ok(new_token) = Self::force_refresh_codex_token(codex_home) {
            return Ok(new_token);
        }

        existing_access.ok_or_else(|| "Codex OAuth access token 不存在；请重新登录".to_string())
    }

    fn codex_access_token_is_fresh(token: &serde_json::Value) -> bool {
        let Some(expires_at) = token.get("expiresAt").and_then(|value| value.as_str()) else {
            return true;
        };
        let Some(expires_unix) = Self::parse_rfc3339_utc(expires_at) else {
            return true;
        };
        let now_unix = Self::current_unix_seconds();
        expires_unix.saturating_sub(now_unix) >= 60
    }

    fn force_refresh_codex_token(codex_home: &str) -> Result<String, String> {
        let home = std::path::Path::new(codex_home);
        let path = home.join("oauth_token.json");
        let raw = std::fs::read_to_string(&path)
            .map_err(|_| "Codex 账号会话文件不存在。".to_string())?;
        let token: serde_json::Value = serde_json::from_str(&raw)
            .map_err(|_| "Codex 账号会话文件格式无效。".to_string())?;
        let refresh_token = token
            .get("refreshToken")
            .and_then(|v| v.as_str())
            .filter(|v| !v.trim().is_empty())
            .ok_or_else(|| "Codex refresh token 不存在".to_string())?;

        let refreshed = Self::refresh_codex_oauth_token(refresh_token)?;
        if let Some(new_access) = refreshed.get("access_token").and_then(|v| v.as_str()) {
            let mut updated = token.clone();
            updated["accessToken"] = serde_json::json!(new_access);
            if let Some(new_refresh) = refreshed.get("refresh_token").and_then(|v| v.as_str()) {
                if !new_refresh.is_empty() {
                    updated["refreshToken"] = serde_json::json!(new_refresh);
                }
            }
            if let Some(new_id) = refreshed.get("id_token").and_then(|v| v.as_str()) {
                updated["idToken"] = serde_json::json!(new_id);
            }
            let expires_in = refreshed
                .get("expires_in")
                .and_then(|v| v.as_u64())
                .unwrap_or(86400);
            let expires_unix = Self::current_unix_seconds() + expires_in as i64;
            updated["expiresAt"] = serde_json::json!(Self::format_rfc3339_utc(expires_unix));
            let _ = Self::persist_codex_oauth_token(&path, &updated);
            return Ok(new_access.to_string());
        }
        Err("OpenAI 未返回新的 access_token".to_string())
    }

    fn refresh_codex_oauth_token(refresh_token: &str) -> Result<serde_json::Value, String> {
        let mut command = std::process::Command::new("curl");
        command
            .arg("-sS")
            .arg("--connect-timeout")
            .arg("10")
            .arg("--max-time")
            .arg("30")
            .arg("-X")
            .arg("POST")
            .arg("https://auth.openai.com/oauth/token")
            .arg("-H")
            .arg("Content-Type: application/x-www-form-urlencoded")
            .arg("--data-urlencode")
            .arg("grant_type=refresh_token")
            .arg("--data-urlencode")
            .arg("client_id=app_EMoamEEZ73f0CkXaXp7hrann")
            .arg("--data-urlencode")
            .arg(format!("refresh_token={refresh_token}"));

        let output = command
            .output()
            .map_err(|error| format!("could not start refresh helper: {error}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("network helper failed: {}", stderr.trim()));
        }
        serde_json::from_slice(&output.stdout)
            .map_err(|_| "OpenAI returned a non-JSON refresh response".to_string())
    }

    fn persist_codex_oauth_token(path: &std::path::Path, token: &serde_json::Value) -> Result<(), String> {
        let encoded = serde_json::to_vec_pretty(token)
            .map_err(|_| "could not encode refreshed OAuth credentials".to_string())?;
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or_default();
        let temporary_path = format!("{}.refreshing-{}-{nonce}", path.display(), std::process::id());
        std::fs::write(&temporary_path, encoded)
            .map_err(|_| "could not save refreshed OAuth credentials".to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&temporary_path, std::fs::Permissions::from_mode(0o600));
        }
        std::fs::rename(&temporary_path, path)
            .map_err(|_| "could not replace refreshed OAuth credentials".to_string())
    }

    fn message_text(content: Option<&serde_json::Value>) -> Option<String> {
        match content? {
            serde_json::Value::String(text) => Some(text.clone()),
            serde_json::Value::Array(parts) => Some(
                parts
                    .iter()
                    .filter_map(|part| {
                        part.get("text")
                            .and_then(|value| value.as_str())
                            .map(str::to_string)
                    })
                    .collect::<Vec<_>>()
                    .join("\n"),
            ),
            _ => None,
        }
    }

    /// Image parts carried by an OpenAI-style multimodal `content` array.
    ///
    /// `message_text` reads only `text` parts, so every structured upstream
    /// adapter used to drop a user's attachment without a word and the model
    /// then answered about an image it never received. Each adapter converts
    /// these URLs into its own protocol's image shape instead.
    fn message_image_urls(content: Option<&serde_json::Value>) -> Vec<String> {
        let Some(serde_json::Value::Array(parts)) = content else {
            return Vec::new();
        };
        parts
            .iter()
            .filter_map(|part| {
                if part.get("type").and_then(|value| value.as_str()) != Some("image_url") {
                    return None;
                }
                let url = part
                    .get("image_url")
                    .and_then(|value| value.get("url"))
                    .and_then(|value| value.as_str())?;
                let trimmed = url.trim();
                if trimmed.is_empty() {
                    None
                } else {
                    Some(trimmed.to_string())
                }
            })
            .collect()
    }

    /// Split an inline `data:<mime>;base64,<payload>` URL, the form clients use
    /// for an attached file. Returns `None` for a remote URL, which has no
    /// inlinable Gemini equivalent.
    fn parse_inline_data_url(url: &str) -> Option<(String, String)> {
        let rest = url.strip_prefix("data:")?;
        let (meta, payload) = rest.split_once(',')?;
        let mime = meta.split(';').next()?.trim();
        if !meta.to_ascii_lowercase().contains("base64") || mime.is_empty() || payload.trim().is_empty()
        {
            return None;
        }
        Some((mime.to_string(), payload.to_string()))
    }

    /// Gemini Cloud Code `inlineData` parts for one message's attachments.
    fn gemini_inline_data_parts(content: Option<&serde_json::Value>) -> Vec<serde_json::Value> {
        Self::message_image_urls(content)
            .iter()
            .filter_map(|url| Self::parse_inline_data_url(url))
            .map(|(mime_type, data)| {
                serde_json::json!({"inlineData": {"mimeType": mime_type, "data": data}})
            })
            .collect()
    }

    /// Responses-API content parts for one user message, images included.
    fn codex_user_content_parts(content: Option<&serde_json::Value>) -> Vec<serde_json::Value> {
        let mut parts = Vec::new();
        if let Some(text) = Self::message_text(content) {
            parts.push(serde_json::json!({"type": "input_text", "text": text}));
        }
        for url in Self::message_image_urls(content) {
            parts.push(serde_json::json!({"type": "input_image", "image_url": url}));
        }
        parts
    }

    fn write_gateway_error(
        stream: &mut TcpStream,
        requested_model: &str,
        is_stream: bool,
        now_unix: u64,
        message: &str,
    ) -> std::io::Result<bool> {
        let message = serde_json::to_string(message).unwrap_or_else(|_| "\"网关调用失败\"".into());
        let model = serde_json::to_string(requested_model).unwrap_or_else(|_| "\"unknown\"".into());
        let response = if is_stream {
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\ndata: {{\"id\":\"resp_error\",\"object\":\"chat.completion.chunk\",\"created\":{now_unix},\"model\":{model},\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":{message}}},\"finish_reason\":null}}]}}\n\ndata: {{\"id\":\"resp_error\",\"object\":\"chat.completion.chunk\",\"created\":{now_unix},\"model\":{model},\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n"
            )
        } else {
            let body =
                format!("{{\"error\":{{\"message\":{message},\"type\":\"upstream_error\"}}}}");
            format!(
                "HTTP/1.1 502 Bad Gateway\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
        };
        stream.write_all(response.as_bytes())?;
        stream.flush()?;
        Ok(true)
    }

    #[allow(dead_code)]
    pub(crate) fn resolve_upstream_endpoint(model: &str) -> Result<UpstreamEndpoint, String> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
        Self::resolve_upstream_endpoint_for_home(&home, model)
    }

    fn resolve_upstream_endpoint_with_exclusions(
        model: &str,
        exclusions: &[String],
    ) -> Result<UpstreamEndpoint, String> {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
        Self::resolve_upstream_endpoint_for_home_with_exclusions(&home, model, exclusions)
    }

    pub(crate) fn resolve_upstream_endpoint_for_home(home: &str, model: &str) -> Result<UpstreamEndpoint, String> {
        Self::resolve_upstream_endpoint_for_home_with_exclusions(home, model, &[])
    }

    fn sort_and_pick_candidate(
        _provider: &str,
        routing_mode: &str,
        candidates: &mut Vec<(i64, String, UpstreamEndpoint)>,
    ) -> Option<UpstreamEndpoint> {
        if candidates.is_empty() {
            return None;
        }
        let dynamic_state = AccountDynamicState::global();
        let state_guard = dynamic_state.lock().ok();

        candidates.sort_by(|a, b| {
            let a_cooling = state_guard.as_ref().map_or(false, |s| s.is_cooling_down(&a.1));
            let b_cooling = state_guard.as_ref().map_or(false, |s| s.is_cooling_down(&b.1));
            a_cooling
                .cmp(&b_cooling)
                .then_with(|| b.0.cmp(&a.0))
                .then_with(|| {
                    if routing_mode == "smooth" {
                        let a_last = state_guard.as_ref().and_then(|s| s.last_served(&a.1));
                        let b_last = state_guard.as_ref().and_then(|s| s.last_served(&b.1));
                        a_last.cmp(&b_last)
                    } else {
                        std::cmp::Ordering::Equal
                    }
                })
                .then_with(|| a.1.cmp(&b.1))
        });

        drop(state_guard);

        let picked = candidates.remove(0).2;
        if let Ok(mut s) = AccountDynamicState::global().lock() {
            s.record_served(&picked.connection_id);
        }
        Some(picked)
    }

    pub(crate) fn resolve_upstream_endpoint_for_home_with_exclusions(
        home: &str,
        model: &str,
        exclusions: &[String],
    ) -> Result<UpstreamEndpoint, String> {
        let app_support = format!("{home}/Library/Application Support/Tomo");
        let settings = GatewaySettings::load_for_home(home);
        let mut lower = model.to_lowercase();

        let mut explicit_provider = None;

        // Hermes custom providers only accept model IDs in their configured
        // allowlist, and render that ID directly in the picker. Codexling
        // publishes aliases shaped as:
        // - `供应商·模型名·账号名` (3 segments, explicit account routing)
        // - `供应商·模型名` (2 segments, consolidated quota pool routing)
        // Convert the human-readable alias back to the routing syntax here.
        let picker_parts: Vec<&str> = lower.split('·').map(str::trim).collect();
        if picker_parts.len() == 3 && picker_parts.iter().all(|part| !part.is_empty()) {
            let provider_label = picker_parts[0];
            if provider_label.starts_with("openai") || provider_label.starts_with("codex") {
                explicit_provider = Some("openai");
                lower = format!("{}@{}", picker_parts[1], picker_parts[2]);
            } else if provider_label.starts_with("google") || provider_label.starts_with("gemini") {
                explicit_provider = Some("google");
                lower = format!("{}@{}", picker_parts[1], picker_parts[2]);
            } else if provider_label.starts_with("deepseek") {
                explicit_provider = Some("deepseek");
                lower = format!("{}@{}", picker_parts[1], picker_parts[2]);
            } else if provider_label.starts_with("opencode") {
                explicit_provider = Some("opencode");
                lower = format!("{}@{}", picker_parts[1], picker_parts[2]);
            }
        } else if picker_parts.len() == 2 && picker_parts.iter().all(|part| !part.is_empty()) {
            let provider_label = picker_parts[0];
            if provider_label.starts_with("openai") || provider_label.starts_with("codex") {
                explicit_provider = Some("openai");
                lower = picker_parts[1].to_string();
            } else if provider_label.starts_with("google") || provider_label.starts_with("gemini") {
                explicit_provider = Some("google");
                lower = picker_parts[1].to_string();
            } else if provider_label.starts_with("deepseek") {
                explicit_provider = Some("deepseek");
                lower = picker_parts[1].to_string();
            } else if provider_label.starts_with("opencode") {
                explicit_provider = Some("opencode");
                lower = picker_parts[1].to_string();
            }
        }

        if explicit_provider.is_none() {
            if lower.starts_with("openai · ")
                || lower.starts_with("openai / codex · ")
                || lower.starts_with("openai/")
                || lower.starts_with("codex/")
            {
                explicit_provider = Some("openai");
            } else if lower.starts_with("google · ")
                || lower.starts_with("google gemini · ")
                || lower.starts_with("google/")
                || lower.starts_with("gemini/")
            {
                explicit_provider = Some("google");
            } else if lower.starts_with("deepseek · ")
                || lower.starts_with("deepseek 官方 · ")
                || lower.starts_with("deepseek/")
            {
                explicit_provider = Some("deepseek");
            } else if lower.starts_with("opencode · ")
                || lower.starts_with("opencode 聚合平台 · ")
                || lower.starts_with("opencode/")
            {
                explicit_provider = Some("opencode");
            }

            for prefix in &[
                "openai · ",
                "openai / codex · ",
                "google · ",
                "google gemini · ",
                "deepseek · ",
                "deepseek 官方 · ",
                "opencode · ",
                "opencode 聚合平台 · ",
                "openai/",
                "codex/",
                "google/",
                "gemini/",
                "deepseek/",
                "opencode/",
            ] {
                if lower.starts_with(prefix) {
                    lower = lower[prefix.len()..].trim().to_string();
                    break;
                }
            }
        }

        // Support multiple account scoping syntax:
        // 1. "gemini-3.7-flash (徐金琦)"
        // 2. "[徐金琦] gemini-3.7-flash"
        // 3. "徐金琦/gemini-3.7-flash"
        let (account_filter, base_model) =
            if let (Some(l_paren), Some(r_paren)) = (lower.find('('), lower.rfind(')')) {
                if l_paren < r_paren {
                    let acc = lower[l_paren + 1..r_paren].trim();
                    let bm = lower[..l_paren].trim();
                    (Some(acc), bm)
                } else {
                    (None, lower.as_str())
                }
            } else if lower.starts_with('[') && lower.contains(']') {
                if let Some(r_bracket) = lower.find(']') {
                    let acc = lower[1..r_bracket].trim();
                    let bm = lower[r_bracket + 1..].trim();
                    (Some(acc), bm)
                } else {
                    (None, lower.as_str())
                }
            } else if let Some(slash_idx) = lower.find('/') {
                (
                    Some(lower[..slash_idx].trim()),
                    lower[slash_idx + 1..].trim(),
                )
            } else if let Some(at_idx) = lower.find('@') {
                (Some(lower[at_idx + 1..].trim()), lower[..at_idx].trim())
            } else if let Some(colon_idx) = lower.find(':') {
                (
                    Some(lower[colon_idx + 1..].trim()),
                    lower[..colon_idx].trim(),
                )
            } else {
                (None, lower.as_str())
            };

        // Extract provider and clean account info from account_filter if present (e.g. `go-opencode`, `x-seven-google`, `seven-x-openai`).
        let (inferred_prov, clean_account_filter, filter_short_id) = match account_filter {
            Some(af) => Self::parse_account_filter(af),
            None => (None, None, None),
        };
        if explicit_provider.is_none() {
            explicit_provider = inferred_prov;
        }

        // When explicit provider is not given, inspect connections-v1.json first
        // to discover which account actually owns this model, rather than guessing by substring.
        if explicit_provider.is_none() {
            let conn_path = format!("{app_support}/connections-v1.json");
            if let Ok(content) = std::fs::read_to_string(&conn_path) {
                if let Ok(registry) = serde_json::from_str::<serde_json::Value>(&content) {
                    let normalized_requested = base_model
                        .trim()
                        .trim_start_matches("models/")
                        .to_ascii_lowercase()
                        .replace('_', "-");

                    let account_matches_and_has_model =
                        |accounts: Option<&Vec<serde_json::Value>>, provider_suffix: &str| -> (bool, bool) {
                            let mut account_found = false;
                            let mut model_found = false;
                            if let Some(accs) = accounts {
                                for acc in accs {
                                    if !acc
                                        .get("isEnabled")
                                        .and_then(|e| e.as_bool())
                                        .unwrap_or(true)
                                    {
                                        continue;
                                    }
                                    let id = Self::connection_id(acc);
                                    let short_id = Self::connection_short_id(acc);
                                    let label = acc.get("label").and_then(|v| v.as_str()).unwrap_or("");
                                    let display = acc
                                        .get("displayName")
                                        .or_else(|| {
                                            acc.get("usage").and_then(|u| u.get("accountName"))
                                        })
                                        .and_then(|v| v.as_str())
                                        .unwrap_or(label);
                                    let email =
                                        acc.get("email").and_then(|v| v.as_str()).unwrap_or("");
                                    let (slug, friendly_name) =
                                        Self::friendly_account_slug(Some(display), Some(email), label);
                                    let scoped_slug = format!("{slug}-{provider_suffix}");
                                    let full_slug = format!("{slug}-{provider_suffix}-{short_id}");
                                    let id_slug = format!("{slug}-{short_id}");
                                    let account_display = format!("{friendly_name} ({provider_suffix} · {short_id})");

                                    let is_acc_match = match account_filter {
                                        Some(filter) => {
                                            if let Some(prov) = explicit_provider {
                                                if prov != provider_suffix {
                                                    continue;
                                                }
                                            }
                                            if let Some(ref sid) = filter_short_id {
                                                sid.eq_ignore_ascii_case(&short_id) || id.to_lowercase().replace('-', "").starts_with(sid)
                                            } else {
                                                Self::gateway_account_filter_matches(
                                                    filter,
                                                    &[display, label, email, &slug, &scoped_slug, &full_slug, &id_slug, &short_id, &id, &account_display],
                                                ) || clean_account_filter.as_deref().map_or(false, |cf| {
                                                    Self::gateway_account_filter_matches(
                                                        cf,
                                                        &[display, label, email, &slug, &id_slug, &short_id],
                                                    )
                                                })
                                            }
                                        }
                                        None => true,
                                    };

                                    if is_acc_match {
                                        account_found = true;
                                        let has_model = acc
                                            .get("availableModelIDs")
                                            .and_then(|m| m.as_array())
                                            .map_or(false, |models| {
                                                models.iter().filter_map(|m| m.as_str()).any(|cand| {
                                                    cand.eq_ignore_ascii_case(base_model)
                                                        || cand
                                                            .strip_suffix("-tiered")
                                                            .map_or(false, |t| {
                                                                t.eq_ignore_ascii_case(base_model)
                                                            })
                                                        || cand
                                                            .trim_start_matches("models/")
                                                            .replace('_', "-")
                                                            .eq_ignore_ascii_case(
                                                                &normalized_requested,
                                                            )
                                                })
                                            });
                                        if has_model {
                                            model_found = true;
                                            break;
                                        }
                                    }
                                }
                            }
                            (account_found, model_found)
                        };

                    let gemini_accs = registry.get("geminiConnections").and_then(|a| a.as_array());
                    let opencode_accs = registry.get("openCodeConnections").and_then(|a| a.as_array());
                    let deepseek_accs = registry.get("deepSeekConnections").and_then(|a| a.as_array());
                    let codex_accs = registry.get("codexAccounts").and_then(|a| a.as_array());

                    let (gemini_acc, gemini_model) =
                        account_matches_and_has_model(gemini_accs, "google");
                    let (opencode_acc, opencode_model) =
                        account_matches_and_has_model(opencode_accs, "opencode");
                    let (deepseek_acc, deepseek_model) =
                        account_matches_and_has_model(deepseek_accs, "deepseek");
                    let (codex_acc, codex_model) =
                        account_matches_and_has_model(codex_accs, "openai");

                    let matched_with_model: Vec<(&str, bool)> = [
                        ("google", gemini_model),
                        ("opencode", opencode_model),
                        ("deepseek", deepseek_model),
                        ("openai", codex_model),
                    ]
                    .iter()
                    .filter_map(|(p, has_m)| if *has_m { Some((*p, true)) } else { None })
                    .collect();

                    if matched_with_model.len() == 1 {
                        explicit_provider = Some(matched_with_model[0].0);
                    } else if matched_with_model.len() > 1 {
                        // Disambiguate by model's native/primary platform ownership:
                        if base_model.contains("gemini") {
                            explicit_provider = Some("google");
                        } else if base_model.starts_with("gpt-") || base_model.starts_with("o1") || base_model.starts_with("o3") || base_model.starts_with("o4") {
                            explicit_provider = Some("openai");
                        } else if base_model.starts_with("deepseek") && deepseek_model {
                            explicit_provider = Some("deepseek");
                        } else if opencode_model {
                            explicit_provider = Some("opencode");
                        } else {
                            explicit_provider = Some(matched_with_model[0].0);
                        }
                    } else if account_filter.is_some() {
                        let matched_providers = [
                            ("google", gemini_acc),
                            ("opencode", opencode_acc),
                            ("deepseek", deepseek_acc),
                            ("openai", codex_acc),
                        ];
                        let active: Vec<&str> = matched_providers
                            .iter()
                            .filter_map(|(p, matched)| if *matched { Some(*p) } else { None })
                            .collect();
                        if active.len() == 1 {
                            explicit_provider = Some(active[0]);
                        }
                    }
                }
            }
        }

        let is_google = match explicit_provider {
            Some(provider) => provider == "google",
            None => base_model.contains("gemini"),
        };
        let is_openai = match explicit_provider {
            Some(provider) => provider == "openai",
            None => {
                base_model.starts_with("gpt-")
                    || base_model.starts_with("o1")
                    || base_model.starts_with("o3")
                    || base_model.starts_with("o4")
            }
        };
        let is_deepseek = match explicit_provider {
            Some(provider) => provider == "deepseek",
            None => base_model.contains("deepseek") && !base_model.contains("opencode"),
        };
        let is_opencode = match explicit_provider {
            Some(provider) => provider == "opencode",
            None => {
                base_model.contains("qwen")
                    || base_model.contains("kimi")
                    || base_model.contains("minimax")
                    || base_model.contains("glm")
                    || base_model.contains("hy3")
                    || base_model.contains("hy4")
                    || base_model.contains("grok")
                    || base_model.contains("claude")
            }
        };

        // 1. Google Gemini 专属通道（严格隔离，只使用已登录账号的 OAuth 凭证）
        if is_google {
            let conn_path = format!("{app_support}/connections-v1.json");
            let mut oauth_failures = Vec::new();
            if let Ok(content) = std::fs::read_to_string(&conn_path) {
                if let Ok(registry) = serde_json::from_str::<serde_json::Value>(&content) {
                    if let Some(accounts) =
                        registry.get("geminiConnections").and_then(|a| a.as_array())
                    {
                        let prov_mode = settings.routing_mode_for_provider("google");
                        let pinned_target = if account_filter.is_none() && prov_mode == "pinnedAccount" {
                            settings.pinned_account_for_provider("google")
                        } else {
                            None
                        };
                        let mut candidates: Vec<(i64, String, UpstreamEndpoint)> = Vec::new();
                        for acc in accounts {
                            if !acc
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                            {
                                continue;
                            }
                            let display_name = acc
                                .get("displayName")
                                .and_then(|d| d.as_str())
                                .unwrap_or("");
                            let email = acc.get("email").and_then(|e| e.as_str()).unwrap_or("");
                            let label = acc.get("label").and_then(|l| l.as_str()).unwrap_or("");
                            let handle = acc
                                .get("credentialHandle")
                                .and_then(|h| h.as_str())
                                .unwrap_or("");

                            let (slug, friendly_name) = Self::friendly_account_slug(
                                Some(display_name),
                                Some(email),
                                label,
                            );
                            let id = Self::connection_id(acc);
                            let short_id = Self::connection_short_id(acc);
                            let scoped_slug = format!("{slug}-google");
                            let full_slug = format!("{slug}-google-{short_id}");
                            let id_slug = format!("{slug}-{short_id}");
                            let account_display = format!("{friendly_name} (Google · {short_id})");

                            let matched = match account_filter {
                                Some(filter) => {
                                    if let Some(ref sid) = filter_short_id {
                                        sid.eq_ignore_ascii_case(&short_id) || id.to_lowercase().replace('-', "").starts_with(sid)
                                    } else {
                                        Self::gateway_account_filter_matches(
                                            filter,
                                            &[display_name, email, label, &slug, &scoped_slug, &full_slug, &id_slug, &short_id, &id, &account_display],
                                        ) || clean_account_filter.as_deref().map_or(false, |cf| {
                                            Self::gateway_account_filter_matches(
                                                cf,
                                                &[display_name, email, label, &slug, &id_slug, &short_id],
                                            )
                                        })
                                    }
                                }
                                None => {
                                    !exclusions.contains(&id)
                                }
                            };

                            if matched {
                                match Self::gemini_oauth_access_token(&app_support, handle) {
                                    Ok(access_token) => {
                                        let requested = base_model.trim().to_lowercase();
                                        let normalized = |value: &str| {
                                            value
                                                .trim()
                                                .trim_start_matches("models/")
                                                .trim_start_matches("MODEL_GOOGLE_")
                                                .trim_start_matches("MODEL_OPENAI_")
                                                .to_lowercase()
                                                .replace('_', "-")
                                        };
                                        let target_model = acc
                                        .get("availableModelIDs")
                                        .and_then(|models| models.as_array())
                                        .and_then(|models| models.iter().filter_map(|model| model.as_str()).find(|candidate| {
                                            candidate.eq_ignore_ascii_case(base_model)
                                                || candidate.strip_suffix("-tiered").map(|alias| alias.eq_ignore_ascii_case(base_model)).unwrap_or(false)
                                                || normalized(candidate) == requested
                                        }))
                                        .map(str::to_owned);

                                        if let Some(target_model) = target_model {
                                            let score = Self::score_gemini_account(acc);
                                            let is_cooling = AccountDynamicState::global()
                                                .lock()
                                                .ok()
                                                .map_or(false, |s| s.is_cooling_down(&id));
                                            let is_pinned_hit = prov_mode == "pinnedAccount"
                                                && pinned_target.map_or(false, |pid| id == pid)
                                                && !is_cooling
                                                && score > 0;

                                            let routing_mode = if is_pinned_hit {
                                                "pinned".to_string()
                                            } else if account_filter.is_none() && (settings.is_provider_consolidated("google") || prov_mode == "pinnedAccount") {
                                                "consolidated".to_string()
                                            } else {
                                                "direct".to_string()
                                            };
                                            let endpoint = UpstreamEndpoint {
                                                url: "https://daily-cloudcode-pa.googleapis.com/v1internal:generateContent".into(),
                                                auth_header: format!("Bearer {access_token}"),
                                                extra_headers: Vec::new(),
                                                project: acc
                                                    .get("projectId")
                                                    .and_then(|project| project.as_str())
                                                    .filter(|project| !project.trim().is_empty())
                                                    .map(str::to_owned),
                                                target_model,
                                                provider_name: "Google Gemini".into(),
                                                _account_name: account_display,
                                                codex_home: None,
                                                connection_id: id.clone(),
                                                quota_score: score,
                                                routing_mode,
                                            };

                                            if is_pinned_hit {
                                                if let Ok(mut s) = AccountDynamicState::global().lock() {
                                                    s.record_served(&endpoint.connection_id);
                                                }
                                                return Ok(endpoint);
                                            } else {
                                                if prov_mode == "pinnedAccount" && pinned_target.map_or(false, |pid| id == pid) {
                                                    GatewaySettings::persist_fallback_to_smooth(home, "google");
                                                }
                                                if account_filter.is_some() || (!settings.is_provider_consolidated("google") && prov_mode != "pinnedAccount") {
                                                    if let Ok(mut s) = AccountDynamicState::global().lock() {
                                                        s.record_served(&endpoint.connection_id);
                                                    }
                                                    return Ok(endpoint);
                                                } else {
                                                    candidates.push((score, id, endpoint));
                                                }
                                            }
                                        }
                                    }
                                    Err(error) => oauth_failures.push(error),
                                }
                            }
                        }

                        let prov_mode = settings.routing_mode_for_provider("google");
                        if let Some(mut picked) = Self::sort_and_pick_candidate("google", prov_mode, &mut candidates) {
                            if prov_mode == "pinnedAccount" {
                                if pinned_target == Some(&picked.connection_id) && picked.quota_score > 0 {
                                    picked.routing_mode = "pinned".to_string();
                                } else {
                                    picked.routing_mode = "consolidated".to_string();
                                    GatewaySettings::persist_fallback_to_smooth(home, "google");
                                }
                            }
                            return Ok(picked);
                        }
                    }
                }
            }
            let account = account_filter.unwrap_or("默认");
            if let Some(error) = oauth_failures.into_iter().next() {
                return Err(format!(
                    "Google Gemini 账号 [{account}] 的 OAuth 凭证暂时不可用：{error}"
                ));
            }
            return Err(format!("Google Gemini 账号 [{account}] 的 OAuth 凭证不可用，请在 Tomo 重新登录该 Google 账号后重试。"));
        }

        // 2. OpenAI / Codex 专属通道 (严格隔离，绝不降级)
        if is_openai {
            let conn_path = format!("{app_support}/connections-v1.json");
            let mut found_session_home: Option<String> = None;
            if let Ok(content) = std::fs::read_to_string(&conn_path) {
                if let Ok(registry) = serde_json::from_str::<serde_json::Value>(&content) {
                    if let Some(accounts) = registry.get("codexAccounts").and_then(|a| a.as_array())
                    {
                        let prov_mode = settings.routing_mode_for_provider("openai");
                        let pinned_target = if account_filter.is_none() && prov_mode == "pinnedAccount" {
                            settings.pinned_account_for_provider("openai")
                        } else {
                            None
                        };
                        let mut candidates: Vec<(i64, String, UpstreamEndpoint)> = Vec::new();
                        for account in accounts {
                            if !account
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                                || account.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let label = account
                                .get("label")
                                .and_then(|v| v.as_str())
                                .unwrap_or("codex");
                            let display = account
                                .get("usage")
                                .and_then(|u| u.get("accountName"))
                                .and_then(|v| v.as_str())
                                .unwrap_or(label);
                            let (slug, friendly_name) = Self::friendly_account_slug(
                                Some(display),
                                None,
                                label,
                            );
                            let id = Self::connection_id(account);
                            let short_id = Self::connection_short_id(account);
                            let scoped_slug = format!("{slug}-openai");
                            let full_slug = format!("{slug}-openai-{short_id}");
                            let id_slug = format!("{slug}-{short_id}");
                            let account_display = format!("{friendly_name} (OpenAI · {short_id})");

                            let matched = match account_filter {
                                Some(filter) => {
                                    if let Some(ref sid) = filter_short_id {
                                        sid.eq_ignore_ascii_case(&short_id) || id.to_lowercase().replace('-', "").starts_with(sid)
                                    } else {
                                        Self::gateway_account_filter_matches(
                                            filter,
                                            &[display, label, &slug, &scoped_slug, &full_slug, &id_slug, &short_id, &id, &account_display],
                                        ) || clean_account_filter.as_deref().map_or(false, |cf| {
                                            Self::gateway_account_filter_matches(
                                                cf,
                                                &[display, label, &slug, &id_slug, &short_id],
                                            )
                                        })
                                    }
                                }
                                None => {
                                    !exclusions.contains(&id)
                                }
                            };
                            if !matched {
                                continue;
                            }
                            let relative_home = account
                                .get("relativeHomeDirectory")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            if relative_home.contains('/') || relative_home.contains("..") {
                                continue;
                            }
                            let codex_home =
                                format!("{app_support}/Runtimes/Codex/{relative_home}");
                            if std::path::Path::new(&codex_home).join("oauth_token.json").is_file() {
                                found_session_home = Some(codex_home.clone());
                                let Some(target_model) =
                                    Self::resolve_codex_model(&codex_home, base_model)
                                else {
                                    continue;
                                };
                                let score = Self::score_codex_account(account);
                                let is_cooling = AccountDynamicState::global()
                                    .lock()
                                    .ok()
                                    .map_or(false, |s| s.is_cooling_down(&id));
                                let is_pinned_hit = prov_mode == "pinnedAccount"
                                    && pinned_target.map_or(false, |pid| id == pid)
                                    && !is_cooling
                                    && score > 0;

                                let routing_mode = if is_pinned_hit {
                                    "pinned".to_string()
                                } else if account_filter.is_none() && (settings.is_provider_consolidated("openai") || prov_mode == "pinnedAccount") {
                                    "consolidated".to_string()
                                } else {
                                    "direct".to_string()
                                };
                                let endpoint = UpstreamEndpoint {
                                    url: String::new(),
                                    auth_header: String::new(),
                                    extra_headers: vec![],
                                    project: None,
                                    target_model,
                                    provider_name: "OpenAI / Codex".into(),
                                    _account_name: account_display,
                                    codex_home: Some(codex_home),
                                    connection_id: id.clone(),
                                    quota_score: score,
                                    routing_mode,
                                };
                                if is_pinned_hit {
                                    if let Ok(mut s) = AccountDynamicState::global().lock() {
                                        s.record_served(&endpoint.connection_id);
                                    }
                                    return Ok(endpoint);
                                } else {
                                    if prov_mode == "pinnedAccount" && pinned_target.map_or(false, |pid| id == pid) {
                                        GatewaySettings::persist_fallback_to_smooth(home, "openai");
                                    }
                                    if account_filter.is_some() || (!settings.is_provider_consolidated("openai") && prov_mode != "pinnedAccount") {
                                        if let Ok(mut s) = AccountDynamicState::global().lock() {
                                            s.record_served(&endpoint.connection_id);
                                        }
                                        return Ok(endpoint);
                                    } else {
                                        candidates.push((score, id, endpoint));
                                    }
                                }
                            }
                        }

                        let prov_mode = settings.routing_mode_for_provider("openai");
                        if let Some(mut picked) = Self::sort_and_pick_candidate("openai", prov_mode, &mut candidates) {
                            if prov_mode == "pinnedAccount" {
                                if pinned_target == Some(&picked.connection_id) && picked.quota_score > 0 {
                                    picked.routing_mode = "pinned".to_string();
                                } else {
                                    picked.routing_mode = "consolidated".to_string();
                                    GatewaySettings::persist_fallback_to_smooth(home, "openai");
                                }
                            }
                            return Ok(picked);
                        }
                    }
                }
            }
            if let Some(codex_home) = found_session_home {
                let available = Self::codex_catalog(&codex_home)
                    .iter()
                    .filter_map(|m| m.get("slug").and_then(|s| s.as_str()))
                    .collect::<Vec<_>>()
                    .join(", ");
                return Err(format!(
                    "OpenAI / Codex 订阅不支持模型 [{}]。该账号仅支持: {}. 请改用列表中的模型。",
                    base_model, available
                ));
            }
            return Err("OpenAI / Codex 会话未就绪，请在 Tomo 中检查登录状态。".into());
        }

        // 3. DeepSeek 官方直连 (严格隔离，仅选 DeepSeek 时调用)
        if is_deepseek {
            let conn_path = format!("{app_support}/connections-v1.json");
            let key_dir = format!("{app_support}/deepseek_credentials");
            let mut matched_account = false;
            let mut found_account_for_filter = false;
            if let Ok(content) = std::fs::read_to_string(&conn_path) {
                if let Ok(registry) = serde_json::from_str::<serde_json::Value>(&content) {
                    if let Some(accounts) = registry
                        .get("deepSeekConnections")
                        .and_then(|a| a.as_array())
                    {
                        let prov_mode = settings.routing_mode_for_provider("deepseek");
                        let pinned_target = if account_filter.is_none() && prov_mode == "pinnedAccount" {
                            settings.pinned_account_for_provider("deepseek")
                        } else {
                            None
                        };
                        let mut candidates: Vec<(i64, String, UpstreamEndpoint)> = Vec::new();
                        for account in accounts {
                            if !account
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                                || account.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let label = account.get("label").and_then(|v| v.as_str()).unwrap_or("");
                            let (slug, friendly_name) = Self::friendly_account_slug(Some(label), None, label);
                            let id = Self::connection_id(account);
                            let short_id = Self::connection_short_id(account);
                            let scoped_slug = format!("{slug}-deepseek");
                            let full_slug = format!("{slug}-deepseek-{short_id}");
                            let id_slug = format!("{slug}-{short_id}");
                            let account_display = format!("{friendly_name} (DeepSeek · {short_id})");

                            let matched = match account_filter {
                                Some(filter) => {
                                    if let Some(ref sid) = filter_short_id {
                                        sid.eq_ignore_ascii_case(&short_id) || id.to_lowercase().replace('-', "").starts_with(sid)
                                    } else {
                                        Self::gateway_account_filter_matches(
                                            filter,
                                            &[label, &slug, &scoped_slug, &full_slug, &id_slug, &short_id, &id, &account_display],
                                        ) || clean_account_filter.as_deref().map_or(false, |cf| {
                                            Self::gateway_account_filter_matches(cf, &[label, &slug, &id_slug, &short_id])
                                        })
                                    }
                                }
                                None => {
                                    !exclusions.contains(&id)
                                }
                            };
                            if matched {
                                matched_account = true;
                                if let (Some(handle), Some(target_model)) = (
                                    account.get("credentialHandle").and_then(|v| v.as_str()),
                                    Self::connection_model_id(account, base_model),
                                ) {
                                    found_account_for_filter = true;
                                    // Find key for handle
                                    let mut found_key = None;
                                    if let Ok(entries) = std::fs::read_dir(&key_dir) {
                                        for entry in entries.flatten() {
                                            let file_name = entry.file_name();
                                            let name = file_name.to_string_lossy();
                                            if name == format!("{handle}.key") || name == format!("{handle}.json") {
                                                if let Ok(c) = std::fs::read_to_string(entry.path()) {
                                                    let k = c.trim().to_string();
                                                    if !k.is_empty() {
                                                        found_key = Some(k);
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    if let Some(key) = found_key {
                                        let score = Self::score_deepseek_account(account);
                                        let is_cooling = AccountDynamicState::global()
                                            .lock()
                                            .ok()
                                            .map_or(false, |s| s.is_cooling_down(&id));
                                        let is_pinned_hit = prov_mode == "pinnedAccount"
                                            && pinned_target.map_or(false, |pid| id == pid)
                                            && !is_cooling
                                            && score > 0;

                                        let routing_mode = if is_pinned_hit {
                                            "pinned".to_string()
                                        } else if account_filter.is_none() && (settings.is_provider_consolidated("deepseek") || prov_mode == "pinnedAccount") {
                                            "consolidated".to_string()
                                        } else {
                                            "direct".to_string()
                                        };
                                        let endpoint = UpstreamEndpoint {
                                            url: "https://api.deepseek.com/chat/completions".into(),
                                            auth_header: format!("Bearer {key}"),
                                            extra_headers: vec![],
                                            project: None,
                                            target_model,
                                            provider_name: "DeepSeek 官方".into(),
                                            _account_name: account_display,
                                            codex_home: None,
                                            connection_id: id.clone(),
                                            quota_score: score,
                                            routing_mode,
                                        };
                                        if is_pinned_hit {
                                            if let Ok(mut s) = AccountDynamicState::global().lock() {
                                                s.record_served(&endpoint.connection_id);
                                            }
                                            return Ok(endpoint);
                                        } else {
                                            if prov_mode == "pinnedAccount" && pinned_target.map_or(false, |pid| id == pid) {
                                                GatewaySettings::persist_fallback_to_smooth(home, "deepseek");
                                            }
                                            if account_filter.is_some() || (!settings.is_provider_consolidated("deepseek") && prov_mode != "pinnedAccount") {
                                                if let Ok(mut s) = AccountDynamicState::global().lock() {
                                                    s.record_served(&endpoint.connection_id);
                                                }
                                                return Ok(endpoint);
                                            } else {
                                                candidates.push((score, id, endpoint));
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        let prov_mode = settings.routing_mode_for_provider("deepseek");
                        if let Some(mut picked) = Self::sort_and_pick_candidate("deepseek", prov_mode, &mut candidates) {
                            if prov_mode == "pinnedAccount" {
                                if pinned_target == Some(&picked.connection_id) && picked.quota_score > 0 {
                                    picked.routing_mode = "pinned".to_string();
                                } else {
                                    picked.routing_mode = "consolidated".to_string();
                                    GatewaySettings::persist_fallback_to_smooth(home, "deepseek");
                                }
                            }
                            return Ok(picked);
                        }
                    }
                }
            }
            if account_filter.is_some() {
                let detail = if found_account_for_filter {
                    "DeepSeek API Key 未配置，已阻止降级以保护余额。".to_string()
                } else if matched_account {
                    format!("DeepSeek 账号 [{}] 不提供模型 [{}]；已阻止回退。", account_filter.unwrap(), base_model)
                } else {
                    format!("DeepSeek 账号 [{}] 未启用或认证未就绪；已阻止回退。", account_filter.unwrap())
                };
                return Err(detail);
            }
            return Err(format!(
                "DeepSeek 当前没有已启用或可用账号提供模型 [{}]；已阻止回退。",
                base_model
            ));
        }

        // 4. OpenCode 聚合平台 (严格隔离)
        if is_opencode {
            let conn_path = format!("{app_support}/connections-v1.json");
            let key_dir = format!("{app_support}/opencode_credentials");
            let mut matched_account = false;
            let mut found_account_for_filter = false;
            if let Ok(content) = std::fs::read_to_string(&conn_path) {
                if let Ok(registry) = serde_json::from_str::<serde_json::Value>(&content) {
                    if let Some(accounts) = registry
                        .get("openCodeConnections")
                        .and_then(|a| a.as_array())
                    {
                        let prov_mode = settings.routing_mode_for_provider("opencode");
                        let pinned_target = if account_filter.is_none() && prov_mode == "pinnedAccount" {
                            settings.pinned_account_for_provider("opencode")
                        } else {
                            None
                        };
                        let mut candidates: Vec<(i64, String, UpstreamEndpoint)> = Vec::new();
                        for account in accounts {
                            if !account
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                                || account.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let label = account.get("label").and_then(|v| v.as_str()).unwrap_or("");
                            let (slug, friendly_name) = Self::friendly_account_slug(Some(label), None, label);
                            let id = Self::connection_id(account);
                            let short_id = Self::connection_short_id(account);
                            let scoped_slug = format!("{slug}-opencode");
                            let full_slug = format!("{slug}-opencode-{short_id}");
                            let id_slug = format!("{slug}-{short_id}");
                            let account_display = format!("{friendly_name} (OpenCode · {short_id})");

                            let matched = match account_filter {
                                Some(filter) => {
                                    if let Some(ref sid) = filter_short_id {
                                        sid.eq_ignore_ascii_case(&short_id) || id.to_lowercase().replace('-', "").starts_with(sid)
                                    } else {
                                        Self::gateway_account_filter_matches(
                                            filter,
                                            &[label, &slug, &scoped_slug, &full_slug, &id_slug, &short_id, &id, &account_display],
                                        ) || clean_account_filter.as_deref().map_or(false, |cf| {
                                            Self::gateway_account_filter_matches(cf, &[label, &slug, &id_slug, &short_id])
                                        })
                                    }
                                }
                                None => {
                                    !exclusions.contains(&id)
                                }
                            };
                            if matched {
                                matched_account = true;
                                if let (Some(handle), Some(target_model)) = (
                                    account.get("credentialHandle").and_then(|v| v.as_str()),
                                    Self::connection_model_id(account, base_model),
                                ) {
                                    found_account_for_filter = true;
                                    let plan = account
                                        .get("plan")
                                        .and_then(|p| p.as_str())
                                        .unwrap_or("go")
                                        .to_string();

                                    let mut found_key = None;
                                    if let Ok(entries) = std::fs::read_dir(&key_dir) {
                                        for entry in entries.flatten() {
                                            let file_name = entry.file_name();
                                            let name = file_name.to_string_lossy();
                                            if name == format!("{handle}.key") || name == format!("{handle}.json") {
                                                if let Ok(c) = std::fs::read_to_string(entry.path()) {
                                                    let k = c.trim().to_string();
                                                    if !k.is_empty() {
                                                        found_key = Some(k);
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    if let Some(key) = found_key {
                                        let url = if plan.eq_ignore_ascii_case("zen") {
                                            "https://opencode.ai/zen/v1/chat/completions".into()
                                        } else {
                                            "https://opencode.ai/zen/go/v1/chat/completions".into()
                                        };
                                        let mut extra_headers = Vec::new();
                                        if !plan.eq_ignore_ascii_case("zen") {
                                            let session_id = if !short_id.is_empty() && short_id != "default" {
                                                short_id.clone()
                                            } else {
                                                let clean_id = id.replace('-', "").to_lowercase();
                                                if clean_id.len() >= 8 {
                                                    clean_id[..8].to_string()
                                                } else {
                                                    "tomo-session".to_string()
                                                }
                                            };
                                            extra_headers.push(("x-opencode-session".to_string(), session_id));
                                        }
                                        let score = Self::score_opencode_account(account);
                                        let is_cooling = AccountDynamicState::global()
                                            .lock()
                                            .ok()
                                            .map_or(false, |s| s.is_cooling_down(&id));
                                        let is_pinned_hit = prov_mode == "pinnedAccount"
                                            && pinned_target.map_or(false, |pid| id == pid)
                                            && !is_cooling
                                            && score > 0;

                                        let routing_mode = if is_pinned_hit {
                                            "pinned".to_string()
                                        } else if account_filter.is_none() && (settings.is_provider_consolidated("opencode") || prov_mode == "pinnedAccount") {
                                            "consolidated".to_string()
                                        } else {
                                            "direct".to_string()
                                        };
                                        let endpoint = UpstreamEndpoint {
                                            url,
                                            auth_header: format!("Bearer {key}"),
                                            extra_headers,
                                            project: None,
                                            target_model,
                                            provider_name: "OpenCode 聚合平台".into(),
                                            _account_name: account_display,
                                            codex_home: None,
                                            connection_id: id.clone(),
                                            quota_score: score,
                                            routing_mode,
                                        };
                                        if is_pinned_hit {
                                            if let Ok(mut s) = AccountDynamicState::global().lock() {
                                                s.record_served(&endpoint.connection_id);
                                            }
                                            return Ok(endpoint);
                                        } else {
                                            if prov_mode == "pinnedAccount" && pinned_target.map_or(false, |pid| id == pid) {
                                                GatewaySettings::persist_fallback_to_smooth(home, "opencode");
                                            }
                                            if account_filter.is_some() || (!settings.is_provider_consolidated("opencode") && prov_mode != "pinnedAccount") {
                                                if let Ok(mut s) = AccountDynamicState::global().lock() {
                                                    s.record_served(&endpoint.connection_id);
                                                }
                                                return Ok(endpoint);
                                            } else {
                                                candidates.push((score, id, endpoint));
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        let prov_mode = settings.routing_mode_for_provider("opencode");
                        if let Some(mut picked) = Self::sort_and_pick_candidate("opencode", prov_mode, &mut candidates) {
                            if prov_mode == "pinnedAccount" {
                                if pinned_target == Some(&picked.connection_id) && picked.quota_score > 0 {
                                    picked.routing_mode = "pinned".to_string();
                                } else {
                                    picked.routing_mode = "consolidated".to_string();
                                    GatewaySettings::persist_fallback_to_smooth(home, "opencode");
                                }
                            }
                            return Ok(picked);
                        }
                    }
                }
            }
            if account_filter.is_some() {
                let detail = if found_account_for_filter {
                    "OpenCode API Key 未配置。".to_string()
                } else if matched_account {
                    format!("OpenCode 账号 [{}] 不提供模型 [{}]；已阻止回退。", account_filter.unwrap(), base_model)
                } else {
                    format!("OpenCode 账号 [{}] 未启用或认证未就绪；已阻止回退。", account_filter.unwrap())
                };
                return Err(detail);
            }
            return Err(format!(
                "OpenCode 当前没有已启用或可用账号提供模型 [{}]；已阻止回退。",
                base_model
            ));
        }

        Err(format!(
            "无法识别该模型的目标供应商 [{}]，已阻止跨供应商降级以保护余额。",
            model
        ))
    }

    /// The upstream model ID comes solely from the account's discovered
    /// catalog. Display
    /// aliases never become upstream IDs by string rewriting: this preserves
    /// model spelling, provider ownership, and account eligibility exactly as
    /// they were advertised by the corresponding service.
    fn connection_model_id(account: &serde_json::Value, requested_model: &str) -> Option<String> {
        let normalize = |value: &str| {
            value
                .trim()
                .trim_start_matches("models/")
                .to_ascii_lowercase()
                .replace('_', "-")
        };
        let requested = normalize(requested_model);
        if requested.is_empty() {
            return None;
        }

        account
            .get("availableModelIDs")
            .and_then(|models| models.as_array())
            .into_iter()
            .flatten()
            .filter_map(|model| model.as_str())
            .find(|model| {
                model.eq_ignore_ascii_case(requested_model)
                    || model
                        .strip_suffix("-tiered")
                        .map_or(false, |t| t.eq_ignore_ascii_case(requested_model))
                    || normalize(model) == requested
            })
            .map(str::to_string)
    }

    /// The codex CLI validates `--model` against its own catalog
    /// (`models_cache.json`), not against the model list that chatgpt.com's
    /// `backend-api/models` returns. For a ChatGPT-subscription account those
    /// two lists are disjoint, so a model in `availableModelIDs` can never be
    /// routed through `codex exec` without a 400 (e.g. `gpt-5-6-t-mini`).
    ///
    /// This returns the user-selectable model slugs the CLI can actually
    /// serve, keeping hidden/internal entries (`gpt-reserve`, `codex-auto-review`)
    /// out. Rather than maintaining a (staleable) allowlist, the source of truth
    /// is the codex CLI itself: `codex debug models` renders the CLI's own
    /// catalog and transparently re-fetches it whenever the on-disk cache is
    /// stale, so newly released models are picked up automatically. Results are
    /// cached in-process for a short TTL so the hot routing path does not spawn
    /// the CLI on every request.
    fn codex_catalog(codex_home: &str) -> Vec<serde_json::Value> {
        const TTL: Duration = Duration::from_secs(120);
        let cache = CODEX_CATALOG_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
        if let Ok(guard) = cache.lock() {
            if let Some(entry) = guard.get(codex_home) {
                if entry.fetched.elapsed() < TTL {
                    return entry.catalog.clone();
                }
            }
        }
        let catalog = Self::fetch_codex_catalog(codex_home);
        if let Ok(mut guard) = cache.lock() {
            guard.insert(
                codex_home.to_string(),
                CodexCatalogEntry {
                    fetched: Instant::now(),
                    catalog: catalog.clone(),
                },
            );
        }
        catalog
    }

    /// Sources the OpenAI Codex model catalog directly from the API.
    /// In non-test builds, it requests `https://chatgpt.com/backend-api/codex/models` using the
    /// OAuth access token, caching the result to `models_cache.json`.
    /// In test builds or if the network request fails, it falls back to reading `models_cache.json`.
    fn fetch_codex_catalog(codex_home: &str) -> Vec<serde_json::Value> {
        let path = std::path::Path::new(codex_home).join("models_cache.json");
        if !cfg!(test) {
            if let Ok(access_token) = Self::codex_oauth_access_token(codex_home) {
                let output = std::process::Command::new("curl")
                    .arg("-sS")
                    .arg("--connect-timeout")
                    .arg("5")
                    .arg("--max-time")
                    .arg("10")
                    .arg("https://chatgpt.com/backend-api/codex/models?client_version=0.153.4")
                    .arg("-H")
                    .arg(format!("Authorization: Bearer {}", access_token))
                    .arg("-H")
                    .arg("User-Agent: codex_cli_rs/0.153.4 (Macos; arm64) codex_exec")
                    .stdin(std::process::Stdio::null())
                    .output();
                if let Ok(output) = output {
                    if output.status.success() {
                        if let Ok(json) = serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                            let catalog = Self::parse_visible_codex_models(&json);
                            if !catalog.is_empty() {
                                let _ = std::fs::write(&path, &output.stdout);
                                return catalog;
                            }
                        }
                    }
                }
            }
        }
        if let Ok(raw) = std::fs::read_to_string(&path) {
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(&raw) {
                let catalog = Self::parse_visible_codex_models(&json);
                if !catalog.is_empty() {
                    return catalog;
                }
            }
        }
        Vec::new()
    }

    /// Filters a codex model catalog JSON (either `codex debug models` output or
    /// the on-disk `models_cache.json`) down to the user-selectable entries the
    /// CLI can actually serve, dropping hidden/internal slugs.
    fn parse_visible_codex_models(json: &serde_json::Value) -> Vec<serde_json::Value> {
        let mut catalog = Vec::new();
        if let Some(models) = json.get("models").and_then(|m| m.as_array()) {
            for model in models {
                let Some(slug) = model.get("slug").and_then(|s| s.as_str()) else {
                    continue;
                };
                if slug.trim().is_empty() || slug == "codex-auto-review" {
                    continue;
                }
                // `gpt-reserve` and other internal entries are hidden from the
                // picker, so only `list` visibility models are servable.
                if model.get("visibility").and_then(|v| v.as_str()) == Some("hide") {
                    continue;
                }
                let display = model
                    .get("display_name")
                    .and_then(|d| d.as_str())
                    .unwrap_or(slug);
                catalog.push(serde_json::json!({
                    "slug": slug,
                    "display_name": display,
                }));
            }
        }
        catalog
    }

    /// Resolve a requested model to a slug the codex CLI can actually serve.
    /// The ChatGPT API's `-wm` suffix is dropped by the CLI (e.g.
    /// `gpt-5.6-sol-wm` -> `gpt-5.6-sol`). Returns `None` when there is no
    /// servable match, so the caller can reject clearly instead of letting the
    /// CLI emit a confusing English 400.
    fn resolve_codex_model(codex_home: &str, requested_model: &str) -> Option<String> {
        let requested = requested_model.trim();
        if requested.is_empty() {
            return None;
        }
        let accepted = Self::codex_catalog(codex_home);
        let find = |candidate: &str| -> Option<String> {
            accepted
                .iter()
                .find(|m| {
                    let slug = m.get("slug").and_then(|s| s.as_str()).unwrap_or("");
                    slug.eq_ignore_ascii_case(candidate)
                })
                .and_then(|m| m.get("slug").and_then(|s| s.as_str()).map(str::to_string))
        };
        find(requested)
            .or_else(|| {
                requested
                    .strip_suffix("-wm")
                    .map(str::trim)
                    .and_then(find)
            })
            // Fallback: If not found in cached catalog, do not hardcode a rejection!
            // Allow newly released models (e.g. `gpt-6-astra`) or custom models to pass through
            // directly to `codex exec`, stripping ChatGPT web `-wm` suffix if present.
            .or_else(|| {
                let stripped = requested.strip_suffix("-wm").map(str::trim).unwrap_or(requested);
                if !stripped.is_empty() {
                    Some(stripped.to_string())
                } else {
                    Some(requested.to_string())
                }
            })
    }

    /// Loads the user-owned Gemini OAuth session and refreshes it when a
    /// refresh token exists. A successful refresh is atomically persisted so
    /// the next routed request does not need to refresh again.
    pub(crate) fn gemini_oauth_access_token(app_support: &str, handle: &str) -> Result<String, String> {
        if handle.trim().is_empty() {
            return Err("Google OAuth credential handle is missing".into());
        }
        let path = format!("{app_support}/gemini_oauth/{handle}.json");
        let raw = std::fs::read_to_string(&path)
            .map_err(|_| "Google OAuth token is missing; sign in again".to_string())?;
        let mut token: serde_json::Value = serde_json::from_str(&raw)
            .map_err(|_| "Google OAuth token file is invalid; sign in again".to_string())?;
        let existing_access = token
            .get("accessToken")
            .and_then(|value| value.as_str())
            .filter(|value| !value.trim().is_empty())
            .map(str::to_owned);
        // Do not refresh a still-valid access token for every routed request.
        // Some user-owned legacy OAuth clients require a secret only during
        // refresh.  The native App can continue using its valid access token,
        // and the Gateway must do the same until it is actually near expiry.
        if existing_access.is_some() && Self::gemini_access_token_is_fresh(&token) {
            return Ok(existing_access.expect("checked is_some"));
        }
        let refresh_token = token
            .get("refreshToken")
            .and_then(|value| value.as_str())
            .filter(|value| !value.trim().is_empty());

        let Some(refresh_token) = refresh_token else {
            return existing_access
                .ok_or_else(|| "Google OAuth access token is missing; sign in again".into());
        };
        let client_id = token
            .get("clientID")
            .and_then(|value| value.as_str())
            .map(str::to_owned)
            .or_else(|| std::env::var("CODEXLING_GEMINI_OAUTH_CLIENT_ID").ok())
            .filter(|value| !value.trim().is_empty());
        let Some(client_id) = client_id else {
            return existing_access.ok_or_else(|| {
                "Gemini OAuth client configuration is missing; restart Tomo".into()
            });
        };

        let refreshed = Self::refresh_gemini_oauth_token(&client_id, refresh_token)?;
        let refreshed_access = refreshed
            .get("access_token")
            .and_then(|value| value.as_str())
            .filter(|value| !value.trim().is_empty())
            .map(str::to_owned);

        let Some(refreshed_access) = refreshed_access else {
            let provider_error = refreshed
                .get("error")
                .and_then(|value| value.as_str())
                .unwrap_or("unknown_error");
            let provider_description = refreshed
                .get("error_description")
                .and_then(|value| value.as_str())
                .unwrap_or("Google did not return a usable access token");
            if let Some(access_token) =
                existing_access.filter(|_| Self::gemini_access_token_is_unexpired(&token))
            {
                return Ok(access_token);
            }
            return Err(format!("Google OAuth refresh was rejected ({provider_error}): {provider_description}. Please sign in again."));
        };

        let expires_in = refreshed
            .get("expires_in")
            .and_then(|value| value.as_i64())
            .unwrap_or(3_600)
            .clamp(60, 86_400);
        let now_unix = Self::current_unix_seconds();
        token["accessToken"] = serde_json::Value::String(refreshed_access.clone());
        token["expiresAt"] = serde_json::Value::String(Self::format_rfc3339_utc(
            now_unix.saturating_add(expires_in),
        ));
        if let Some(new_refresh_token) = refreshed
            .get("refresh_token")
            .and_then(|value| value.as_str())
            .filter(|value| !value.trim().is_empty())
        {
            token["refreshToken"] = serde_json::Value::String(new_refresh_token.to_string());
        }
        Self::persist_gemini_oauth_token(&path, &token)?;
        Ok(refreshed_access)
    }

    /// Refresh through the configured network route first. If a stale local
    /// proxy prevents curl from connecting, retry once without proxy settings;
    /// this keeps an OAuth renewal from requiring the user to re-authorize.
    fn refresh_gemini_oauth_token(
        client_id: &str,
        refresh_token: &str,
    ) -> Result<serde_json::Value, String> {
        let via_environment = Self::run_gemini_oauth_refresh(client_id, refresh_token, false);
        match via_environment {
            Ok(value) => Ok(value),
            Err(environment_error) => Self::run_gemini_oauth_refresh(client_id, refresh_token, true)
                .map_err(|direct_error| format!(
                    "OAuth refresh could not reach Google (configured network route: {environment_error}; direct route: {direct_error})"
                )),
        }
    }

    fn run_gemini_oauth_refresh(
        client_id: &str,
        refresh_token: &str,
        bypass_proxy: bool,
    ) -> Result<serde_json::Value, String> {
        let mut command = std::process::Command::new("curl");
        command
            .arg("-sS")
            .arg("--connect-timeout")
            .arg("5")
            .arg("--max-time")
            .arg("20")
            .arg("-X")
            .arg("POST")
            .arg("https://oauth2.googleapis.com/token")
            .arg("--data-urlencode")
            .arg("grant_type=refresh_token")
            .arg("--data-urlencode")
            .arg(format!("client_id={client_id}"))
            .arg("--data-urlencode")
            .arg(format!("refresh_token={refresh_token}"));
        if bypass_proxy {
            command.arg("--noproxy").arg("*");
        } else if let Some(proxy) = Self::gemini_proxy_override() {
            command.arg("--proxy").arg(proxy);
        }
        let output = command
            .output()
            .map_err(|error| format!("could not start refresh helper: {error}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("network helper failed: {}", stderr.trim()));
        }
        serde_json::from_slice(&output.stdout)
            .map_err(|_| "Google returned a non-JSON refresh response".to_string())
    }

    fn persist_gemini_oauth_token(path: &str, token: &serde_json::Value) -> Result<(), String> {
        let encoded = serde_json::to_vec(token)
            .map_err(|_| "could not encode refreshed OAuth credentials".to_string())?;
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or_default();
        let temporary_path = format!("{path}.refreshing-{}-{nonce}", std::process::id());
        std::fs::write(&temporary_path, encoded)
            .map_err(|_| "could not save refreshed OAuth credentials".to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&temporary_path, std::fs::Permissions::from_mode(0o600))
                .map_err(|_| "could not secure refreshed OAuth credentials".to_string())?;
        }
        std::fs::rename(&temporary_path, path)
            .map_err(|_| "could not replace refreshed OAuth credentials".to_string())
    }

    fn gemini_access_token_is_fresh(token: &serde_json::Value) -> bool {
        let Some(expires_at) = token.get("expiresAt").and_then(|value| value.as_str()) else {
            return false;
        };
        let Some(expires_unix) = Self::parse_rfc3339_utc(expires_at) else {
            return false;
        };
        let now_unix = Self::current_unix_seconds();
        // Match the App's 60-second safety window.
        expires_unix.saturating_sub(now_unix) >= 60
    }

    fn gemini_access_token_is_unexpired(token: &serde_json::Value) -> bool {
        Self::parse_rfc3339_utc(
            token
                .get("expiresAt")
                .and_then(|value| value.as_str())
                .unwrap_or(""),
        )
        .is_some_and(|expires_unix| expires_unix >= Self::current_unix_seconds())
    }

    fn current_unix_seconds() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs() as i64)
            .unwrap_or(i64::MAX)
    }

    /// Formats the RFC3339 subset written by Swift's ISO8601 encoder without
    /// introducing a date-time dependency into the Gateway binary.
    fn format_rfc3339_utc(unix_seconds: i64) -> String {
        let days = unix_seconds.div_euclid(86_400);
        let seconds_of_day = unix_seconds.rem_euclid(86_400);
        let z = days + 719_468;
        let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
        let doe = z - era * 146_097;
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
        let mut year = yoe + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = doy - (153 * mp + 2) / 5 + 1;
        let month = mp + if mp < 10 { 3 } else { -9 };
        year += i64::from(month <= 2);
        let hour = seconds_of_day / 3_600;
        let minute = (seconds_of_day % 3_600) / 60;
        let second = seconds_of_day % 60;
        format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
    }

    /// Minimal RFC3339 UTC parser for Swift's persisted ISO-8601 `expiresAt`.
    /// It accepts both `YYYY-MM-DDTHH:MM:SSZ` and fractional-second variants.
    fn parse_rfc3339_utc(value: &str) -> Option<i64> {
        let core = value.strip_suffix('Z')?.split('.').next()?;
        let bytes = core.as_bytes();
        if bytes.len() != 19
            || bytes[4] != b'-'
            || bytes[7] != b'-'
            || bytes[10] != b'T'
            || bytes[13] != b':'
            || bytes[16] != b':'
        {
            return None;
        }
        let number = |range: std::ops::Range<usize>| {
            std::str::from_utf8(&bytes[range]).ok()?.parse::<i64>().ok()
        };
        let (year, month, day, hour, minute, second) = (
            number(0..4)?,
            number(5..7)?,
            number(8..10)?,
            number(11..13)?,
            number(14..16)?,
            number(17..19)?,
        );
        if !(1..=12).contains(&month)
            || !(1..=31).contains(&day)
            || hour > 23
            || minute > 59
            || second > 60
        {
            return None;
        }
        // Howard Hinnant's civil-date conversion, days since Unix epoch.
        let adjusted_year = year - i64::from(month <= 2);
        let era = if adjusted_year >= 0 {
            adjusted_year
        } else {
            adjusted_year - 399
        } / 400;
        let yoe = adjusted_year - era * 400;
        let shifted_month = month + if month > 2 { -3 } else { 9 };
        let doy = (153 * shifted_month + 2) / 5 + day - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        let days = era * 146_097 + doe - 719_468;
        Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
    }

    fn has_gemini_oauth_token_for_home(home: &str, handle: &str) -> bool {
        if handle.trim().is_empty() {
            return false;
        }
        let path =
            format!("{home}/Library/Application Support/Tomo/gemini_oauth/{handle}.json");
        std::fs::read_to_string(path)
            .ok()
            .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
            .and_then(|token| {
                token
                    .get("accessToken")
                    .and_then(|value| value.as_str())
                    .map(str::to_owned)
            })
            .is_some_and(|token| !token.trim().is_empty())
    }

    /// Scoped Gateway ids use a URL-safe account slug (for example
    /// `xujinqixujinqi-gmail-com`), while the registry keeps the original
    /// email address.  Match both representations without treating dashes,
    /// dots or `@` as meaningful separators.
    fn gateway_account_filter_matches(filter: &str, candidates: &[&str]) -> bool {
        let normalize = |value: &str| {
            let mut normalized = String::new();
            for character in value.chars() {
                if character.is_alphanumeric() {
                    // Account labels are user-controlled and may contain
                    // non-ASCII letters. ASCII lowercasing leaves `Ø`
                    // untouched, so `qintelli-zø` could not find
                    // `Qintelli ZØ` even though it was the same account.
                    normalized.extend(character.to_lowercase());
                } else {
                    normalized.push(' ');
                }
            }
            normalized
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
        };
        let normalized_filter = normalize(filter);
        if normalized_filter.is_empty() {
            return false;
        }
        let compact_filter = normalized_filter.replace(' ', "");
        candidates.iter().any(|candidate| {
            let normalized_candidate = normalize(candidate);
            if normalized_candidate.is_empty() {
                return false;
            }
            let compact_candidate = normalized_candidate.replace(' ', "");
            normalized_candidate.contains(&normalized_filter)
                || normalized_filter.contains(&normalized_candidate)
                || compact_candidate == compact_filter
        })
    }

    pub(crate) fn friendly_account_slug(
        display_name: Option<&str>,
        _email: Option<&str>,
        label: &str,
    ) -> (String, String) {
        let raw_name = if let Some(d) = display_name {
            let trimmed = d.trim();
            if !trimmed.is_empty() && !trimmed.contains('@') {
                trimmed.to_string()
            } else {
                label.trim().to_string()
            }
        } else {
            label.trim().to_string()
        };

        let clean_name = if raw_name.contains('@') {
            raw_name.split('@').next().unwrap_or(&raw_name).to_string()
        } else {
            raw_name
        };

        // Title Case words in slug for consistent UI display (e.g. Seven-X, X-Seven, DeepSeek)
        let parts: Vec<String> = clean_name
            .split(|c: char| c.is_whitespace() || c == '-' || c == '_' || c == '.')
            .filter(|s| !s.is_empty())
            .map(|s| {
                if s.eq_ignore_ascii_case("deepseek") {
                    "DeepSeek".to_string()
                } else if s.eq_ignore_ascii_case("opencode") {
                    "OpenCode".to_string()
                } else if s.len() <= 3 && s.chars().all(|c| c.is_ascii_alphabetic()) {
                    s.to_uppercase()
                } else {
                    let mut c = s.chars();
                    match c.next() {
                        None => String::new(),
                        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                    }
                }
            })
            .collect();

        let slug = if parts.is_empty() {
            clean_name.clone()
        } else {
            parts.join("-")
        };

        (slug, clean_name)
    }

    pub(crate) fn connection_id(acc: &serde_json::Value) -> String {
        if let Some(id_obj) = acc.get("id").and_then(|v| v.get("rawValue")).and_then(|s| s.as_str()) {
            id_obj.to_string()
        } else if let Some(id_str) = acc.get("id").and_then(|s| s.as_str()) {
            id_str.to_string()
        } else if let Some(handle) = acc.get("credentialHandle").and_then(|s| s.as_str()) {
            handle.to_string()
        } else {
            String::new()
        }
    }

    pub(crate) fn connection_short_id(acc: &serde_json::Value) -> String {
        let raw = Self::connection_id(acc);
        let clean = raw.replace('-', "").to_lowercase();
        if clean.len() >= 8 {
            clean[..8].to_string()
        } else if !clean.is_empty() {
            clean
        } else {
            "default".to_string()
        }
    }

    fn parse_account_filter(
        filter: &str,
    ) -> (Option<&'static str>, Option<String>, Option<String>) {
        let lower = filter.trim().to_lowercase();
        let mut explicit_provider = None;
        if lower.contains("opencode") {
            explicit_provider = Some("opencode");
        } else if lower.contains("google") || lower.contains("gemini") {
            explicit_provider = Some("google");
        } else if lower.contains("deepseek") {
            explicit_provider = Some("deepseek");
        } else if lower.contains("openai") || lower.contains("codex") {
            explicit_provider = Some("openai");
        }

        let parts: Vec<&str> = lower.split('-').collect();
        let mut short_id = None;
        if !parts.is_empty() {
            let last = parts.last().unwrap();
            if last.len() == 8 && last.chars().all(|c| c.is_ascii_hexdigit()) {
                short_id = Some(last.to_string());
            }
        }

        let mut clean = lower.clone();
        for p in &[
            "-opencode", "_opencode", "opencode-", "opencode_",
            "-google", "_google", "google-", "google_",
            "-gemini", "_gemini", "gemini-", "gemini_",
            "-deepseek", "_deepseek", "deepseek-", "deepseek_",
            "-openai", "_openai", "openai-", "openai_",
            "-codex", "_codex", "codex-", "codex_",
        ] {
            clean = clean.replace(p, "");
        }
        if let Some(ref sid) = short_id {
            clean = clean.replace(&format!("-{sid}"), "").replace(&format!("_{sid}"), "");
            if clean == *sid {
                clean.clear();
            }
        }
        let clean_opt = if clean.trim().is_empty() {
            None
        } else {
            Some(clean.trim().to_string())
        };

        (explicit_provider, clean_opt, short_id)
    }

    /// `/v1/models` IDs are protocol values, not display labels. Keep them
    /// whitespace-free so clients such as Hermes can switch to them, while
    /// `name`/`display_name` retain the friendly provider and account copy.
    fn scoped_model_id(provider: &str, model: &str, account_slug: &str) -> String {
        format!("{provider}/{model}@{account_slug}")
    }

    /// Cloud Code uses a routing suffix for tiered models. Keep it in the
    /// protocol ID, but show every Gemini generation with a consistent
    /// product name so future catalog additions need no source change.
    fn google_model_display_name(model: &str) -> String {
        let concise = model.trim_end_matches("-tiered");
        concise
            .split('-')
            .map(|part| {
                if part.chars().next().is_some_and(|character| character.is_ascii_digit()) {
                    part.to_string()
                } else {
                    let mut letters = part.chars();
                    match letters.next() {
                        Some(first) => first.to_uppercase().collect::<String>() + letters.as_str(),
                        None => String::new(),
                    }
                }
            })
            .collect::<Vec<_>>()
            .join(" ")
    }

    fn get_dynamic_models_payload() -> serde_json::Value {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
        Self::get_dynamic_models_payload_for_home(&home)
    }

    pub(crate) fn score_codex_account(acc: &serde_json::Value) -> i64 {
        let usage = match acc.get("usage") {
            Some(u) => u,
            None => return 100,
        };
        if let Some(sw) = usage.get("shortWindow") {
            let remaining = sw.get("remaining").and_then(|v| v.as_f64()).unwrap_or(100.0);
            let total = sw.get("total").and_then(|v| v.as_f64()).unwrap_or(100.0);
            if remaining <= 0.0 {
                return 0;
            }
            if total > 0.0 {
                return ((remaining / total) * 100.0).round().clamp(0.0, 100.0) as i64;
            }
            return remaining.round().clamp(0.0, 100.0) as i64;
        }
        if let Some(pw) = usage.get("primary") {
            let remaining = pw.get("remaining").and_then(|v| v.as_f64()).unwrap_or(100.0);
            let total = pw.get("total").and_then(|v| v.as_f64()).unwrap_or(100.0);
            if remaining <= 0.0 {
                return 0;
            }
            if total > 0.0 {
                return ((remaining / total) * 100.0).round().clamp(0.0, 100.0) as i64;
            }
            return remaining.round().clamp(0.0, 100.0) as i64;
        }
        if let Some(sec) = usage.get("secondary") {
            let remaining = sec.get("remaining").and_then(|v| v.as_f64()).unwrap_or(100.0);
            let total = sec.get("total").and_then(|v| v.as_f64()).unwrap_or(100.0);
            if remaining <= 0.0 {
                return 0;
            }
            if total > 0.0 {
                return ((remaining / total) * 100.0).round().clamp(0.0, 100.0) as i64;
            }
            return remaining.round().clamp(0.0, 100.0) as i64;
        }
        100
    }

    pub(crate) fn score_gemini_account(acc: &serde_json::Value) -> i64 {
        if let Some(cooldown_str) = acc.get("cooldownResetsAt").and_then(|c| c.as_str()) {
            if let Some(cooldown_sec) = Self::parse_rfc3339_utc(cooldown_str) {
                let now_sec = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);
                if cooldown_sec > now_sec {
                    return 0;
                }
            }
        }
        let five_hour = acc
            .get("geminiFiveHourRemaining")
            .and_then(|f| f.as_f64())
            .unwrap_or(1.0);
        let weekly = acc
            .get("geminiWeeklyRemaining")
            .and_then(|w| w.as_f64())
            .unwrap_or(1.0);
        let remaining = five_hour.min(weekly);
        (remaining * 100.0).round().clamp(0.0, 100.0) as i64
    }

    pub(crate) fn score_deepseek_account(acc: &serde_json::Value) -> i64 {
        let balance = acc
            .get("balance")
            .and_then(|b| b.get("total"))
            .and_then(|t| t.as_f64())
            .unwrap_or(0.0);
        if balance <= 0.0 {
            0
        } else if balance <= 10.0 {
            30
        } else if balance <= 50.0 {
            70
        } else {
            100
        }
    }

    pub(crate) fn score_opencode_account(acc: &serde_json::Value) -> i64 {
        let is_enabled = acc
            .get("isEnabled")
            .and_then(|e| e.as_bool())
            .unwrap_or(true);
        let is_connected = acc
            .get("authenticationState")
            .and_then(|s| s.as_str())
            == Some("connected");
        if is_enabled && is_connected {
            100
        } else {
            0
        }
    }



    fn get_dynamic_models_payload_for_home(home: &str) -> serde_json::Value {
        let settings = GatewaySettings::load_for_home(home);
        let mut models: Vec<serde_json::Value> = Vec::new();
        let conn_path = format!("{home}/Library/Application Support/Tomo/connections-v1.json");
        if let Ok(content) = std::fs::read_to_string(&conn_path) {
            if let Ok(registry) = serde_json::from_str::<serde_json::Value>(&content) {
                // 1. Group 1: OpenAI / Codex Accounts
                if let Some(accounts) = registry.get("codexAccounts").and_then(|a| a.as_array()) {
                    if settings.is_provider_consolidated("openai") {
                        struct ConsolidatedOpenAI {
                            account_count: usize,
                            max_score: i64,
                        }
                        let mut openai_models: Vec<(String, ConsolidatedOpenAI)> = Vec::new();

                        for acc in accounts {
                            if !acc
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                                || acc.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let relative_home = acc
                                .get("relativeHomeDirectory")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            let codex_home = if relative_home.contains('/') || relative_home.contains("..") {
                                String::new()
                            } else {
                                format!(
                                    "{home}/Library/Application Support/Tomo/Runtimes/Codex/{relative_home}"
                                )
                            };
                            if !std::path::Path::new(&codex_home).join("oauth_token.json").is_file() {
                                continue;
                            }
                            let score = Self::score_codex_account(acc);
                            for entry in Self::codex_catalog(&codex_home) {
                                let Some(raw_mid) = entry.get("slug").and_then(|s| s.as_str()) else {
                                    continue;
                                };
                                if raw_mid.trim().is_empty() || raw_mid.chars().any(char::is_whitespace) {
                                    continue;
                                }
                                if let Some((_, info)) = openai_models.iter_mut().find(|(m, _)| m == raw_mid) {
                                    info.account_count += 1;
                                    info.max_score = info.max_score.max(score);
                                } else {
                                    openai_models.push((
                                        raw_mid.to_string(),
                                        ConsolidatedOpenAI {
                                            account_count: 1,
                                            max_score: score,
                                        },
                                    ));
                                }
                            }
                        }

                        for (raw_mid, info) in openai_models {
                            models.push(serde_json::json!({
                                "id": format!("openai/{raw_mid}"),
                                "name": format!("OpenAI · {raw_mid} (整合 {} 账号 · 最高额度 {}%)", info.account_count, info.max_score),
                                "display_name": format!("OpenAI · {raw_mid} (整合 {} 账号 · 最高额度 {}%)", info.account_count, info.max_score),
                                "object": "model",
                                "created": 1700000000,
                                "provider": "OpenAI / Codex",
                                "owned_by": "openai",
                                "account": format!("整合 {} 个账号", info.account_count),
                                "permission_tier": "高可用整合",
                                "quota_remaining": format!("最高额度 {}%", info.max_score),
                                "description": format!("OpenAI {} [整合 {} 个账号]", raw_mid, info.account_count)
                            }));
                        }
                    } else {
                        for acc in accounts {
                            if !acc
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                                || acc.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let label = acc.get("label").and_then(|l| l.as_str()).unwrap_or("codex");
                            let account_name = acc
                                .get("usage")
                                .and_then(|u| u.get("accountName"))
                                .and_then(|n| n.as_str());
                            let email = acc
                                .get("usage")
                                .and_then(|u| u.get("accountEmail"))
                                .and_then(|e| e.as_str());
                            let plan_raw = acc
                                .get("usage")
                                .and_then(|u| u.get("planName"))
                                .and_then(|p| p.as_str())
                                .unwrap_or("Plus");
                            let plan = if plan_raw.eq_ignore_ascii_case("plus") {
                                "Plus"
                            } else if plan_raw.eq_ignore_ascii_case("free") {
                                "Free"
                            } else {
                                plan_raw
                            };
                            let remaining = acc
                                .get("usage")
                                .and_then(|u| u.get("shortWindow"))
                                .and_then(|w| w.get("remaining"))
                                .and_then(|r| r.as_i64())
                                .unwrap_or(100);
                            let coupons = acc
                                .get("usage")
                                .and_then(|u| u.get("resetCoupons"))
                                .and_then(|c| c.as_array())
                                .map(|a| a.len())
                                .unwrap_or(0);
                            let quota_desc = if coupons > 0 {
                                format!("额度: {}% (含{}张重置券)", remaining, coupons)
                            } else {
                                format!("额度: {}%", remaining)
                            };

                            let (slug_base, friendly_name) =
                                Self::friendly_account_slug(account_name, email, label);
                            let short_id = Self::connection_short_id(acc);
                            let slug = format!("{slug_base}-openai-{short_id}");
                            let account_display = format!("{friendly_name} (OpenAI · {short_id})");

                            let relative_home = acc
                                .get("relativeHomeDirectory")
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            let codex_home = if relative_home.contains('/') || relative_home.contains("..") {
                                String::new()
                            } else {
                                format!(
                                    "{home}/Library/Application Support/Tomo/Runtimes/Codex/{relative_home}"
                                )
                            };
                            for entry in Self::codex_catalog(&codex_home) {
                                let Some(raw_mid) = entry.get("slug").and_then(|s| s.as_str()) else {
                                    continue;
                                };
                                if raw_mid.trim().is_empty() || raw_mid.chars().any(char::is_whitespace) {
                                    continue;
                                }
                                let sid = Self::scoped_model_id("openai", raw_mid, &slug);
                                if !models.iter().any(|existing| existing["id"] == sid) {
                                    models.push(serde_json::json!({
                                        "id": sid,
                                        "name": format!("OpenAI · {raw_mid} ({account_display})"),
                                        "display_name": format!("OpenAI · {raw_mid} ({account_display})"),
                                        "object": "model",
                                        "created": 1700000000,
                                        "provider": "OpenAI / Codex",
                                        "owned_by": "openai",
                                        "account": account_display,
                                        "permission_tier": plan,
                                        "quota_remaining": quota_desc,
                                        "description": format!("OpenAI {} [{}]", raw_mid, account_display)
                                    }));
                                }
                            }
                        }
                    }
                }

                // 2. Group 2: Google Gemini Accounts (OAuth token + proxy enabled)
                if let Some(accounts) = registry.get("geminiConnections").and_then(|a| a.as_array()) {
                    if settings.is_provider_consolidated("google") {
                        struct ConsolidatedGemini {
                            account_count: usize,
                            max_score: i64,
                        }
                        let mut gemini_models: Vec<(String, ConsolidatedGemini)> = Vec::new();

                        for acc in accounts {
                            let is_enabled = acc
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true);
                            let handle = acc
                                .get("credentialHandle")
                                .and_then(|h| h.as_str())
                                .unwrap_or("");
                            let has_oauth_token = Self::has_gemini_oauth_token_for_home(home, handle);

                            if !is_enabled
                                || !has_oauth_token
                                || acc.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let score = Self::score_gemini_account(acc);
                            let model_ids = acc
                                .get("availableModelIDs")
                                .and_then(|m| m.as_array())
                                .cloned()
                                .unwrap_or_default();
                            for raw_mid in model_ids {
                                let Some(mid) = raw_mid.as_str() else {
                                    continue;
                                };
                                if mid.trim().is_empty() || mid.chars().any(char::is_whitespace) {
                                    continue;
                                }
                                if let Some((_, info)) = gemini_models.iter_mut().find(|(m, _)| m == mid) {
                                    info.account_count += 1;
                                    info.max_score = info.max_score.max(score);
                                } else {
                                    gemini_models.push((
                                        mid.to_string(),
                                        ConsolidatedGemini {
                                            account_count: 1,
                                            max_score: score,
                                        },
                                    ));
                                }
                            }
                        }

                        for (mid, info) in gemini_models {
                            let display_model = Self::google_model_display_name(&mid);
                            models.push(serde_json::json!({
                                "id": format!("google/{mid}"),
                                "name": format!("Google · {display_model} (整合 {} 账号 · 最高额度 {}%)", info.account_count, info.max_score),
                                "display_name": format!("Google · {display_model} (整合 {} 账号 · 最高额度 {}%)", info.account_count, info.max_score),
                                "object": "model",
                                "created": 1700000000,
                                "provider": "Google Gemini",
                                "owned_by": "google",
                                "account": format!("整合 {} 个账号", info.account_count),
                                "permission_tier": "高可用整合",
                                "quota_remaining": format!("最高额度 {}%", info.max_score),
                                "description": format!("Google {} [整合 {} 个账号]", mid, info.account_count)
                            }));
                        }
                    } else {
                        for acc in accounts {
                            let is_enabled = acc
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true);
                            let handle = acc
                                .get("credentialHandle")
                                .and_then(|h| h.as_str())
                                .unwrap_or("");
                            let has_oauth_token = Self::has_gemini_oauth_token_for_home(home, handle);

                            if !is_enabled
                                || !has_oauth_token
                                || acc.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let label = acc
                                .get("label")
                                .and_then(|l| l.as_str())
                                .unwrap_or("gemini");
                            let display_name = acc.get("displayName").and_then(|d| d.as_str());
                            let email = acc.get("email").and_then(|e| e.as_str());
                            let tier = acc
                                .get("tier")
                                .and_then(|t| t.as_str())
                                .unwrap_or("Google OAuth");
                            let five_hour = acc
                                .get("geminiFiveHourRemaining")
                                .and_then(|f| f.as_f64())
                                .unwrap_or(1.0);
                            let weekly = acc
                                .get("geminiWeeklyRemaining")
                                .and_then(|w| w.as_f64())
                                .unwrap_or(1.0);
                            let quota_desc =
                                if (five_hour - 1.0).abs() < 0.001 && (weekly - 1.0).abs() < 0.001 {
                                    "5h 配额充足".to_string()
                                } else {
                                    format!("5h: {:.0}%, 周: {:.0}%", five_hour * 100.0, weekly * 100.0)
                                };

                            let (slug_base, friendly_name) =
                                Self::friendly_account_slug(display_name, email, label);
                            let short_id = Self::connection_short_id(acc);
                            let slug = format!("{slug_base}-google-{short_id}");
                            let account_display = format!("{friendly_name} (Google · {short_id})");

                            let model_ids = acc
                                .get("availableModelIDs")
                                .and_then(|models| models.as_array())
                                .cloned()
                                .unwrap_or_default();
                            for raw_mid in model_ids {
                                let Some(mid) = raw_mid.as_str() else {
                                    continue;
                                };
                                if mid.trim().is_empty() || mid.chars().any(char::is_whitespace) {
                                    continue;
                                }
                                let sid = Self::scoped_model_id("google", mid, &slug);
                                let display_model = Self::google_model_display_name(mid);
                                if !models.iter().any(|m: &serde_json::Value| m["id"] == sid) {
                                    models.push(serde_json::json!({
                                        "id": sid,
                                        "name": format!("Google · {display_model} ({account_display})"),
                                        "display_name": format!("Google · {display_model} ({account_display})"),
                                        "object": "model",
                                        "created": 1700000000,
                                        "provider": "Google Gemini",
                                        "owned_by": "google",
                                        "account": account_display,
                                        "permission_tier": tier,
                                        "quota_remaining": quota_desc,
                                        "description": format!("Google {} [{}]", mid, account_display)
                                    }));
                                }
                            }
                        }
                    }
                }

                // 3. Group 3: DeepSeek 官方账号
                if let Some(accounts) = registry
                    .get("deepSeekConnections")
                    .and_then(|a| a.as_array())
                {
                    if settings.is_provider_consolidated("deepseek") {
                        struct ConsolidatedDeepSeek {
                            account_count: usize,
                            max_score: i64,
                        }
                        let mut deepseek_models: Vec<(String, ConsolidatedDeepSeek)> = Vec::new();

                        for acc in accounts {
                            if !acc
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                                || acc.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let score = Self::score_deepseek_account(acc);
                            if let Some(mids) = acc.get("availableModelIDs").and_then(|m| m.as_array()) {
                                for raw_mid in mids.iter().filter_map(|model| model.as_str()) {
                                    if raw_mid.trim().is_empty() || raw_mid.chars().any(char::is_whitespace) {
                                        continue;
                                    }
                                    if let Some((_, info)) = deepseek_models.iter_mut().find(|(m, _)| m == raw_mid) {
                                        info.account_count += 1;
                                        info.max_score = info.max_score.max(score);
                                    } else {
                                        deepseek_models.push((
                                            raw_mid.to_string(),
                                            ConsolidatedDeepSeek {
                                                account_count: 1,
                                                max_score: score,
                                            },
                                        ));
                                    }
                                }
                            }
                        }

                        for (raw_mid, info) in deepseek_models {
                            models.push(serde_json::json!({
                                "id": format!("deepseek/{raw_mid}"),
                                "name": format!("DeepSeek · {raw_mid} (整合 {} 账号 · 最高额度 {}%)", info.account_count, info.max_score),
                                "display_name": format!("DeepSeek · {raw_mid} (整合 {} 账号 · 最高额度 {}%)", info.account_count, info.max_score),
                                "object": "model",
                                "created": 1700000000,
                                "provider": "DeepSeek 官方",
                                "owned_by": "deepseek",
                                "account": format!("整合 {} 个账号", info.account_count),
                                "permission_tier": "官方直连整合",
                                "quota_remaining": format!("最高额度 {}%", info.max_score),
                                "description": format!("DeepSeek {} [整合 {} 个账号]", raw_mid, info.account_count)
                            }));
                        }
                    } else {
                        for acc in accounts {
                            if !acc
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                                || acc.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let label = acc
                                .get("label")
                                .and_then(|l| l.as_str())
                                .unwrap_or("deepseek");
                            let balance_val = acc
                                .get("balance")
                                .and_then(|b| b.get("total"))
                                .and_then(|t| t.as_f64())
                                .unwrap_or(0.0);
                            let balance_desc = format!("¥{:.2}", balance_val);
                            let (slug_base, friendly_name) = Self::friendly_account_slug(None, None, label);
                            let short_id = Self::connection_short_id(acc);
                            let slug = format!("{slug_base}-deepseek-{short_id}");
                            let account_display = format!("{friendly_name} (DeepSeek · {short_id})");

                            if let Some(mids) = acc.get("availableModelIDs").and_then(|m| m.as_array()) {
                                for raw_mid in mids.iter().filter_map(|model| model.as_str()) {
                                    if raw_mid.trim().is_empty() || raw_mid.chars().any(char::is_whitespace) { continue; }
                                    let sid = Self::scoped_model_id("deepseek", raw_mid, &slug);
                                    if !models.iter().any(|model: &serde_json::Value| model["id"] == sid) {
                                        models.push(serde_json::json!({
                                            "id": sid,
                                            "name": format!("DeepSeek · {raw_mid} ({account_display})"),
                                            "display_name": format!("DeepSeek · {raw_mid} ({account_display})"),
                                            "object": "model",
                                            "created": 1700000000,
                                            "provider": "DeepSeek 官方",
                                            "owned_by": "deepseek",
                                            "account": account_display,
                                            "permission_tier": "官方直连",
                                            "quota_remaining": balance_desc,
                                            "description": format!("DeepSeek {} [{}]", raw_mid, account_display)
                                        }));
                                    }
                                }
                            }
                        }
                    }
                }

                // 4. Group 4: OpenCode 聚合平台
                if let Some(accounts) = registry
                    .get("openCodeConnections")
                    .and_then(|a| a.as_array())
                {
                    if settings.is_provider_consolidated("opencode") {
                        struct ConsolidatedOpenCode {
                            account_count: usize,
                        }
                        let mut opencode_models: Vec<(String, ConsolidatedOpenCode)> = Vec::new();

                        for acc in accounts {
                            if !acc
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                                || acc.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            if let Some(avail_models) = acc.get("availableModelIDs").and_then(|m| m.as_array()) {
                                for raw_m in avail_models {
                                    if let Some(mid) = raw_m.as_str() {
                                        if mid.chars().any(char::is_whitespace) {
                                            continue;
                                        }
                                        if let Some((_, info)) = opencode_models.iter_mut().find(|(m, _)| m == mid) {
                                            info.account_count += 1;
                                        } else {
                                            opencode_models.push((
                                                mid.to_string(),
                                                ConsolidatedOpenCode {
                                                    account_count: 1,
                                                },
                                            ));
                                        }
                                    }
                                }
                            }
                        }

                        for (mid, info) in opencode_models {
                            models.push(serde_json::json!({
                                "id": format!("opencode/{mid}"),
                                "name": format!("OpenCode · {mid} (整合 {} 账号)", info.account_count),
                                "display_name": format!("OpenCode · {mid} (整合 {} 账号)", info.account_count),
                                "object": "model",
                                "created": 1700000000,
                                "provider": "OpenCode 聚合平台",
                                "owned_by": "opencode",
                                "account": format!("整合 {} 个账号", info.account_count),
                                "permission_tier": "聚合平台整合",
                                "quota_remaining": "配额正常",
                                "description": format!("OpenCode {} [整合 {} 个账号]", mid, info.account_count)
                            }));
                        }
                    } else {
                        for acc in accounts {
                            if !acc
                                .get("isEnabled")
                                .and_then(|e| e.as_bool())
                                .unwrap_or(true)
                                || acc.get("authenticationState").and_then(|s| s.as_str())
                                    != Some("connected")
                            {
                                continue;
                            }
                            let label = acc
                                .get("label")
                                .and_then(|l| l.as_str())
                                .unwrap_or("opencode");
                            let plan = acc
                                .get("plan")
                                .and_then(|p| p.as_str())
                                .unwrap_or("go")
                                .to_uppercase();
                            let (slug_base, friendly_name) = Self::friendly_account_slug(None, None, label);
                            let short_id = Self::connection_short_id(acc);
                            let slug = format!("{slug_base}-opencode-{short_id}");
                            let account_display = format!("{friendly_name} (OpenCode · {short_id})");

                            if let Some(avail_models) =
                                acc.get("availableModelIDs").and_then(|m| m.as_array())
                            {
                                let count = avail_models.len();
                                let quota_desc = format!("可用 ({} 款模型)", count);
                                for raw_m in avail_models {
                                    if let Some(mid) = raw_m.as_str() {
                                        if mid.chars().any(char::is_whitespace) {
                                            continue;
                                        }
                                        let sid = Self::scoped_model_id("opencode", mid, &slug);
                                        if !models.iter().any(|m: &serde_json::Value| m["id"] == sid) {
                                            models.push(serde_json::json!({
                                                "id": sid,
                                                "name": format!("OpenCode · {mid} ({account_display})"),
                                                "display_name": format!("OpenCode · {mid} ({account_display})"),
                                                "object": "model",
                                                "created": 1700000000,
                                                "provider": "OpenCode 聚合平台",
                                                "owned_by": "opencode",
                                                "account": account_display,
                                                "permission_tier": format!("OpenCode {plan}"),
                                                "quota_remaining": quota_desc,
                                                "description": format!("OpenCode {} [{}]", mid, account_display)
                                            }));
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        serde_json::json!({
            "object": "list",
            "data": models
        })
    }

    fn process_chat_completions(&self, body: &str) -> Vec<u8> {
        let raw_req: OpenAiChatRequest = match serde_json::from_str(body) {
            Ok(r) => r,
            Err(err) => {
                return Self::response(
                    "400 Bad Request",
                    "application/json",
                    &serde_json::json!({"error": err.to_string()}).to_string(),
                );
            }
        };

        let req_id = format!(
            "req_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        );
        let canonical_res = decode_chat_request(raw_req, &req_id);
        let canonical = canonical_res.value;
        self.total_requests.fetch_add(1, Ordering::Relaxed);
        self.total_input_tokens
            .fetch_add((body.len() / 4).max(1), Ordering::Relaxed);
        self.total_output_tokens.fetch_add(12, Ordering::Relaxed);

        // Resolve target via RouteTable
        let resolved = match self.route_table.resolve(&canonical.model, None) {
            Ok(t) => t,
            Err(e) => {
                return Self::response(
                    "502 Bad Gateway",
                    "application/json",
                    &serde_json::json!({"error": e.to_string()}).to_string(),
                );
            }
        };

        let resp_id = format!("resp_{req_id}");
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        if !canonical.stream {
            let resp_json = serde_json::json!({
                "id": resp_id,
                "object": "chat.completion",
                "created": now,
                "model": resolved.model,
                "choices": [
                    {
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": format!("Hello from Tomo Gateway! (Routed to {})", resolved.model)
                        },
                        "finish_reason": "stop"
                    }
                ],
                "usage": {
                    "prompt_tokens": (body.len() / 4).max(1),
                    "completion_tokens": 12,
                    "total_tokens": (body.len() / 4).max(1) + 12
                }
            });
            return Self::response("200 OK", "application/json", &resp_json.to_string());
        }

        // Synthesize standard streaming response events
        let events = vec![
            StreamEvent::ResponseStarted(ResponseStarted {
                sequence: 1,
                response_id: resp_id.clone(),
                model: resolved.model.clone(),
                created_at: now,
            }),
            StreamEvent::TextDelta(TextDelta {
                sequence: 2,
                item_id: format!("{resp_id}_item_0"),
                text: "Hello from Tomo Gateway!".into(),
            }),
            StreamEvent::ResponseCompleted(ResponseCompleted {
                sequence: 3,
                finish_reason: FinishReason::Stop,
            }),
        ];

        let mut sse_body = String::new();
        for ev in &events {
            let lines = encode_chat_stream_event(ev, &resp_id, &resolved.model, now);
            for line in lines {
                sse_body.push_str(&line);
            }
        }

        Self::response("200 OK", "text/event-stream", &sse_body)
    }

    fn process_responses(&self, body: &str) -> Vec<u8> {
        let raw_req: OpenAiResponsesRequest = match serde_json::from_str(body) {
            Ok(r) => r,
            Err(err) => {
                return Self::response(
                    "400 Bad Request",
                    "application/json",
                    &serde_json::json!({"error": err.to_string()}).to_string(),
                );
            }
        };

        let req_id = format!(
            "req_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        );
        let canonical_res = decode_responses_request(raw_req, &req_id);
        let canonical = canonical_res.value;
        self.total_requests.fetch_add(1, Ordering::Relaxed);
        self.total_input_tokens
            .fetch_add((body.len() / 4).max(1), Ordering::Relaxed);
        self.total_output_tokens.fetch_add(12, Ordering::Relaxed);

        // Resolve target via RouteTable
        let resolved = match self.route_table.resolve(&canonical.model, None) {
            Ok(t) => t,
            Err(e) => {
                return Self::response(
                    "502 Bad Gateway",
                    "application/json",
                    &serde_json::json!({"error": e.to_string()}).to_string(),
                );
            }
        };

        let resp_id = format!("resp_{req_id}");
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        if !canonical.stream {
            let resp_json = serde_json::json!({
                "id": resp_id,
                "object": "response",
                "created": now,
                "model": resolved.model,
                "status": "completed",
                "output": [
                    {
                        "id": format!("{resp_id}_item_0"),
                        "type": "message",
                        "role": "assistant",
                        "content": [
                            {
                                "type": "output_text",
                                "text": "Codex wire response via Tomo Gateway."
                            }
                        ]
                    }
                ],
                "usage": {
                    "input_tokens": (body.len() / 4).max(1),
                    "output_tokens": 12,
                    "total_tokens": (body.len() / 4).max(1) + 12
                }
            });
            return Self::response("200 OK", "application/json", &resp_json.to_string());
        }

        let events = vec![
            StreamEvent::ResponseStarted(ResponseStarted {
                sequence: 1,
                response_id: resp_id.clone(),
                model: resolved.model.clone(),
                created_at: now,
            }),
            StreamEvent::TextDelta(TextDelta {
                sequence: 2,
                item_id: format!("{resp_id}_item_0"),
                text: "Codex wire response via Tomo Gateway.".into(),
            }),
            StreamEvent::ResponseCompleted(ResponseCompleted {
                sequence: 3,
                finish_reason: FinishReason::Stop,
            }),
        ];

        let mut sse_body = String::new();
        for ev in &events {
            let lines = encode_responses_stream_event(ev, &resp_id, &resolved.model);
            for line in lines {
                sse_body.push_str(&line);
            }
        }

        Self::response("200 OK", "text/event-stream", &sse_body)
    }

    fn process_anthropic_messages(&self, body: &str) -> Vec<u8> {
        let raw_req: AnthropicMessagesRequest = match serde_json::from_str(body) {
            Ok(r) => r,
            Err(err) => {
                return Self::response(
                    "400 Bad Request",
                    "application/json",
                    &serde_json::json!({"error": err.to_string()}).to_string(),
                );
            }
        };

        let req_id = format!(
            "req_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        );
        let canonical_res = decode_anthropic_request(raw_req, &req_id);
        let canonical = canonical_res.value;
        self.total_requests.fetch_add(1, Ordering::Relaxed);
        self.total_input_tokens
            .fetch_add((body.len() / 4).max(1), Ordering::Relaxed);
        self.total_output_tokens.fetch_add(12, Ordering::Relaxed);

        // Resolve target via RouteTable
        let resolved = match self.route_table.resolve(&canonical.model, None) {
            Ok(t) => t,
            Err(e) => {
                return Self::response(
                    "502 Bad Gateway",
                    "application/json",
                    &serde_json::json!({"error": e.to_string()}).to_string(),
                );
            }
        };

        let resp_id = format!("msg_{req_id}");

        if !canonical.stream {
            let resp_json = serde_json::json!({
                "id": resp_id,
                "type": "message",
                "role": "assistant",
                "model": resolved.model,
                "content": [
                    {
                        "type": "text",
                        "text": "Claude Code message via Tomo Gateway."
                    }
                ],
                "stop_reason": "end_turn",
                "stop_sequence": null,
                "usage": {
                    "input_tokens": (body.len() / 4).max(1),
                    "output_tokens": 12
                }
            });
            return Self::response("200 OK", "application/json", &resp_json.to_string());
        }

        let events = vec![
            StreamEvent::ResponseStarted(ResponseStarted {
                sequence: 1,
                response_id: resp_id.clone(),
                model: resolved.model.clone(),
                created_at: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_secs(),
            }),
            StreamEvent::TextDelta(TextDelta {
                sequence: 2,
                item_id: format!("{resp_id}_block_0"),
                text: "Claude Code message via Tomo Gateway.".into(),
            }),
            StreamEvent::ResponseCompleted(ResponseCompleted {
                sequence: 3,
                finish_reason: FinishReason::Stop,
            }),
        ];

        let mut sse_body = String::new();
        for ev in &events {
            let lines = encode_anthropic_stream_event(ev, &resp_id, &resolved.model);
            for line in lines {
                sse_body.push_str(&line);
            }
        }

        Self::response("200 OK", "text/event-stream", &sse_body)
    }

    pub fn run_loop(&self, listener: TcpListener) -> std::io::Result<()> {
        for stream_res in listener.incoming() {
            if !self.is_running.load(Ordering::Relaxed) {
                break;
            }
            if let Ok(stream) = stream_res {
                let server = self.clone();
                std::thread::spawn(move || {
                    if let Err(e) = server.handle_client(stream) {
                        if e.kind() != std::io::ErrorKind::BrokenPipe
                            && e.kind() != std::io::ErrorKind::ConnectionReset
                        {
                            eprintln!("[Gateway] Client error: {e}");
                        }
                    }
                });
            }
        }
        Ok(())
    }
}
