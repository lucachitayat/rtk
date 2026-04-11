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

lazy_static! {
    static ref TIMESTAMP_RE: Regex =
        Regex::new(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z\s*").unwrap();
}

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
        let build_number = b["buildNumber"].as_str().unwrap_or("?");
        let branch = b["sourceBranch"].as_str().unwrap_or("?");
        let reason = b["reason"].as_str().unwrap_or("?");
        let finish = b["finishTime"]
            .as_str()
            .map(truncate_iso_date)
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
            "{} {} #{} | {} | {} | {} | {} | {}",
            icon, id, build_number, def_name, result, short_branch, reason, finish
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
    let build_number = b["buildNumber"].as_str().unwrap_or("?");
    let reason = b["reason"].as_str().unwrap_or("?");
    let requested_by = b["requestedBy"]["displayName"].as_str().unwrap_or("?");

    let branch = b["sourceBranch"].as_str().unwrap_or("?");
    let short_branch = branch
        .strip_prefix("refs/heads/")
        .or_else(|| branch.strip_prefix("refs/pull/"))
        .unwrap_or(branch);

    let source_version = b["sourceVersion"].as_str().unwrap_or("?");
    let short_commit = if source_version.len() >= 7 {
        &source_version[..7]
    } else {
        source_version
    };

    let start = b["startTime"].as_str();
    let finish = b["finishTime"].as_str();

    let icon = match result {
        "succeeded" => "ok",
        "failed" => "FAIL",
        "canceled" => "skip",
        _ if status == "inProgress" => "...",
        _ => "?",
    };

    // Calculate duration if both timestamps present
    let time_info = match (start, finish) {
        (Some(s), Some(f)) => {
            match (chrono::DateTime::parse_from_rfc3339(s), chrono::DateTime::parse_from_rfc3339(f)) {
                (Ok(start_dt), Ok(finish_dt)) => {
                    let duration = finish_dt.signed_duration_since(start_dt);
                    let minutes = duration.num_minutes();
                    format!(
                        "started: {} | finished: {} ({}m)",
                        truncate_iso_date(s),
                        truncate_iso_date(f),
                        minutes
                    )
                }
                _ => format!(
                    "started: {} | finished: {}",
                    truncate_iso_date(s),
                    truncate_iso_date(f)
                ),
            }
        }
        (Some(s), None) => format!("started: {} | finished: running", truncate_iso_date(s)),
        (None, Some(f)) => format!("finished: {}", truncate_iso_date(f)),
        (None, None) => "started: ? | finished: ?".to_string(),
    };

    Some(FilterResult::new(format!(
        "{} build {} | {} #{}\n  branch: {} | commit: {}\n  reason: {} | by: {}\n  {}",
        icon, id, def_name, build_number, short_branch, short_commit, reason, requested_by, time_info
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
    let mut failed_count = 0;
    let mut lines = Vec::new();

    for r in records {
        let name = r["name"].as_str().unwrap_or("?");
        let rtype = r["type"].as_str().unwrap_or("?");
        let result = r["result"].as_str().unwrap_or("?");
        let start = r["startTime"].as_str();
        let finish = r["finishTime"].as_str();

        // Calculate duration
        let duration_str = match (start, finish) {
            (Some(s), Some(f)) => {
                match (chrono::DateTime::parse_from_rfc3339(s), chrono::DateTime::parse_from_rfc3339(f)) {
                    (Ok(start_dt), Ok(finish_dt)) => {
                        let duration = finish_dt.signed_duration_since(start_dt);
                        let minutes = duration.num_minutes();
                        let seconds = duration.num_seconds() % 60;
                        if minutes > 0 {
                            format!("{}m{}s", minutes, seconds)
                        } else {
                            format!("{}s", seconds)
                        }
                    }
                    _ => "?".to_string(),
                }
            }
            _ => "?".to_string(),
        };

        if result == "failed" {
            failed_count += 1;
            let log_id = r["log"]["id"].as_i64();
            let log_str = match log_id {
                Some(id) => format!("logId:{}", id),
                None => "logId:-".to_string(),
            };

            let error_count = r["errorCount"].as_i64().unwrap_or(0);
            let warning_count = r["warningCount"].as_i64().unwrap_or(0);

            let mut counters = Vec::new();
            if error_count > 0 {
                counters.push(format!("{}err", error_count));
            }
            if warning_count > 0 {
                counters.push(format!("{}warn", warning_count));
            }
            let counter_str = if counters.is_empty() {
                String::new()
            } else {
                format!(" {}", counters.join(" "))
            };

            lines.push(format!(
                "  FAIL {} ({}) {}{} {}",
                name, rtype, log_str, counter_str, duration_str
            ));

            // Add first issue message if present
            if let Some(issues) = r["issues"].as_array() {
                if let Some(first_issue) = issues.first() {
                    if let Some(msg) = first_issue["message"].as_str() {
                        lines.push(format!("    > {}", msg));
                    }
                }
            }
        } else {
            lines.push(format!("  ok {} ({}) {}", name, rtype, duration_str));
        }
    }

    let summary = if failed_count == 0 {
        format!("ok timeline: 0 failed of {} tasks", total)
    } else {
        format!("FAIL timeline: {} failed of {} tasks", failed_count, total)
    };

    let full_text = if lines.is_empty() {
        summary
    } else {
        format!("{}\n{}", summary, lines.join("\n"))
    };

    Some(FilterResult::new(full_text))
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
    let token_type = v["tokenType"].as_str().unwrap_or("Bearer");
    let subscription = v["subscription"].as_str().unwrap_or("?");
    let tenant = v["tenant"].as_str().unwrap_or("?");
    let expires = v["expiresOn"]
        .as_str()
        .map(truncate_iso_date)
        .unwrap_or("?");

    // Mask the token — only show prefix to confirm it was obtained
    let prefix_len = token.len().min(10);
    let prefix = &token[..prefix_len];

    Some(FilterResult::new(format!(
        "{} [{}...] | sub:{} | tenant:{} | expires:{}",
        token_type, prefix, subscription, tenant, expires
    )))
}

// ─── Generic fallback ──────────────────────────────────────────────────────

fn run_generic(subcommand: &str, args: &[String], verbose: u8, full_sub: &str) -> Result<i32> {
    let timer = tracking::TimedExecution::start();

    let mut cmd = resolved_command("az");
    cmd.arg(subcommand);

    let mut has_output_flag = false;
    for arg in args {
        if arg == "--output" || arg == "-o" || arg.starts_with("--output=") || arg.starts_with("-o=") {
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
    Ok(exit_code_from_status(&status, "az"))
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

    let combined = if stderr.is_empty() {
        raw.clone()
    } else {
        format!("{}\n{}", raw, stderr)
    };

    if !output.status.success() {
        timer.track(&cmd_label, &rtk_label, &combined, &stderr);
        eprintln!("{}", stderr.trim());
        return Ok(exit_code_from_output(&output, "az"));
    }

    let result = filter_fn(&raw).unwrap_or_else(|| FilterResult::new(raw.clone()));

    if result.truncated {
        if let Some(hint) = force_tee_hint(&combined, &slug) {
            println!("{}\n{}", result.text, hint);
        } else {
            println!("{}", result.text);
        }
    } else {
        println!("{}", result.text);
    }

    timer.track(&cmd_label, &rtk_label, &combined, &result.text);
    Ok(exit_code_from_output(&output, "az"))
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
        if arg == "--output" || arg == "-o" || arg.starts_with("--output=") || arg.starts_with("-o=") {
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
    use crate::core::utils::count_tokens;

    #[test]
    fn test_filter_build_list_single() {
        let json = r#"[{
            "id": 12345,
            "buildNumber": "2026.0410.1",
            "result": "succeeded",
            "status": "completed",
            "definition": {"name": "MyPipeline"},
            "sourceBranch": "refs/heads/main",
            "reason": "manual",
            "finishTime": "2026-04-10T12:00:00.000Z",
            "startTime": "2026-04-10T11:50:00.000Z"
        }]"#;
        let result = filter_build_list(json).unwrap();
        assert!(result.text.contains("ok 12345 #2026.0410.1"));
        assert!(result.text.contains("MyPipeline"));
        assert!(result.text.contains("succeeded"));
        assert!(result.text.contains("main"));
        assert!(result.text.contains("manual"));
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
            "reason": "pullRequest",
            "finishTime": "2026-04-10T12:00:00.000Z",
            "startTime": "2026-04-10T11:50:00.000Z"
        }]"#;
        let result = filter_build_list(json).unwrap();
        assert!(result.text.contains("FAIL 99 #1"));
        assert!(result.text.contains("42/merge"));
        assert!(result.text.contains("pullRequest"));
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
            "buildNumber": "2026.0410.1",
            "reason": "pullRequest",
            "requestedBy": {"displayName": "John Doe"},
            "sourceBranch": "refs/heads/main",
            "sourceVersion": "abc1234567890abcdef",
            "startTime": "2026-04-10T11:50:00.000Z",
            "finishTime": "2026-04-10T12:00:00.000Z"
        }"#;
        let result = filter_build_show(json).unwrap();
        assert!(result.text.starts_with("ok build 12345 | MyPipeline #2026.0410.1"));
        assert!(result.text.contains("branch: main"));
        assert!(result.text.contains("commit: abc1234"));
        assert!(result.text.contains("reason: pullRequest"));
        assert!(result.text.contains("by: John Doe"));
        assert!(result.text.contains("started: 2026-04-10"));
        assert!(result.text.contains("finished: 2026-04-10"));
        assert!(result.text.contains("(10m)"));
    }

    #[test]
    fn test_filter_timeline_with_failures() {
        let json = r#"{
            "records": [
                {
                    "name": "Build",
                    "type": "Stage",
                    "result": "succeeded",
                    "log": null,
                    "startTime": "2026-04-10T11:50:00.000Z",
                    "finishTime": "2026-04-10T11:52:30.000Z",
                    "errorCount": 0,
                    "warningCount": 0
                },
                {
                    "name": "Run Tests",
                    "type": "Task",
                    "result": "failed",
                    "log": {"id": 42},
                    "startTime": "2026-04-10T11:52:30.000Z",
                    "finishTime": "2026-04-10T11:55:30.000Z",
                    "errorCount": 3,
                    "warningCount": 1,
                    "issues": [{"message": "Process completed with exit code 1"}]
                },
                {
                    "name": "Publish Results",
                    "type": "Task",
                    "result": "failed",
                    "log": {"id": 43},
                    "startTime": "2026-04-10T11:55:30.000Z",
                    "finishTime": "2026-04-10T11:56:00.000Z",
                    "errorCount": 1,
                    "warningCount": 0,
                    "issues": [{"message": "No test results found"}]
                }
            ]
        }"#;
        let result = filter_timeline(json).unwrap();
        assert!(result.text.contains("FAIL timeline: 2 failed of 3 tasks"));
        assert!(result.text.contains("ok Build (Stage)"));
        assert!(result.text.contains("2m30s"));
        assert!(result.text.contains("FAIL Run Tests (Task) logId:42 3err 1warn"));
        assert!(result.text.contains("> Process completed with exit code 1"));
        assert!(result.text.contains("FAIL Publish Results (Task) logId:43 1err"));
        assert!(result.text.contains("> No test results found"));
    }

    #[test]
    fn test_filter_timeline_all_pass() {
        let json = r#"{
            "records": [
                {
                    "name": "Build",
                    "type": "Stage",
                    "result": "succeeded",
                    "log": null,
                    "startTime": "2026-04-10T11:50:00.000Z",
                    "finishTime": "2026-04-10T11:52:00.000Z"
                },
                {
                    "name": "Test",
                    "type": "Task",
                    "result": "succeeded",
                    "log": {"id": 1},
                    "startTime": "2026-04-10T11:52:00.000Z",
                    "finishTime": "2026-04-10T11:52:45.000Z"
                }
            ]
        }"#;
        let result = filter_timeline(json).unwrap();
        assert!(result.text.contains("ok timeline: 0 failed of 2 tasks"));
        assert!(result.text.contains("ok Build (Stage) 2m0s"));
        assert!(result.text.contains("ok Test (Task) 45s"));
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
        assert!(result.text.contains("Bearer"));
        assert!(result.text.contains("[eyJ0eXAiOi..."));
        assert!(result.text.contains("sub:sub-id"));
        assert!(result.text.contains("tenant:tenant-id"));
        assert!(result.text.contains("expires:2026-04-10"));
        // Must NOT contain the full token
        assert!(!result.text.contains("eyJ0eXAiOiJKV1QiLCJhbGci..."));
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

    // ─── Token Savings Tests ───────────────────────────────────────────────────

    #[test]
    fn test_build_list_token_savings() {
        let json = r#"[
            {
                "id": 12345,
                "buildNumber": "2026.0410.1",
                "result": "succeeded",
                "status": "completed",
                "definition": {
                    "id": 1,
                    "name": "CI Pipeline",
                    "path": "\\",
                    "project": {"name": "MyProject"},
                    "revision": 5
                },
                "sourceBranch": "refs/heads/main",
                "sourceVersion": "abc1234def5678901234567890123456789012",
                "finishTime": "2026-04-10T12:00:00.000Z",
                "startTime": "2026-04-10T11:50:00.000Z",
                "queueTime": "2026-04-10T11:49:00.000Z",
                "reason": "individualCI",
                "requestedBy": {
                    "displayName": "John Doe",
                    "id": "user-guid-1",
                    "uniqueName": "john@example.com"
                },
                "requestedFor": {
                    "displayName": "John Doe",
                    "id": "user-guid-1",
                    "uniqueName": "john@example.com"
                },
                "repository": {
                    "id": "repo-guid",
                    "name": "my-repo",
                    "type": "TfsGit",
                    "url": "https://dev.azure.com/org/project/_git/my-repo"
                },
                "logs": {
                    "id": 0,
                    "type": "Container",
                    "url": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs"
                },
                "url": "https://dev.azure.com/org/project/_apis/build/Builds/12345",
                "_links": {
                    "self": {"href": "https://dev.azure.com/org/project/_apis/build/Builds/12345"},
                    "web": {"href": "https://dev.azure.com/org/project/_build/results?buildId=12345"},
                    "sourceVersionDisplayUri": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/changes"}
                },
                "tags": [],
                "priority": "normal",
                "project": {
                    "id": "proj-guid",
                    "name": "MyProject",
                    "state": "wellFormed",
                    "visibility": "private"
                }
            },
            {
                "id": 12346,
                "buildNumber": "2026.0410.2",
                "result": "failed",
                "status": "completed",
                "definition": {
                    "id": 2,
                    "name": "Nightly Build",
                    "path": "\\",
                    "project": {"name": "MyProject"},
                    "revision": 3
                },
                "sourceBranch": "refs/heads/develop",
                "sourceVersion": "def5678abc1234901234567890123456789012",
                "finishTime": "2026-04-10T13:00:00.000Z",
                "startTime": "2026-04-10T12:30:00.000Z",
                "queueTime": "2026-04-10T12:29:00.000Z",
                "reason": "schedule",
                "requestedBy": {
                    "displayName": "Azure Pipelines",
                    "id": "system-guid",
                    "uniqueName": "system@example.com"
                },
                "requestedFor": {
                    "displayName": "Jane Smith",
                    "id": "user-guid-2",
                    "uniqueName": "jane@example.com"
                },
                "repository": {
                    "id": "repo-guid",
                    "name": "my-repo",
                    "type": "TfsGit",
                    "url": "https://dev.azure.com/org/project/_git/my-repo"
                },
                "logs": {
                    "id": 0,
                    "type": "Container",
                    "url": "https://dev.azure.com/org/project/_apis/build/builds/12346/logs"
                },
                "url": "https://dev.azure.com/org/project/_apis/build/Builds/12346",
                "_links": {
                    "self": {"href": "https://dev.azure.com/org/project/_apis/build/Builds/12346"},
                    "web": {"href": "https://dev.azure.com/org/project/_build/results?buildId=12346"},
                    "sourceVersionDisplayUri": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12346/changes"}
                },
                "tags": [],
                "priority": "normal",
                "project": {
                    "id": "proj-guid",
                    "name": "MyProject",
                    "state": "wellFormed",
                    "visibility": "private"
                }
            },
            {
                "id": 12347,
                "buildNumber": "2026.0410.3",
                "result": "canceled",
                "status": "completed",
                "definition": {
                    "id": 1,
                    "name": "CI Pipeline",
                    "path": "\\",
                    "project": {"name": "MyProject"},
                    "revision": 5
                },
                "sourceBranch": "refs/pull/42/merge",
                "sourceVersion": "ghi9012jkl3456789012345678901234567890",
                "finishTime": "2026-04-10T14:00:00.000Z",
                "startTime": "2026-04-10T13:50:00.000Z",
                "queueTime": "2026-04-10T13:49:00.000Z",
                "reason": "pullRequest",
                "requestedBy": {
                    "displayName": "Bob Wilson",
                    "id": "user-guid-3",
                    "uniqueName": "bob@example.com"
                },
                "requestedFor": {
                    "displayName": "Bob Wilson",
                    "id": "user-guid-3",
                    "uniqueName": "bob@example.com"
                },
                "repository": {
                    "id": "repo-guid",
                    "name": "my-repo",
                    "type": "TfsGit",
                    "url": "https://dev.azure.com/org/project/_git/my-repo"
                },
                "logs": {
                    "id": 0,
                    "type": "Container",
                    "url": "https://dev.azure.com/org/project/_apis/build/builds/12347/logs"
                },
                "url": "https://dev.azure.com/org/project/_apis/build/Builds/12347",
                "_links": {
                    "self": {"href": "https://dev.azure.com/org/project/_apis/build/Builds/12347"},
                    "web": {"href": "https://dev.azure.com/org/project/_build/results?buildId=12347"},
                    "sourceVersionDisplayUri": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12347/changes"}
                },
                "tags": ["pr-build"],
                "priority": "normal",
                "project": {
                    "id": "proj-guid",
                    "name": "MyProject",
                    "state": "wellFormed",
                    "visibility": "private"
                }
            }
        ]"#;

        let result = filter_build_list(json).unwrap();
        let input_tokens = count_tokens(json);
        let output_tokens = count_tokens(&result.text);
        let savings = 100.0 - (output_tokens as f64 / input_tokens as f64 * 100.0);

        assert!(
            savings >= 60.0,
            "build_list filter: expected ≥60% savings, got {:.1}%",
            savings
        );

        // Also verify output is not empty and contains key info
        assert!(!result.text.is_empty());
        assert!(result.text.contains("12345"));
        assert!(result.text.contains("CI Pipeline"));
    }

    #[test]
    fn test_build_show_token_savings() {
        let json = r#"{
            "id": 12345,
            "buildNumber": "2026.0410.1",
            "result": "succeeded",
            "status": "completed",
            "definition": {
                "id": 1,
                "name": "CI Pipeline",
                "path": "\\",
                "project": {"name": "MyProject"},
                "revision": 5
            },
            "sourceBranch": "refs/heads/main",
            "sourceVersion": "abc1234def5678901234567890123456789012",
            "finishTime": "2026-04-10T12:00:00.000Z",
            "startTime": "2026-04-10T11:50:00.000Z",
            "queueTime": "2026-04-10T11:49:00.000Z",
            "reason": "individualCI",
            "requestedBy": {
                "displayName": "John Doe",
                "id": "user-guid-1",
                "uniqueName": "john@example.com"
            },
            "requestedFor": {
                "displayName": "John Doe",
                "id": "user-guid-1",
                "uniqueName": "john@example.com"
            },
            "repository": {
                "id": "repo-guid",
                "name": "my-repo",
                "type": "TfsGit",
                "url": "https://dev.azure.com/org/project/_git/my-repo"
            },
            "logs": {
                "id": 0,
                "type": "Container",
                "url": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs"
            },
            "url": "https://dev.azure.com/org/project/_apis/build/Builds/12345",
            "_links": {
                "self": {"href": "https://dev.azure.com/org/project/_apis/build/Builds/12345"},
                "web": {"href": "https://dev.azure.com/org/project/_build/results?buildId=12345"},
                "sourceVersionDisplayUri": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/changes"}
            },
            "tags": [],
            "priority": "normal",
            "project": {
                "id": "proj-guid",
                "name": "MyProject",
                "state": "wellFormed",
                "visibility": "private"
            }
        }"#;

        let result = filter_build_show(json).unwrap();
        let input_tokens = count_tokens(json);
        let output_tokens = count_tokens(&result.text);
        let savings = 100.0 - (output_tokens as f64 / input_tokens as f64 * 100.0);

        assert!(
            savings >= 60.0,
            "build_show filter: expected ≥60% savings, got {:.1}%",
            savings
        );

        // Also verify output format
        assert!(result.text.contains("ok build 12345"));
        assert!(result.text.contains("CI Pipeline"));
    }

    #[test]
    fn test_timeline_token_savings() {
        let json = r#"{
            "records": [
                {
                    "id": "guid-1",
                    "name": "Initialize",
                    "type": "Task",
                    "result": "succeeded",
                    "state": "completed",
                    "order": 1,
                    "startTime": "2026-04-10T11:50:00.000Z",
                    "finishTime": "2026-04-10T11:50:30.000Z",
                    "log": {"id": 1, "url": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs/1"},
                    "errorCount": 0,
                    "warningCount": 0,
                    "workerName": "agent-1",
                    "percentComplete": 100,
                    "issues": [],
                    "_links": {
                        "self": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/Timeline/guid-1"},
                        "log": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs/1"}
                    },
                    "previousAttempts": [],
                    "parentId": "guid-0"
                },
                {
                    "id": "guid-2",
                    "name": "Build",
                    "type": "Task",
                    "result": "failed",
                    "state": "completed",
                    "order": 2,
                    "startTime": "2026-04-10T11:50:30.000Z",
                    "finishTime": "2026-04-10T11:52:00.000Z",
                    "log": {"id": 2, "url": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs/2"},
                    "errorCount": 5,
                    "warningCount": 2,
                    "workerName": "agent-1",
                    "percentComplete": 100,
                    "issues": [
                        {
                            "type": "error",
                            "message": "Build failed with exit code 1",
                            "data": {"sourcepath": "/src/main.rs"}
                        },
                        {
                            "type": "error",
                            "message": "Compilation errors found"
                        }
                    ],
                    "_links": {
                        "self": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/Timeline/guid-2"},
                        "log": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs/2"}
                    },
                    "previousAttempts": [],
                    "parentId": "guid-0"
                },
                {
                    "id": "guid-3",
                    "name": "Test",
                    "type": "Task",
                    "result": "succeeded",
                    "state": "completed",
                    "order": 3,
                    "startTime": "2026-04-10T11:52:00.000Z",
                    "finishTime": "2026-04-10T11:54:00.000Z",
                    "log": {"id": 3, "url": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs/3"},
                    "errorCount": 0,
                    "warningCount": 0,
                    "workerName": "agent-1",
                    "percentComplete": 100,
                    "issues": [],
                    "_links": {
                        "self": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/Timeline/guid-3"},
                        "log": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs/3"}
                    },
                    "previousAttempts": [],
                    "parentId": "guid-0"
                },
                {
                    "id": "guid-4",
                    "name": "Publish",
                    "type": "Task",
                    "result": "failed",
                    "state": "completed",
                    "order": 4,
                    "startTime": "2026-04-10T11:54:00.000Z",
                    "finishTime": "2026-04-10T11:54:10.000Z",
                    "log": {"id": 4, "url": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs/4"},
                    "errorCount": 1,
                    "warningCount": 0,
                    "workerName": "agent-1",
                    "percentComplete": 100,
                    "issues": [
                        {
                            "type": "error",
                            "message": "No artifacts found to publish"
                        }
                    ],
                    "_links": {
                        "self": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/Timeline/guid-4"},
                        "log": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/logs/4"}
                    },
                    "previousAttempts": [],
                    "parentId": "guid-0"
                },
                {
                    "id": "guid-5",
                    "name": "Deploy",
                    "type": "Stage",
                    "result": "succeeded",
                    "state": "completed",
                    "order": 5,
                    "startTime": "2026-04-10T11:54:10.000Z",
                    "finishTime": "2026-04-10T11:56:00.000Z",
                    "log": null,
                    "errorCount": 0,
                    "warningCount": 0,
                    "workerName": "agent-1",
                    "percentComplete": 100,
                    "issues": [],
                    "_links": {
                        "self": {"href": "https://dev.azure.com/org/project/_apis/build/builds/12345/Timeline/guid-5"}
                    },
                    "previousAttempts": [],
                    "parentId": "guid-0"
                }
            ]
        }"#;

        let result = filter_timeline(json).unwrap();
        let input_tokens = count_tokens(json);
        let output_tokens = count_tokens(&result.text);
        let savings = 100.0 - (output_tokens as f64 / input_tokens as f64 * 100.0);

        assert!(
            savings >= 60.0,
            "timeline filter: expected ≥60% savings, got {:.1}%",
            savings
        );

        // Verify output contains key info
        assert!(result.text.contains("FAIL timeline: 2 failed of 5 tasks"));
        assert!(result.text.contains("FAIL Build"));
        assert!(result.text.contains("FAIL Publish"));
    }

    #[test]
    fn test_logs_token_savings() {
        // Create a fixture with 100 log lines with ISO timestamp prefixes
        let mut log_lines = Vec::new();
        for i in 0..100 {
            log_lines.push(format!(
                "\"2026-04-10T11:{:02}:{:02}.0000000Z ##[section]Log line {} with some typical build output content that goes here\"",
                i / 60, i % 60, i + 1
            ));
        }
        let json = format!(r#"{{ "value": [{}] }}"#, log_lines.join(",\n        "));

        let result = filter_logs(&json).unwrap();
        let input_tokens = count_tokens(&json);
        let output_tokens = count_tokens(&result.text);
        let savings = 100.0 - (output_tokens as f64 / input_tokens as f64 * 100.0);

        // Logs savings are lower because content is preserved, mainly timestamps stripped
        assert!(
            savings >= 40.0,
            "logs filter: expected ≥40% savings, got {:.1}%",
            savings
        );

        // Verify truncation and timestamp removal
        assert!(result.text.contains("(100 lines total, showing last 50)"));
        assert!(!result.text.contains("2026-04-10T"));
    }

    #[test]
    fn test_access_token_token_savings() {
        let long_token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiIsIng1dCI6InEtTWpOVjN1YnF0bHFLZzFNdGRDVjVIdW1qYyIsImtpZCI6InEtTWpOVjN1YnF0bHFLZzFNdGRDVjVIdW1qYyJ9eyJhdWQiOiJodHRwczovL21hbmFnZW1lbnQuY29yZS53aW5kb3dzLm5ldC8iLCJpc3MiOiJodHRwczovL3N0cy53aW5kb3dzLm5ldC8xMjM0NTY3OC0xMjM0LTEyMzQtMTIzNC0xMjM0NTY3ODkwYWIvIiwiaWF0IjoxNzEwMDAwMDAwLCJuYmYiOjE3MTAwMDAwMDAsImV4cCI6MTcxMDAwMzYwMCwiYWlvIjoiRTJaZ1lIanIxWVgvMy90cC82bjlPZnovQitHQUE9PSIsImFwcGlkIjoiYXBwaWQtZ3VpZCIsImFwcGlkYWNyIjoiMSIsImlkcCI6Imh0dHBzOi8vc3RzLndpbmRvd3MubmV0L3RlbmFudC1ndWlkLyIsIm9pZCI6Im9pZC1ndWlkIiwicmgiOiIwLkFYQUFsNlFfb1hlZ0JrZUcxX0lULWdoalFGVEFBQUFBQUFBQXdBQUFBQUFBQUFBQUFBQS4iLCJzdWIiOiJzdWItZ3VpZCIsInRpZCI6ImUzZjNhNDk3LWE3NzctNDg2Ny04NmQ3ZjIxM2ZhMDg2MyIsInV0aSI6ImI3RGtCakdLT2s2OWhUMGozRTNmQUEiLCJ2ZXIiOiIxLjAiLCJ4bXNfdGNkdCI6MTYzOTI0NTk5OH0=";

        let json = format!(r#"{{
            "accessToken": "{}",
            "expiresOn": "2026-04-10T13:00:00.000000+00:00",
            "expires_on": 1781362800,
            "subscription": "12345678-1234-1234-1234-123456789abc",
            "tenant": "abcdef01-2345-6789-abcd-ef0123456789",
            "tokenType": "Bearer",
            "environmentName": "AzureCloud"
        }}"#, long_token);

        let result = filter_access_token(&json).unwrap();
        let input_tokens = count_tokens(&json);
        let output_tokens = count_tokens(&result.text);
        let savings = 100.0 - (output_tokens as f64 / input_tokens as f64 * 100.0);

        // Token filter's primary value is security (masking), not maximum savings
        // Token is masked to ~10 chars, but other metadata is preserved
        assert!(
            savings >= 40.0,
            "access_token filter: expected ≥40% savings, got {:.1}%",
            savings
        );

        // Verify token is masked
        assert!(result.text.contains("Bearer"));
        assert!(!result.text.contains(long_token));
    }

    // ─── Edge Case Tests ────────────────────────────────────────────────────────

    #[test]
    fn test_build_list_partially_succeeded() {
        let json = r#"[{
            "id": 12345,
            "buildNumber": "2026.0410.1",
            "result": "partiallySucceeded",
            "status": "completed",
            "definition": {"name": "MyPipeline"},
            "sourceBranch": "refs/heads/main",
            "reason": "manual",
            "finishTime": "2026-04-10T12:00:00.000Z"
        }]"#;
        let result = filter_build_list(json).unwrap();
        // partiallySucceeded falls through to "?" icon
        assert!(result.text.contains("? 12345"));
        assert!(result.text.contains("partiallySucceeded"));
    }

    #[test]
    fn test_timeline_failed_no_issues() {
        let json = r#"{
            "records": [
                {
                    "name": "Build",
                    "type": "Task",
                    "result": "failed",
                    "log": {"id": 42},
                    "startTime": "2026-04-10T11:50:00.000Z",
                    "finishTime": "2026-04-10T11:52:00.000Z",
                    "errorCount": 0,
                    "warningCount": 0
                }
            ]
        }"#;
        // Should NOT crash even without issues array
        let result = filter_timeline(json).unwrap();
        assert!(result.text.contains("FAIL Build (Task) logId:42"));
        assert!(!result.text.contains(">"));
    }

    #[test]
    fn test_timeline_failed_empty_issues() {
        let json = r#"{
            "records": [
                {
                    "name": "Build",
                    "type": "Task",
                    "result": "failed",
                    "log": {"id": 42},
                    "startTime": "2026-04-10T11:50:00.000Z",
                    "finishTime": "2026-04-10T11:52:00.000Z",
                    "errorCount": 0,
                    "warningCount": 0,
                    "issues": []
                }
            ]
        }"#;
        // Should NOT crash with empty issues array
        let result = filter_timeline(json).unwrap();
        assert!(result.text.contains("FAIL Build (Task) logId:42"));
        assert!(!result.text.contains(">"));
    }

    #[test]
    fn test_build_show_unicode() {
        let json = r#"{
            "id": 12345,
            "result": "succeeded",
            "status": "completed",
            "definition": {"name": "MyPipeline"},
            "buildNumber": "2026.0410.1",
            "reason": "pullRequest",
            "requestedBy": {"displayName": "田中太郎"},
            "sourceBranch": "refs/heads/feature/日本語",
            "sourceVersion": "abc1234567890abcdef",
            "startTime": "2026-04-10T11:50:00.000Z",
            "finishTime": "2026-04-10T12:00:00.000Z"
        }"#;
        let result = filter_build_show(json).unwrap();
        // Must not crash or corrupt output
        assert!(result.text.contains("田中太郎"));
        assert!(result.text.contains("feature/日本語"));
    }

    #[test]
    fn test_build_show_null_fields() {
        // Build JSON where key fields are missing entirely
        let json = r#"{
            "id": 12345,
            "result": "succeeded",
            "status": "completed",
            "definition": {"name": "MyPipeline"}
        }"#;
        let result = filter_build_show(json).unwrap();
        // All missing fields should gracefully fall back to "?"
        assert!(result.text.contains("ok build 12345"));
        assert!(result.text.contains("MyPipeline #?"));
        assert!(result.text.contains("branch: ?"));
        assert!(result.text.contains("commit: ?"));
        assert!(result.text.contains("reason: ?"));
        assert!(result.text.contains("by: ?"));
    }

    #[test]
    fn test_build_list_truncation() {
        // Create 25 builds (more than MAX_ITEMS=20)
        let mut builds = Vec::new();
        for i in 1..=25 {
            builds.push(format!(
                r#"{{
                    "id": {},
                    "buildNumber": "2026.0410.{}",
                    "result": "succeeded",
                    "status": "completed",
                    "definition": {{"name": "Pipeline"}},
                    "sourceBranch": "refs/heads/main",
                    "reason": "manual",
                    "finishTime": "2026-04-10T12:00:00.000Z"
                }}"#,
                i, i
            ));
        }
        let json = format!("[{}]", builds.join(",\n"));

        let result = filter_build_list(&json).unwrap();
        // Should be truncated and show +5 more
        assert!(result.truncated);
        assert!(result.text.contains("... +5 more builds"));
    }

    #[test]
    fn test_logs_exact_tail() {
        // Create exactly 50 lines (LOG_TAIL_LINES)
        let mut log_lines = Vec::new();
        for i in 0..50 {
            log_lines.push(format!(
                "\"2026-04-10T11:{:02}:{:02}.0000000Z Log line {}\"",
                i / 60, i % 60, i + 1
            ));
        }
        let json = format!(r#"{{ "value": [{}] }}"#, log_lines.join(",\n"));

        let result = filter_logs(&json).unwrap();
        // Should NOT show truncation header with exactly 50 lines
        assert!(!result.truncated);
        assert!(!result.text.contains("lines total"));
        // Should show all 50 lines
        assert!(result.text.contains("Log line 1"));
        assert!(result.text.contains("Log line 50"));
    }

    #[test]
    fn test_access_token_missing_fields() {
        // Token JSON with only accessToken — no other fields
        let json = r#"{"accessToken": "eyJ0eXAiOiJKV1QiLCJhbGci..."}"#;
        let result = filter_access_token(json).unwrap();
        // Should show "?" for missing fields
        assert!(result.text.contains("Bearer")); // default tokenType
        assert!(result.text.contains("sub:?"));
        assert!(result.text.contains("tenant:?"));
        assert!(result.text.contains("expires:?"));
    }

    #[test]
    fn test_all_filters_invalid_json() {
        let invalid = "not valid json";

        // All filters should return None (not panic)
        assert!(filter_build_list(invalid).is_none());
        assert!(filter_build_show(invalid).is_none());
        assert!(filter_timeline(invalid).is_none());
        assert!(filter_logs(invalid).is_none());
        assert!(filter_access_token(invalid).is_none());
    }
}
