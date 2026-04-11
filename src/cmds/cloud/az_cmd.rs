//! Azure CLI output compression.
//!
//! Filters verbose JSON from `az pipelines`, `az devops invoke`, and `az account`
//! into compact summaries. Specialized handlers for high-frequency Azure DevOps
//! commands; generic JSON compression fallback for everything else.

use crate::core::tee::force_tee_hint;
use crate::core::tracking;
use crate::core::utils::{exit_code_from_output, exit_code_from_status, resolved_command, truncate_iso_date};
use crate::json_cmd;
use anyhow::{Context, Result};
use lazy_static::lazy_static;
use regex::Regex;
use serde_json::Value;

const MAX_ITEMS: usize = 20;
const JSON_COMPRESS_DEPTH: usize = 4;
const LOG_TAIL_LINES: usize = 50;

struct FilterResult {
    text: String,
    truncated: bool,
}

impl FilterResult {
    fn new(text: String) -> Self {
        Self {
            text,
            truncated: false,
        }
    }

    fn truncated(text: String) -> Self {
        Self {
            text,
            truncated: true,
        }
    }
}

// ─── Entry point ───────────────────────────────────────────────────────────

/// Run an Azure CLI command with token-optimized output
pub fn run(subcommand: &str, args: &[String], verbose: u8) -> Result<i32> {
    let full_sub = if args.is_empty() {
        subcommand.to_string()
    } else {
        format!("{} {}", subcommand, args.join(" "))
    };

    match subcommand {
        "pipelines" if !args.is_empty() && args[0] == "build" => {
            run_pipelines_build(&args[1..], verbose, &full_sub)
        }
        "devops" if !args.is_empty() && args[0] == "invoke" => {
            run_devops_invoke(&args[1..], verbose, &full_sub)
        }
        "account" if !args.is_empty() && args[0] == "get-access-token" => {
            run_account_token(&args[1..], verbose, &full_sub)
        }
        _ => run_generic(subcommand, args, verbose, &full_sub),
    }
}

// ─── az pipelines build (list | show) ──────────────────────────────────────

fn run_pipelines_build(args: &[String], verbose: u8, full_sub: &str) -> Result<i32> {
    if !args.is_empty() && args[0] == "list" {
        return run_az_filtered(&build_az_args("pipelines", &["build", "list"], &args[1..]), verbose, full_sub, filter_build_list);
    }
    if !args.is_empty() && args[0] == "show" {
        return run_az_filtered(&build_az_args("pipelines", &["build", "show"], &args[1..]), verbose, full_sub, filter_build_show);
    }
    run_generic("pipelines", &prepend_arg("build", args), verbose, full_sub)
}

fn filter_build_list(json_str: &str) -> Option<FilterResult> {
    let v: Value = serde_json::from_str(json_str).ok()?;
    let builds = v.as_array()?;

    let total = builds.len();
    if total == 0 {
        return Some(FilterResult::new("No builds found".to_string()));
    }

    let truncated = total > MAX_ITEMS;
    let mut lines = Vec::new();

    for b in builds.iter().take(MAX_ITEMS) {
        let id = b["id"].as_i64().unwrap_or(0);
        let result = b["result"].as_str().unwrap_or("?");
        let status = b["status"].as_str().unwrap_or("?");
        let def_name = b["definition"]["name"].as_str().unwrap_or("?");
        let branch = b["sourceBranch"].as_str().unwrap_or("?");
        let finish = b["finishTime"]
            .as_str()
            .map(|t| truncate_iso_date(t))
            .unwrap_or("running");

        // Shorten branch refs
        let short_branch = branch
            .strip_prefix("refs/heads/")
            .or_else(|| branch.strip_prefix("refs/pull/"))
            .unwrap_or(branch);

        let icon = match result {
            "succeeded" => "ok",
            "failed" => "FAIL",
            "canceled" => "skip",
            _ if status == "inProgress" => "...",
            _ => "?",
        };

        lines.push(format!(
            "{} {} | {} | {} | {} | {}",
            icon, id, def_name, result, short_branch, finish
        ));
    }

    let text = if truncated {
        format!(
            "{}\n... +{} more builds",
            lines.join("\n"),
            total - MAX_ITEMS
        )
    } else {
        lines.join("\n")
    };

    Some(if truncated {
        FilterResult::truncated(text)
    } else {
        FilterResult::new(text)
    })
}

fn filter_build_show(json_str: &str) -> Option<FilterResult> {
    let b: Value = serde_json::from_str(json_str).ok()?;

    let id = b["id"].as_i64().unwrap_or(0);
    let result = b["result"].as_str().unwrap_or("?");
    let status = b["status"].as_str().unwrap_or("?");
    let def_name = b["definition"]["name"].as_str().unwrap_or("?");
    let finish = b["finishTime"]
        .as_str()
        .map(|t| truncate_iso_date(t))
        .unwrap_or("running");

    let icon = match result {
        "succeeded" => "ok",
        "failed" => "FAIL",
        "canceled" => "skip",
        _ if status == "inProgress" => "...",
        _ => "?",
    };

    Some(FilterResult::new(format!(
        "{} build {} | {} | {} | {}",
        icon, id, def_name, result, finish
    )))
}

// ─── az devops invoke (timeline | logs) ────────────────────────────────────

fn run_devops_invoke(args: &[String], verbose: u8, full_sub: &str) -> Result<i32> {
    let resource = find_flag_value(args, "--resource");

    match resource.as_deref() {
        Some("timeline") => {
            run_az_filtered(&build_az_args("devops", &["invoke"], args), verbose, full_sub, filter_timeline)
        }
        Some("logs") => {
            run_az_text_filtered(&build_az_args("devops", &["invoke"], args), verbose, full_sub, filter_logs)
        }
        _ => run_generic("devops", &prepend_arg("invoke", args), verbose, full_sub),
    }
}

fn filter_timeline(json_str: &str) -> Option<FilterResult> {
    let v: Value = serde_json::from_str(json_str).ok()?;
    let records = v["records"].as_array()?;

    let total = records.len();
    let failed: Vec<&Value> = records
        .iter()
        .filter(|r| r["result"].as_str() == Some("failed"))
        .collect();

    let mut lines = Vec::new();
    for r in &failed {
        let name = r["name"].as_str().unwrap_or("?");
        let rtype = r["type"].as_str().unwrap_or("?");
        let log_id = r["log"]["id"].as_i64();
        let log_str = match log_id {
            Some(id) => format!("logId:{}", id),
            None => "logId:-".to_string(),
        };
        lines.push(format!("{} ({}) — {}", name, rtype, log_str));
    }

    let summary = if failed.is_empty() {
        format!("ok timeline: 0 failed of {} tasks", total)
    } else {
        format!(
            "FAIL timeline: {} failed of {} tasks\n{}",
            failed.len(),
            total,
            lines.join("\n")
        )
    };

    Some(FilterResult::new(summary))
}

fn filter_logs(raw: &str) -> Option<FilterResult> {
    // az devops invoke --resource logs returns JSON with a "value" array of log lines,
    // OR when fetching a specific log, the lines are in the "value" array too.
    if let Ok(v) = serde_json::from_str::<Value>(raw) {
        if let Some(log_lines) = v["value"].as_array() {
            // List of available logs (each has id and lineCount)
            if log_lines.first().and_then(|l| l["lineCount"].as_i64()).is_some() {
                let mut lines = Vec::new();
                for log in log_lines {
                    let id = log["id"].as_i64().unwrap_or(0);
                    let count = log["lineCount"].as_i64().unwrap_or(0);
                    lines.push(format!("logId:{} ({} lines)", id, count));
                }
                return Some(FilterResult::new(lines.join("\n")));
            }

            // Actual log content — array of strings with timestamp prefixes
            let total = log_lines.len();
            let tail: Vec<&Value> = if total > LOG_TAIL_LINES {
                log_lines[total - LOG_TAIL_LINES..].iter().collect()
            } else {
                log_lines.iter().collect()
            };

            let truncated = total > LOG_TAIL_LINES;
            let mut stripped = Vec::new();

            lazy_static! {
                static ref TIMESTAMP_RE: Regex =
                    Regex::new(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z\s*").unwrap();
            }

            for line in &tail {
                if let Some(s) = (*line).as_str() {
                    let cleaned = TIMESTAMP_RE.replace(s, "").to_string();
                    stripped.push(cleaned);
                }
            }

            let mut text = stripped.join("\n");
            if truncated {
                text = format!("... ({} lines total, showing last {})\n{}", total, LOG_TAIL_LINES, text);
            }

            return Some(if truncated {
                FilterResult::truncated(text)
            } else {
                FilterResult::new(text)
            });
        }
    }

    // Not JSON or unexpected structure — pass through
    None
}

// ─── az account get-access-token ───────────────────────────────────────────

fn run_account_token(args: &[String], verbose: u8, full_sub: &str) -> Result<i32> {
    run_az_filtered(
        &build_az_args("account", &["get-access-token"], args),
        verbose,
        full_sub,
        filter_access_token,
    )
}

fn filter_access_token(json_str: &str) -> Option<FilterResult> {
    let v: Value = serde_json::from_str(json_str).ok()?;
    let token = v["accessToken"].as_str()?;
    let expires = v["expiresOn"]
        .as_str()
        .map(|t| format!(" (expires {})", truncate_iso_date(t)))
        .unwrap_or_default();

    Some(FilterResult::new(format!("{}{}", token, expires)))
}

// ─── Generic fallback ──────────────────────────────────────────────────────

fn run_generic(subcommand: &str, args: &[String], verbose: u8, full_sub: &str) -> Result<i32> {
    let timer = tracking::TimedExecution::start();

    let mut cmd = resolved_command("az");
    cmd.arg(subcommand);

    let mut has_output_flag = false;
    for arg in args {
        if arg == "--output" || arg == "-o" {
            has_output_flag = true;
        }
        cmd.arg(arg);
    }

    // Inject JSON output for structured operations if not already set
    if !has_output_flag {
        cmd.args(["--output", "json"]);
    }

    if verbose > 0 {
        eprintln!("Running: az {}", full_sub);
    }

    let output = cmd.output().context("Failed to run az CLI")?;
    let raw = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if !output.status.success() {
        timer.track(
            &format!("az {}", full_sub),
            &format!("rtk az {}", full_sub),
            &stderr,
            &stderr,
        );
        eprintln!("{}", stderr.trim());
        return Ok(exit_code_from_output(&output, "az"));
    }

    let filtered = match json_cmd::filter_json_string(&raw, JSON_COMPRESS_DEPTH) {
        Ok(schema) => {
            println!("{}", schema);
            schema
        }
        Err(_) => {
            print!("{}", raw);
            raw.clone()
        }
    };

    timer.track(
        &format!("az {}", full_sub),
        &format!("rtk az {}", full_sub),
        &raw,
        &filtered,
    );

    Ok(0)
}

// ─── Shared runners ────────────────────────────────────────────────────────

fn run_az_filtered(
    full_args: &[String],
    verbose: u8,
    full_sub: &str,
    filter_fn: fn(&str) -> Option<FilterResult>,
) -> Result<i32> {
    let cmd_label = format!("az {}", full_sub);
    let rtk_label = format!("rtk az {}", full_sub);
    let slug = cmd_label.replace(' ', "_");
    let timer = tracking::TimedExecution::start();

    let (stdout, stderr, status) = run_az_json(full_args, verbose, full_sub)?;

    let raw = if stderr.is_empty() {
        stdout.clone()
    } else {
        format!("{}\n{}", stdout, stderr)
    };

    if !status.success() {
        let exit_code = exit_code_from_status(&status, "az");
        if let Some(hint) = crate::core::tee::tee_and_hint(&raw, &slug, exit_code) {
            eprintln!("{}\n{}", stderr.trim(), hint);
        } else {
            eprintln!("{}", stderr.trim());
        }
        timer.track(&cmd_label, &rtk_label, &raw, &stderr);
        return Ok(exit_code);
    }

    let result = filter_fn(&stdout).unwrap_or_else(|| {
        eprintln!("rtk: filter warning: az filter returned None, passing through raw output");
        FilterResult::new(stdout.clone())
    });

    if result.truncated {
        if let Some(hint) = force_tee_hint(&raw, &slug) {
            println!("{}\n{}", result.text, hint);
        } else {
            println!("{}", result.text);
        }
    } else if let Some(hint) = crate::core::tee::tee_and_hint(&raw, &slug, 0) {
        println!("{}\n{}", result.text, hint);
    } else {
        println!("{}", result.text);
    }

    timer.track(&cmd_label, &rtk_label, &raw, &result.text);
    Ok(0)
}

fn run_az_text_filtered(
    full_args: &[String],
    verbose: u8,
    full_sub: &str,
    filter_fn: fn(&str) -> Option<FilterResult>,
) -> Result<i32> {
    let cmd_label = format!("az {}", full_sub);
    let rtk_label = format!("rtk az {}", full_sub);
    let slug = cmd_label.replace(' ', "_");
    let timer = tracking::TimedExecution::start();

    // Run without forcing JSON output — logs can be text or JSON
    let mut cmd = resolved_command("az");
    for arg in full_args {
        cmd.arg(arg);
    }

    if verbose > 0 {
        eprintln!("Running: az {}", full_sub);
    }

    let output = cmd.output().context("Failed to run az CLI")?;
    let raw = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if !output.status.success() {
        timer.track(&cmd_label, &rtk_label, &stderr, &stderr);
        eprintln!("{}", stderr.trim());
        return Ok(exit_code_from_output(&output, "az"));
    }

    let result = filter_fn(&raw).unwrap_or_else(|| FilterResult::new(raw.clone()));

    if result.truncated {
        if let Some(hint) = force_tee_hint(&raw, &slug) {
            println!("{}\n{}", result.text, hint);
        } else {
            println!("{}", result.text);
        }
    } else {
        println!("{}", result.text);
    }

    timer.track(&cmd_label, &rtk_label, &raw, &result.text);
    Ok(0)
}

fn run_az_json(
    full_args: &[String],
    verbose: u8,
    full_sub: &str,
) -> Result<(String, String, std::process::ExitStatus)> {
    let mut cmd = resolved_command("az");

    // Pass through all args but ensure JSON output
    let mut has_output_flag = false;
    for arg in full_args {
        if arg == "--output" || arg == "-o" {
            has_output_flag = true;
        }
        cmd.arg(arg);
    }
    if !has_output_flag {
        cmd.args(["--output", "json"]);
    }

    if verbose > 0 {
        eprintln!("Running: az {}", full_sub);
    }

    let output = cmd
        .output()
        .context(format!("Failed to run az {}", full_sub))?;
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if !output.status.success() {
        eprintln!("{}", stderr.trim());
    }

    Ok((stdout, stderr, output.status))
}

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Find the value of a --flag in an args slice
fn find_flag_value(args: &[String], flag: &str) -> Option<String> {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == flag {
            return iter.next().cloned();
        }
        if let Some(val) = arg.strip_prefix(&format!("{}=", flag)) {
            return Some(val.to_string());
        }
    }
    None
}

/// Build full az args: ["pipelines", "build", "list", ...extra_args]
fn build_az_args(service: &str, sub_args: &[&str], extra_args: &[String]) -> Vec<String> {
    let mut all = vec![service.to_string()];
    for s in sub_args {
        all.push(s.to_string());
    }
    all.extend(extra_args.iter().cloned());
    all
}

/// Prepend a single arg to an args slice
fn prepend_arg(first: &str, rest: &[String]) -> Vec<String> {
    let mut all = vec![first.to_string()];
    all.extend(rest.iter().cloned());
    all
}

// ─── Tests ─────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_filter_build_list_single() {
        let json = r#"[{
            "id": 12345,
            "buildNumber": "2026.0410.1",
            "result": "succeeded",
            "status": "completed",
            "definition": {"name": "MyPipeline"},
            "sourceBranch": "refs/heads/main",
            "finishTime": "2026-04-10T12:00:00.000Z",
            "startTime": "2026-04-10T11:50:00.000Z"
        }]"#;
        let result = filter_build_list(json).unwrap();
        assert!(result.text.contains("ok 12345"));
        assert!(result.text.contains("MyPipeline"));
        assert!(result.text.contains("succeeded"));
        assert!(result.text.contains("main"));
        assert!(!result.truncated);
    }

    #[test]
    fn test_filter_build_list_failed() {
        let json = r#"[{
            "id": 99,
            "buildNumber": "1",
            "result": "failed",
            "status": "completed",
            "definition": {"name": "CI"},
            "sourceBranch": "refs/pull/42/merge",
            "finishTime": "2026-04-10T12:00:00.000Z",
            "startTime": "2026-04-10T11:50:00.000Z"
        }]"#;
        let result = filter_build_list(json).unwrap();
        assert!(result.text.contains("FAIL 99"));
        assert!(result.text.contains("42/merge"));
    }

    #[test]
    fn test_filter_build_list_empty() {
        let json = "[]";
        let result = filter_build_list(json).unwrap();
        assert_eq!(result.text, "No builds found");
    }

    #[test]
    fn test_filter_build_show() {
        let json = r#"{
            "id": 12345,
            "result": "succeeded",
            "status": "completed",
            "definition": {"name": "MyPipeline"},
            "finishTime": "2026-04-10T12:00:00.000Z"
        }"#;
        let result = filter_build_show(json).unwrap();
        assert!(result.text.starts_with("ok build 12345"));
        assert!(result.text.contains("MyPipeline"));
    }

    #[test]
    fn test_filter_timeline_with_failures() {
        let json = r#"{
            "records": [
                {"name": "Build", "type": "Stage", "result": "succeeded", "log": null},
                {"name": "Run Tests", "type": "Task", "result": "failed", "log": {"id": 42}},
                {"name": "Publish Results", "type": "Task", "result": "failed", "log": {"id": 43}}
            ]
        }"#;
        let result = filter_timeline(json).unwrap();
        assert!(result.text.contains("FAIL timeline: 2 failed of 3 tasks"));
        assert!(result.text.contains("Run Tests (Task) — logId:42"));
        assert!(result.text.contains("Publish Results (Task) — logId:43"));
    }

    #[test]
    fn test_filter_timeline_all_pass() {
        let json = r#"{
            "records": [
                {"name": "Build", "type": "Stage", "result": "succeeded", "log": null},
                {"name": "Test", "type": "Task", "result": "succeeded", "log": {"id": 1}}
            ]
        }"#;
        let result = filter_timeline(json).unwrap();
        assert_eq!(result.text, "ok timeline: 0 failed of 2 tasks");
    }

    #[test]
    fn test_filter_logs_strips_timestamps() {
        let json = r#"{
            "value": [
                "2026-04-10T12:00:00.1234567Z First line",
                "2026-04-10T12:00:01.1234567Z Second line",
                "2026-04-10T12:00:02.1234567Z Third line"
            ]
        }"#;
        let result = filter_logs(json).unwrap();
        assert!(result.text.contains("First line"));
        assert!(result.text.contains("Second line"));
        assert!(!result.text.contains("2026-04-10T"));
    }

    #[test]
    fn test_filter_logs_list() {
        let json = r#"{
            "value": [
                {"id": 1, "lineCount": 100},
                {"id": 2, "lineCount": 50}
            ]
        }"#;
        let result = filter_logs(json).unwrap();
        assert!(result.text.contains("logId:1 (100 lines)"));
        assert!(result.text.contains("logId:2 (50 lines)"));
    }

    #[test]
    fn test_filter_access_token() {
        let json = r#"{
            "accessToken": "eyJ0eXAiOiJKV1QiLCJhbGci...",
            "expiresOn": "2026-04-10T13:00:00.000Z",
            "subscription": "sub-id",
            "tenant": "tenant-id",
            "tokenType": "Bearer"
        }"#;
        let result = filter_access_token(json).unwrap();
        assert!(result.text.starts_with("eyJ0eXAiOiJKV1QiLCJhbGci..."));
        assert!(result.text.contains("expires"));
    }

    #[test]
    fn test_find_flag_value() {
        let args: Vec<String> = vec![
            "--resource".into(),
            "timeline".into(),
            "--route-parameters".into(),
            "buildId=123".into(),
        ];
        assert_eq!(find_flag_value(&args, "--resource"), Some("timeline".to_string()));
        assert_eq!(find_flag_value(&args, "--route-parameters"), Some("buildId=123".to_string()));
        assert_eq!(find_flag_value(&args, "--missing"), None);
    }

    #[test]
    fn test_find_flag_value_equals() {
        let args: Vec<String> = vec!["--resource=logs".into()];
        assert_eq!(find_flag_value(&args, "--resource"), Some("logs".to_string()));
    }
}
