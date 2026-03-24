use std::{
    collections::HashMap,
    env,
    path::{Path, PathBuf},
    process::Stdio,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
};

use rfd::FileDialog;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{ChildStdin, Command},
    sync::{oneshot, Mutex},
    time::{timeout, Duration},
};

static REQUEST_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Clone)]
struct BackendState {
    inner: Arc<BackendInner>,
}

struct BackendInner {
    stdin: Mutex<ChildStdin>,
    child: Mutex<tokio::process::Child>,
    pending: Mutex<HashMap<String, oneshot::Sender<Result<Value, String>>>>,
}

impl BackendState {
    async fn send(&self, command: &str, args: Value) -> Result<Value, String> {
        let request_id = REQUEST_COUNTER.fetch_add(1, Ordering::Relaxed).to_string();
        let payload = json!({
            "kind": "command",
            "id": request_id,
            "command": command,
            "payload": args,
        });
        let line = serde_json::to_string(&payload).map_err(|error| error.to_string())?;
        let (sender, receiver) = oneshot::channel();

        {
            let mut pending = self.inner.pending.lock().await;
            pending.insert(request_id.clone(), sender);
        }

        {
            let mut stdin = self.inner.stdin.lock().await;
            stdin
                .write_all(line.as_bytes())
                .await
                .map_err(|error| error.to_string())?;
            stdin.write_all(b"\n").await.map_err(|error| error.to_string())?;
            stdin.flush().await.map_err(|error| error.to_string())?;
        }

        receiver
            .await
            .map_err(|_| "Python backend 連線中斷".to_string())?
    }

    async fn shutdown(&self) {
        let _ = self.send("shutdown", json!({})).await;
        let mut child = self.inner.child.lock().await;
        let _ = child.kill().await;
    }
}

fn dev_repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

fn bundled_root(resource_dir: &Path) -> PathBuf {
    let nested = resource_dir.join("_up_").join("_up_").join("_up_");
    if nested.exists() {
        nested
    } else {
        resource_dir.to_path_buf()
    }
}

fn find_ffmpeg_binary(bundled_root: Option<&Path>) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Some(root) = bundled_root {
        candidates.push(root.join("desktop/runtime/bin/ffmpeg"));
        candidates.push(root.join("desktop/runtime/python/bin/ffmpeg"));
    }

    candidates.push(PathBuf::from("/opt/homebrew/bin/ffmpeg"));
    candidates.push(PathBuf::from("/usr/local/bin/ffmpeg"));

    candidates.into_iter().find(|path| path.exists())
}

fn build_backend_path_env(python_bin: &Path, ffmpeg_bin: Option<&Path>) -> String {
    let mut paths: Vec<PathBuf> = Vec::new();

    if let Some(parent) = python_bin.parent() {
        paths.push(parent.to_path_buf());
    }
    if let Some(bin) = ffmpeg_bin.and_then(|path| path.parent()) {
        paths.push(bin.to_path_buf());
    }
    if let Some(lib) = python_bin.parent().and_then(|path| path.parent()).map(|path| path.join("lib")) {
        if lib.exists() {
            paths.push(lib);
        }
    }

    if let Some(existing) = env::var_os("PATH") {
        paths.extend(env::split_paths(&existing));
    } else {
        paths.push(PathBuf::from("/opt/homebrew/bin"));
        paths.push(PathBuf::from("/usr/local/bin"));
        paths.push(PathBuf::from("/usr/bin"));
        paths.push(PathBuf::from("/bin"));
    }

    env::join_paths(paths)
        .unwrap_or_default()
        .to_string_lossy()
        .to_string()
}

fn resolve_python_and_backend(app: &AppHandle) -> Result<(PathBuf, PathBuf, Option<PathBuf>), String> {
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|error| error.to_string())?;

    let bundled_root = bundled_root(&resource_dir);
    let bundled_python = bundled_root.join("desktop/runtime/python/bin/python3");
    let bundled_backend = bundled_root.join("desktop/python_backend.py");
    if bundled_python.exists() && bundled_backend.exists() {
        return Ok((bundled_python, bundled_backend, Some(bundled_root.join("desktop/runtime/python"))));
    }

    let dev_root = dev_repo_root();
    let dev_python = dev_root.join("venv/bin/python");
    let dev_backend = dev_root.join("desktop/python_backend.py");
    if dev_python.exists() && dev_backend.exists() {
        return Ok((dev_python, dev_backend, None));
    }

    Err("找不到桌面版 Python runtime 或 backend 腳本".to_string())
}

async fn spawn_backend(app: AppHandle) -> Result<BackendState, String> {
    let (python_bin, backend_script, bundled_python_home) = resolve_python_and_backend(&app)?;
    let bundled_root = bundled_python_home
        .as_ref()
        .and_then(|path| path.parent())
        .and_then(|path| path.parent())
        .map(Path::to_path_buf);
    let ffmpeg_bin = find_ffmpeg_binary(bundled_root.as_deref());
    let backend_dir = backend_script
        .parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| "無法判斷 backend 腳本路徑".to_string())?;

    let mut command = Command::new(&python_bin);
    command
        .arg(&backend_script)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .current_dir(backend_dir);

    let mut dyld_paths: Vec<PathBuf> = Vec::new();

    if let Some(python_home) = bundled_python_home {
        let site_packages = python_home.join("lib").join("python3.10").join("site-packages");
        command.env("PYTHONHOME", &python_home);
        command.env("PYTHONPATH", site_packages);
        command.env("PYTHONNOUSERSITE", "1");
        dyld_paths.push(python_home.join("lib"));
    }

    command.env("PATH", build_backend_path_env(&python_bin, ffmpeg_bin.as_deref()));
    if let Some(path) = ffmpeg_bin {
        command.env("FFMPEG_BINARY", &path);
        command.env("IMAGEIO_FFMPEG_EXE", &path);
        if let Some(lib_dir) = path.parent().and_then(|bin| bin.parent()).map(|root| root.join("lib")) {
            dyld_paths.push(lib_dir);
        }
    }

    if !dyld_paths.is_empty() {
        let existing = env::var_os("DYLD_LIBRARY_PATH")
            .map(|value| env::split_paths(&value).collect::<Vec<_>>())
            .unwrap_or_default();
        dyld_paths.extend(existing);
        let joined = env::join_paths(dyld_paths).unwrap_or_default();
        command.env("DYLD_LIBRARY_PATH", joined);
    }

    let mut child = command.spawn().map_err(|error| error.to_string())?;

    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| "無法取得 backend stdin".to_string())?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "無法取得 backend stdout".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "無法取得 backend stderr".to_string())?;

    let state = BackendState {
        inner: Arc::new(BackendInner {
            stdin: Mutex::new(stdin),
            child: Mutex::new(child),
            pending: Mutex::new(HashMap::new()),
        }),
    };

    let stdout_state = state.clone();
    let stdout_app = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut reader = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = reader.next_line().await {
            match serde_json::from_str::<Value>(&line) {
                Ok(payload) => {
                    let kind = payload.get("kind").and_then(Value::as_str).unwrap_or_default();
                    if kind == "response" {
                        let request_id = payload
                            .get("request_id")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string();
                        let mut pending = stdout_state.inner.pending.lock().await;
                        if let Some(sender) = pending.remove(&request_id) {
                            let result = if payload.get("ok").and_then(Value::as_bool).unwrap_or(false) {
                                Ok(payload.get("result").cloned().unwrap_or(Value::Null))
                            } else {
                                Err(match payload.get("error") {
                                    Some(Value::String(message)) => message.to_string(),
                                    Some(Value::Object(object)) => object
                                        .get("message")
                                        .and_then(Value::as_str)
                                        .unwrap_or("未知錯誤")
                                        .to_string(),
                                    _ => "未知錯誤".to_string(),
                                })
                            };
                            let _ = sender.send(result);
                        }
                    } else if kind == "event" {
                        let _ = stdout_app.emit("backend://event", payload);
                    } else {
                        let _ = stdout_app.emit(
                            "backend://event",
                            json!({
                                "event": "backend_error",
                                "data": {"message": format!("未知 backend 訊息: {line}")},
                            }),
                        );
                    }
                }
                Err(error) => {
                    let _ = stdout_app.emit(
                        "backend://event",
                        json!({
                            "event": "backend_error",
                            "data": {"message": format!("無法解析 backend 訊息: {error}")},
                        }),
                    );
                }
            }
        }
    });

    let stderr_app = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut reader = BufReader::new(stderr).lines();
        while let Ok(Some(line)) = reader.next_line().await {
            let text = line.trim();
            if text.is_empty() {
                continue;
            }
            let _ = stderr_app.emit(
                "backend://event",
                json!({
                    "event": "backend_error",
                    "data": {"message": text},
                }),
            );
        }
    });

    Ok(state)
}

async fn backend_call(
    state: &BackendState,
    command: &str,
    args: Value,
) -> Result<Value, String> {
    state.send(command, args).await
}

#[tauri::command]
async fn backend_command(
    command: String,
    args: Value,
    state: State<'_, BackendState>,
) -> Result<Value, String> {
    backend_call(&state, &command, args).await
}

fn escape_applescript_string(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

async fn run_osascript(lines: &[String]) -> Result<Option<String>, String> {
    let mut command = Command::new("/usr/bin/osascript");
    for line in lines {
        command.arg("-e").arg(line);
    }

    let output = timeout(Duration::from_secs(45), command.output())
        .await
        .map_err(|_| "選檔視窗逾時，可能被系統擋在其他桌面或沒有成功彈出".to_string())?
        .map_err(|error| error.to_string())?;
    if output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if stdout.is_empty() {
            Ok(None)
        } else {
            Ok(Some(stdout))
        }
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let combined = if stderr.is_empty() {
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        } else {
            stderr
        };
        if combined.contains("User canceled") || combined.contains("(-128)") {
            Ok(None)
        } else {
            Err(if combined.is_empty() {
                "macOS 選擇視窗執行失敗".to_string()
            } else {
                combined
            })
        }
    }
}

#[tauri::command]
async fn pick_audio_files_b() -> Result<Vec<String>, String> {
    let script = vec![
        r#"tell application id "com.minrui.zhuzigaoding" to activate"#.to_string(),
        r#"delay 0.1"#.to_string(),
        r#"set chosenFiles to choose file with prompt "選取音訊檔" with multiple selections allowed"#.to_string(),
        r#"set outputLines to {}"#.to_string(),
        r#"repeat with aFile in chosenFiles"#.to_string(),
        r#"set end of outputLines to POSIX path of aFile"#.to_string(),
        r#"end repeat"#.to_string(),
        r#"set AppleScript's text item delimiters to linefeed"#.to_string(),
        r#"return outputLines as text"#.to_string(),
    ];

    let stdout = run_osascript(&script).await?;
    Ok(stdout
        .map(|text| {
            text.lines()
                .map(str::trim)
                .filter(|line| !line.is_empty())
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default())
}

#[tauri::command]
async fn pick_audio_files_a() -> Result<Vec<String>, String> {
    let files = FileDialog::new()
        .add_filter("audio", &["mp3", "wav", "m4a", "flac", "ogg", "aac", "wma"])
        .pick_files();
    Ok(files
        .unwrap_or_default()
        .into_iter()
        .map(|path| path.display().to_string())
        .collect())
}

#[tauri::command]
async fn pick_audio_files() -> Result<Vec<String>, String> {
    pick_audio_files_b().await
}

#[tauri::command]
async fn pick_save_result_path(suggested_filename: String) -> Result<Option<String>, String> {
    let escaped_name = escape_applescript_string(&suggested_filename);
    let script = vec![
        r#"tell application id "com.minrui.zhuzigaoding" to activate"#.to_string(),
        r#"delay 0.1"#.to_string(),
        format!(
            r#"set targetFile to choose file name with prompt "儲存逐字稿" default name "{}""#,
            escaped_name
        ),
        r#"return POSIX path of targetFile"#.to_string(),
    ];
    run_osascript(&script).await
}

#[tauri::command]
async fn pick_save_all_results_path() -> Result<Option<String>, String> {
    let script = vec![
        r#"tell application id "com.minrui.zhuzigaoding" to activate"#.to_string(),
        r#"delay 0.1"#.to_string(),
        r#"set targetFile to choose file name with prompt "儲存全部結果" default name "transcripts.zip""#.to_string(),
        r#"return POSIX path of targetFile"#.to_string(),
    ];
    run_osascript(&script).await
}

fn ensure_path(path: &Path) -> Result<(), String> {
    if path.exists() {
        Ok(())
    } else {
        Err(format!("找不到必要路徑: {}", path.display()))
    }
}

fn main() {
    let app = tauri::Builder::default()
        .setup(|app| {
            let dev_root = dev_repo_root();
            let _ = ensure_path(&dev_root.join("desktop/python_backend.py"));

            let backend = tauri::async_runtime::block_on(spawn_backend(app.handle().clone()))?;
            app.manage(backend);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            backend_command,
            pick_audio_files_a,
            pick_audio_files_b,
            pick_audio_files,
            pick_save_result_path,
            pick_save_all_results_path
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| {
        if let tauri::RunEvent::ExitRequested { .. } = event {
            if let Some(state) = app_handle.try_state::<BackendState>() {
                tauri::async_runtime::block_on(state.shutdown());
            }
        }
    });
}
