use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::net::{SocketAddr, TcpStream};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use tauri::{Manager, RunEvent, Url, WebviewUrl, WebviewWindowBuilder};

struct Backend {
    child: Mutex<Option<ChildHandle>>,
}

struct ChildHandle {
    child: Child,
    pgid: i32,
}

fn log(msg: &str) {
    eprintln!("{msg}");
    let path = std::env::var("ZCODE_TAURI_LOG").unwrap_or_else(|_| "/tmp/zcode-tauri.log".into());
    // O_NOFOLLOW prevents a pre-created symlink in /tmp from redirecting our
    // append into another file; create logs 0600.
    let mut opts = OpenOptions::new();
    opts.create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW);
    if let Ok(mut f) = opts.open(path) {
        let _ = writeln!(f, "{msg}");
    }
}

fn is_loopback_url(url: &Url) -> bool {
    match url.host() {
        Some(url::Host::Domain(d)) => d.eq_ignore_ascii_case("localhost"),
        Some(url::Host::Ipv4(ip)) => ip.is_loopback(),
        Some(url::Host::Ipv6(ip)) => ip.is_loopback(),
        None => false,
    }
}

fn parse_local_url(line: &str) -> Option<Url> {
    let start = line.find("http://")?;
    let raw = line[start..].split_whitespace().next()?;
    let raw = raw.trim_end_matches(|c: char| matches!(c, ',' | ';' | ')' | '"' | '\'' | '.'));
    let url = Url::parse(raw).ok()?;
    match url.host_str() {
        Some("127.0.0.1") | Some("localhost") | Some("::1") => Some(url),
        _ => None,
    }
}

fn kill_group(pgid: i32, child: &mut Child) {
    if pgid > 1 {
        unsafe {
            libc::kill(-pgid, libc::SIGTERM);
        }
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => {}
            Err(_) => return,
        }
        if Instant::now() >= deadline {
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    if pgid > 1 {
        unsafe {
            libc::kill(-pgid, libc::SIGKILL);
        }
    }
    let _ = child.wait();
}

fn wait_tcp(url: &Url, timeout: Duration) -> bool {
    let addrs: Vec<SocketAddr> = match url.socket_addrs(|| None) {
        Ok(v) if !v.is_empty() => v,
        _ => return false,
    };
    let deadline = Instant::now() + timeout;
    loop {
        for addr in &addrs {
            if TcpStream::connect_timeout(addr, Duration::from_millis(400)).is_ok() {
                return true;
            }
        }
        if Instant::now() >= deadline {
            return false;
        }
        thread::sleep(Duration::from_millis(150));
    }
}

/// Spawn `zcode --web --no-open`, parse its dynamic loopback URL from stdout.
fn spawn_backend() -> Result<(ChildHandle, Url), String> {
    let bin = std::env::var("ZCODE_BIN").unwrap_or_else(|_| "/usr/local/bin/zcode".into());
    let mut cmd = Command::new(&bin);
    cmd.args(["--web", "--no-open"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // Own process group so that ZCode and any helpers can be stopped together.
    cmd.process_group(0);
    // If this shell dies unexpectedly, ask the kernel to terminate the backend too.
    unsafe {
        cmd.pre_exec(|| {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
            Ok(())
        });
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("failed to spawn {bin}: {e}"))?;
    let pgid = child.id() as i32;
    log(&format!("[zcode-tauri] spawned {bin} (pid {pgid})"));

    let stdout = child.stdout.take().ok_or("no stdout pipe")?;
    let stderr = child.stderr.take().ok_or("no stderr pipe")?;

    let (tx, rx) = mpsc::channel::<String>();
    thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = tx.send(line);
        }
    });
    thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            log(&format!("[zcode] {line}"));
        }
    });

    let deadline = Instant::now() + Duration::from_secs(30);
    let mut found: Option<Url> = None;
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            let mut c = child;
            kill_group(pgid, &mut c);
            return Err(format!("zcode exited before reporting URL: {status}"));
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match rx.recv_timeout(remaining.min(Duration::from_millis(500))) {
            Ok(line) => {
                if let Some(url) = parse_local_url(&line) {
                    log(&format!("[zcode-tauri] detected web URL: {url}"));
                    found = Some(url);
                    break;
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    let url = match found {
        Some(u) => u,
        None => {
            let mut c = child;
            kill_group(pgid, &mut c);
            return Err("timed out after 30s waiting for zcode web URL on stdout".into());
        }
    };

    if !wait_tcp(&url, Duration::from_secs(30)) {
        let mut c = child;
        kill_group(pgid, &mut c);
        return Err(format!("zcode reported {url} but the port never accepted TCP"));
    }
    log(&format!("[zcode-tauri] backend ready at {url}"));

    Ok((
        ChildHandle {
            child,
            pgid,
        },
        url,
    ))
}

fn build_window(app: &mut tauri::App, url: Url) -> Result<(), tauri::Error> {
    WebviewWindowBuilder::new(app, "main", WebviewUrl::External(url))
        .title("ZCode")
        .inner_size(1200.0, 800.0)
        .min_inner_size(800.0, 600.0)
        .build()?;
    Ok(())
}

fn build_error_window(app: &mut tauri::App) -> Result<(), tauri::Error> {
    WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .title("ZCode - 后端启动失败")
        .inner_size(900.0, 600.0)
        .build()?;
    Ok(())
}

fn stop_backend(app: &tauri::AppHandle) {
    if let Some(state) = app.try_state::<Backend>() {
        let mut guard = state.child.lock().unwrap();
        if let Some(mut handle) = guard.take() {
            log(&format!(
                "[zcode-tauri] stopping zcode process group {}",
                handle.pgid
            ));
            kill_group(handle.pgid, &mut handle.child);
        }
    }
}

fn main() {
    let app = tauri::Builder::default()
        .setup(|app| {
            let attach = std::env::var("ZCODE_WEB_URL").ok();
            let started = match attach {
                Some(raw) => match Url::parse(&raw) {
                    Ok(url) if !is_loopback_url(&url) => {
                        Err(format!("ZCODE_WEB_URL must be loopback: {url}"))
                    }
                    Ok(url) if wait_tcp(&url, Duration::from_secs(10)) => {
                        log(&format!("[zcode-tauri] attaching to existing {url}"));
                        Ok((None, url))
                    }
                    Ok(url) => Err(format!("ZCODE_WEB_URL={url} is not accepting TCP")),
                    Err(e) => Err(format!("invalid ZCODE_WEB_URL: {e}")),
                },
                None => spawn_backend().map(|(h, u)| (Some(h), u)),
            };

            match started {
                Ok((handle, url)) => {
                    app.manage(Backend {
                        child: Mutex::new(handle),
                    });
                    if let Err(e) = build_window(app, url) {
                        log(&format!("[zcode-tauri] window creation failed: {e}"));
                        stop_backend(app.handle());
                        if let Err(e2) = build_error_window(app) {
                            log(&format!("[zcode-tauri] error window failed: {e2}"));
                        }
                    }
                }
                Err(e) => {
                    log(&format!("[zcode-tauri] backend startup failed: {e}"));
                    app.manage(Backend {
                        child: Mutex::new(None),
                    });
                    if let Err(e2) = build_error_window(app) {
                        log(&format!("[zcode-tauri] error window failed: {e2}"));
                    }
                }
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                // Stop the backend before the webview is torn down.
                stop_backend(window.app_handle());
            }
        })
        .build(tauri::generate_context!())
        .expect("failed to build Tauri application");

    app.run(|app_handle, event| {
        if matches!(event, RunEvent::Exit | RunEvent::ExitRequested { .. }) {
            stop_backend(app_handle);
        }
    });
}
