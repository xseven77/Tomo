use std::io::Write;
use std::net::TcpListener;
use std::thread;
use std::time::Duration;

mod model_health;
mod server;
pub use server::{GatewayServer, GatewaySettings};

fn main() -> std::io::Result<()> {
    let mut port: u16 = 0;
    let mut host = "127.0.0.1".to_string();
    let mut token = "tomo-local-token".to_string();
    let mut auto_check = false;
    let mut host_explicitly_set = false;
    let mut token_explicitly_set = false;

    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            if let Ok(p) = args[i + 1].parse::<u16>() {
                port = p;
            }
            i += 2;
        } else if args[i] == "--host" && i + 1 < args.len() {
            host = args[i + 1].clone();
            host_explicitly_set = true;
            i += 2;
        } else if args[i] == "--token" && i + 1 < args.len() {
            token = args[i + 1].clone();
            token_explicitly_set = true;
            i += 2;
        } else if args[i] == "--auto-check" {
            auto_check = true;
            i += 1;
        } else {
            i += 1;
        }
    }

    let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
    let settings = GatewaySettings::load_for_home(&home);
    if !host_explicitly_set && settings.allow_lan_access {
        host = "0.0.0.0".to_string();
    }
    if !token_explicitly_set {
        if let Some(ref auth_token) = settings.auth_token {
            let trimmed = auth_token.trim();
            if !trimmed.is_empty() {
                token = trimmed.to_string();
            }
        }
    }

    let bind_addr = format!("{host}:{port}");
    let listener = TcpListener::bind(&bind_addr)?;
    let actual_addr = listener.local_addr()?;

    // Emit ready handshake event on first line of stdout
    println!(
        r#"{{"event":"ready","host":"{host}","port":{},"token":"{}"}}"#,
        actual_addr.port(),
        token
    );
    std::io::stdout().flush()?;

    let server = GatewayServer::new(token);

    if auto_check {
        let health_engine = server.model_health.clone();
        thread::spawn(move || {
            let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/qiizo".into());
            // Initial delay of 15 seconds after app startup before evaluating check
            thread::sleep(Duration::from_secs(15));

            // 软件启动或网关重启时：若无历史记录，执行首次引导巡检；
            // 若已有历史记录，遵从 `auto_check_on_startup_with_history` 设置
            {
                let settings = GatewaySettings::load_for_home(&home);
                let has_history = {
                    let data = match health_engine.data.lock() {
                        Ok(d) => d,
                        Err(p) => p.into_inner(),
                    };
                    data.last_full_check_at.is_some()
                };

                let should_run_startup = if !has_history {
                    true
                } else {
                    settings.auto_check_on_startup_with_history
                };

                if should_run_startup {
                    let targets = health_engine.collect_targets(&home, &model_health::CheckScope::All);
                    let count = targets.len();
                    if health_engine.try_start_job("all", count).is_ok() {
                        health_engine.run_check(&home, model_health::CheckScope::All);
                    }
                }
            }

            // 定时巡检自动化任务轮询调度（每 30 秒评估一次，比对当地小时是否命中计划）
            loop {
                thread::sleep(Duration::from_secs(30));

                let settings = GatewaySettings::load_for_home(&home);
                let now = model_health::ModelHealthEngine::now_epoch_secs();

                for task in settings.automation_tasks.iter() {
                    if !GatewaySettings::is_task_due(task, now) {
                        continue;
                    }

                    let task_id = task.id.clone();
                    let task_name = task.name.clone();
                    let task_type = task.task_type.clone();
                    let scope = model_health::CheckScope::Selective {
                        providers: task.providers.clone(),
                        account_ids: if task.all_accounts { Vec::new() } else { task.account_ids.clone() },
                        all_accounts: task.all_accounts,
                    };

                    let targets = health_engine.collect_targets(&home, &scope);
                    let count = targets.len();
                    let scope_desc = format!("task:{task_id}");
                    if health_engine.try_start_job(&scope_desc, count).is_err() {
                        continue;
                    }

                    // 每 30 秒复查一次设置文件：run_check 可能持续数分钟，
                    // 期间 App 可能改过设置，因此每次都基于最新内容改写。
                    let log_id = format!("{task_id}-{now}");
                    let mut start_settings = GatewaySettings::load_for_home(&home);
                    if let Some(entry) = start_settings
                        .automation_tasks
                        .iter_mut()
                        .find(|entry| entry.id == task_id)
                    {
                        entry.last_run_at = Some(now);
                        entry.last_run_status = Some("running".to_string());
                        entry.last_run_summary = None;
                    }
                    start_settings.push_automation_run_log(server::GatewayAutomationRunLog {
                        id: log_id.clone(),
                        task_id: task_id.clone(),
                        task_name,
                        task_type,
                        started_at: now,
                        finished_at: None,
                        is_success: None,
                        summary: None,
                        cancelled: None,
                        results: None,
                    });
                    let _ = start_settings.save_for_home(&home);

                    health_engine.run_check(&home, scope);

                    let finished_at = model_health::ModelHealthEngine::now_epoch_secs();
                    let (is_success, summary_text, is_cancelled) = summarize_job_result(&health_engine);
                    let probe_results = {
                        let job = match health_engine.job.lock() {
                            Ok(job) => job,
                            Err(poisoned) => poisoned.into_inner(),
                        };
                        if job.results.is_empty() {
                            None
                        } else {
                            Some(job.results.clone())
                        }
                    };

                    let mut end_settings = GatewaySettings::load_for_home(&home);
                    if let Some(entry) = end_settings
                        .automation_tasks
                        .iter_mut()
                        .find(|entry| entry.id == task_id)
                    {
                        entry.last_run_status = Some(
                            if is_cancelled {
                                "cancelled"
                            } else if is_success {
                                "success"
                            } else {
                                "failed"
                            }
                            .to_string(),
                        );
                        entry.last_run_summary = Some(summary_text.clone());
                    }
                    end_settings.finish_automation_run_log(
                        &log_id,
                        finished_at,
                        is_success,
                        &summary_text,
                        is_cancelled,
                        probe_results,
                    );
                    let _ = end_settings.save_for_home(&home);
                }
            }
        });
    }

    server.run_loop(listener)?;

    Ok(())
}

/// 汇总一次巡检的结果，文案与 App 端 `GatewayStore.pollModelCheckStatus` 保持一致。
///
/// 返回 `(is_success, summary, is_cancelled)`：取消的巡检必须与失败区分，
/// 否则执行日志会把「用户取消」显示成「失败」，任务状态也会被误判。
fn summarize_job_result(engine: &model_health::ModelHealthEngine) -> (bool, String, bool) {
    let summary = {
        let job = match engine.job.lock() {
            Ok(job) => job,
            Err(poisoned) => poisoned.into_inner(),
        };
        job.last_summary.clone()
    };

    let number = |key: &str| -> i64 {
        summary
            .as_ref()
            .and_then(|value| value.get(key))
            .and_then(|value| value.as_i64())
            .unwrap_or(0)
    };

    let available = number("available");
    let error = number("error");
    let cancelled = summary
        .as_ref()
        .and_then(|value| value.get("cancelled"))
        .and_then(|value| value.as_bool())
        .unwrap_or(false);

    if cancelled {
        return (false, format!("已取消 · 可用 {available} · 异常 {error}"), true);
    }

    let is_success = available > 0 || error == 0;
    (
        is_success,
        format!("可用 {available} · 异常 {error}"),
        false,
    )
}
