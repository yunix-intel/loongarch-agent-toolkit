package main

// indexHTML is the entire web UI. It is embedded so the binary is a single
// self-contained file with no external assets, fonts or CDNs.
const indexHTML = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ccswitch-lite</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0e1116;
    --panel: #161b22;
    --panel2: #1c2230;
    --border: #2a3140;
    --text: #e6edf3;
    --muted: #8b98a9;
    --accent: #d97757;
    --accent2: #e8956f;
    --ok: #3fb950;
    --danger: #f85149;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: radial-gradient(1200px 500px at 20% -10%, #1b2434 0%, var(--bg) 55%);
    color: var(--text); font: 14px/1.55 "Segoe UI", "Noto Sans CJK SC", "PingFang SC", system-ui, sans-serif;
    min-height: 100vh;
  }
  header {
    display: flex; align-items: baseline; gap: 14px; padding: 22px 28px 10px;
    max-width: 1180px; margin: 0 auto;
  }
  header h1 { font-size: 22px; margin: 0; letter-spacing: .3px; }
  header h1 span { color: var(--accent); }
  #currentBadge { color: var(--muted); font-size: 13px; }
  main { max-width: 1180px; margin: 0 auto; padding: 10px 28px 60px; }
  .toolbar { display: flex; gap: 10px; flex-wrap: wrap; margin: 12px 0 20px; }
  button {
    cursor: pointer; border: 1px solid var(--border); background: var(--panel2); color: var(--text);
    padding: 8px 14px; border-radius: 8px; font-size: 13px; transition: .15s;
  }
  button:hover { border-color: #3d4757; background: #222a39; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #1b120e; font-weight: 600; }
  button.primary:hover { background: var(--accent2); }
  button.danger { color: var(--danger); }
  button.subtle { background: transparent; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(330px, 1fr)); gap: 14px; }
  .card {
    background: linear-gradient(180deg, var(--panel), #141924); border: 1px solid var(--border);
    border-radius: 12px; padding: 16px 16px 14px; position: relative; overflow: hidden;
  }
  .card.active { border-color: var(--accent); box-shadow: 0 0 0 1px rgba(217,119,87,.25), 0 8px 28px rgba(0,0,0,.3); }
  .card h3 { margin: 0 0 4px; font-size: 16px; display: flex; align-items: center; gap: 8px; }
  .pill { font-size: 11px; border: 1px solid var(--border); border-radius: 999px; padding: 1px 8px; color: var(--muted); }
  .pill.on { color: var(--accent); border-color: var(--accent); }
  .kv { color: var(--muted); font-size: 12px; margin: 2px 0; word-break: break-all; }
  .kv b { color: var(--text); font-weight: 500; }
  .models { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0 12px; }
  .models span { font-size: 11px; background: #10151d; border: 1px solid var(--border); border-radius: 6px; padding: 2px 7px; color: #b9c5d4; }
  .card .actions { display: flex; gap: 8px; margin-top: 12px; }
  .card .actions button { padding: 5px 10px; font-size: 12px; }
  .empty { color: var(--muted); border: 1px dashed var(--border); border-radius: 12px; padding: 26px; text-align: center; }
  .form-card {
    margin-top: 26px; background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 18px 18px 20px;
  }
  .form-card h2 { margin: 0 0 14px; font-size: 16px; }
  .form-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(230px, 1fr)); gap: 12px 16px; }
  label { display: block; font-size: 12px; color: var(--muted); margin-bottom: 5px; }
  input, select, textarea {
    width: 100%; background: #0d1219; color: var(--text); border: 1px solid var(--border);
    border-radius: 8px; padding: 8px 10px; font: inherit; font-size: 13px; outline: none;
  }
  input:focus, select:focus, textarea:focus { border-color: var(--accent); }
  textarea { min-height: 62px; resize: vertical; font-family: ui-monospace, "Cascadia Code", monospace; font-size: 12px; }
  .form-actions { display: flex; gap: 10px; margin-top: 16px; align-items: center; }
  .hint { color: var(--muted); font-size: 12px; }
  #toast {
    position: fixed; right: 20px; bottom: 20px; max-width: 480px; background: #1c2230;
    border: 1px solid var(--border); border-left: 3px solid var(--ok); color: var(--text);
    padding: 11px 14px; border-radius: 8px; font-size: 13px; opacity: 0; transform: translateY(8px);
    transition: .2s; pointer-events: none; white-space: pre-wrap;
  }
  #toast.show { opacity: 1; transform: translateY(0); }
  #toast.err { border-left-color: var(--danger); }
  footer { max-width: 1180px; margin: 0 auto; padding: 0 28px 30px; color: var(--muted); font-size: 12px; }
  code { color: #c9d5e3; background: #10151d; padding: 1px 5px; border-radius: 5px; }
</style>
</head>
<body>
<header>
  <h1>cc<span>switch</span>-lite</h1>
  <div id="currentBadge">加载中…</div>
</header>
<main>
  <div class="toolbar">
    <button id="applyBtn" class="primary">应用当前供应商</button>
    <button id="restoreBtn" class="danger">恢复官方 1P 模式</button>
    <button id="refreshBtn" class="subtle">刷新</button>
  </div>
  <div id="list" class="grid"></div>

  <section class="form-card">
    <h2 id="formTitle">添加供应商</h2>
    <form id="form">
      <div class="form-grid">
        <div>
          <label for="f-name">名称</label>
          <input id="f-name" required placeholder="例如：公司网关">
        </div>
        <div>
          <label for="f-baseUrl">Base URL</label>
          <input id="f-baseUrl" required placeholder="http://127.0.0.1:18080/v1">
        </div>
        <div>
          <label for="f-apiKey">API Key</label>
          <input id="f-apiKey" type="password" autocomplete="off" placeholder="编辑时留空表示保持不变">
        </div>
        <div>
          <label for="f-apiFormat">API 格式</label>
          <select id="f-apiFormat">
            <option value="anthropic">anthropic</option>
            <option value="openai">openai</option>
          </select>
        </div>
        <div>
          <label for="f-defaultModel">默认模型（ANTHROPIC_MODEL）</label>
          <input id="f-defaultModel" placeholder="可选">
        </div>
      </div>
      <div class="form-grid" style="margin-top:12px">
        <div><label for="f-sonnet">Sonnet 映射</label><input id="f-sonnet" placeholder="可选，支持 [1m] 后缀"></div>
        <div><label for="f-opus">Opus 映射</label><input id="f-opus" placeholder="可选"></div>
        <div><label for="f-haiku">Haiku 映射</label><input id="f-haiku" placeholder="可选"></div>
        <div><label for="f-fable">Fable 映射</label><input id="f-fable" placeholder="可选"></div>
      </div>
      <div style="margin-top:12px">
        <label for="f-headers">额外请求头（每行一个 K=V，仅 Codex 支持）</label>
        <textarea id="f-headers" placeholder="X-Custom-Header=value"></textarea>
      </div>
      <div class="form-actions">
        <button type="submit" class="primary" id="saveBtn">保存</button>
        <button type="button" class="subtle" id="cancelBtn">取消编辑</button>
        <span class="hint" id="formHint">保存只会写入供应商列表；点卡片上的“使用”才会应用。</span>
      </div>
    </form>
  </section>
</main>
<footer>
  数据文件：<code>~/.config/ccswitch-lite/providers.json</code> ·
  API Key 仅以掩码显示 · 所有写操作前自动生成 <code>.bak.&lt;时间戳&gt;</code> 备份
</footer>
<div id="toast"></div>
<script>
(function () {
  "use strict";
  var token = "";
  (function () {
    var m = location.search.match(/[?&]token=([^&]+)/);
    if (m) {
      try { token = decodeURIComponent(m[1]); } catch (e) { token = m[1]; }
      try { sessionStorage.setItem("ccswitch_token", token); } catch (e) {}
      try { history.replaceState(null, "", location.pathname); } catch (e) {}
    } else {
      try { token = sessionStorage.getItem("ccswitch_token") || ""; } catch (e) {}
    }
  }());
  var state = { current: "", providers: [] };
  var editing = "";

  function $(id) { return document.getElementById(id); }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c];
    });
  }

  var toastTimer = null;
  function toast(msg, isErr) {
    var el = $("toast");
    el.textContent = msg;
    el.className = "show" + (isErr ? " err" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.className = ""; }, 5200);
  }

  function api(path, opts) {
    opts = opts || {};
    opts.headers = opts.headers || {};
    if (token) { opts.headers["X-CCSwitch-Token"] = token; }
    return fetch(path, opts).then(function (r) {
      return r.json().catch(function () { return { ok: false, error: "HTTP " + r.status }; })
        .then(function (j) {
          if (!r.ok || j.ok === false) { throw new Error(j.error || ("HTTP " + r.status)); }
          return j;
        });
    });
  }

  function post(path, body) {
    return api(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body || {})
    });
  }

  function modelChips(m) {
    if (!m) { return ""; }
    var out = "";
    [["sonnet", "Sonnet"], ["opus", "Opus"], ["haiku", "Haiku"], ["fable", "Fable"]].forEach(function (pair) {
      var v = m[pair[0]];
      if (v) { out += "<span>" + esc(pair[1]) + ": " + esc(v) + "</span>"; }
    });
    return out;
  }

  function render() {
    var list = $("list");
    $("currentBadge").textContent = state.current
      ? "当前：" + state.current
      : "尚未选择供应商";
    if (!state.providers.length) {
      list.innerHTML = "<div class=\"empty\">还没有供应商。在下方添加第一个。</div>";
      return;
    }
    var html = "";
    state.providers.forEach(function (p) {
      var active = p.name === state.current;
      html += "<article class=\"card" + (active ? " active" : "") + "\">";
      html += "<h3>" + esc(p.name) + "<span class=\"pill\">" + esc(p.apiFormat) + "</span>";
      if (active) { html += "<span class=\"pill on\">使用中</span>"; }
      html += "</h3>";
      html += "<div class=\"kv\"><b>Base URL</b> " + esc(p.baseUrl) + "</div>";
      html += "<div class=\"kv\"><b>Key</b> " + esc(p.maskedKey) + "</div>";
      if (p.defaultModel) { html += "<div class=\"kv\"><b>默认模型</b> " + esc(p.defaultModel) + "</div>"; }
      html += "<div class=\"models\">" + modelChips(p.models) + "</div>";
      html += "<div class=\"actions\">";
      html += "<button class=\"primary\" data-act=\"use\" data-name=\"" + esc(p.name) + "\">使用并应用</button>";
      html += "<button data-act=\"edit\" data-name=\"" + esc(p.name) + "\">编辑</button>";
      html += "<button class=\"danger\" data-act=\"del\" data-name=\"" + esc(p.name) + "\">删除</button>";
      html += "</div></article>";
    });
    list.innerHTML = html;
  }

  function load() {
    return api("/api/state").then(function (s) {
      state = s;
      render();
    }).catch(function (e) { toast("加载失败: " + e.message, true); });
  }

  function fillForm(p) {
    editing = p ? p.name : "";
    $("formTitle").textContent = p ? "编辑供应商：" + p.name : "添加供应商";
    $("f-name").value = p ? p.name : "";
    $("f-name").disabled = !!p;
    $("f-baseUrl").value = p ? p.baseUrl : "";
    $("f-apiKey").value = "";
    $("f-apiKey").placeholder = p ? "留空表示保持原 Key 不变" : "API Key";
    $("f-apiFormat").value = p ? p.apiFormat : "anthropic";
    $("f-defaultModel").value = p && p.defaultModel ? p.defaultModel : "";
    var m = (p && p.models) || {};
    $("f-sonnet").value = m.sonnet || "";
    $("f-opus").value = m.opus || "";
    $("f-haiku").value = m.haiku || "";
    $("f-fable").value = m.fable || "";
    var hs = "";
    if (p && p.extraHeaders) {
      Object.keys(p.extraHeaders).forEach(function (k) { hs += k + "=" + p.extraHeaders[k] + "\n"; });
    }
    $("f-headers").value = hs.replace(/\n$/, "");
  }

  function parseHeaders(text) {
    var out = {};
    text.split(/\r?\n/).forEach(function (line) {
      line = line.trim();
      if (!line) { return; }
      var i = line.indexOf("=");
      if (i > 0) { out[line.slice(0, i).trim()] = line.slice(i + 1).trim(); }
    });
    return out;
  }

  $("form").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var body = {
      name: $("f-name").value.trim(),
      baseUrl: $("f-baseUrl").value.trim(),
      apiKey: $("f-apiKey").value,
      apiFormat: $("f-apiFormat").value,
      defaultModel: $("f-defaultModel").value.trim(),
      models: {
        sonnet: $("f-sonnet").value.trim(),
        opus: $("f-opus").value.trim(),
        haiku: $("f-haiku").value.trim(),
        fable: $("f-fable").value.trim()
      },
      extraHeaders: parseHeaders($("f-headers").value)
    };
    if (Object.keys(body.extraHeaders).length === 0) { delete body.extraHeaders; }
    post("/api/providers", body).then(function (r) {
      toast(r.message || "已保存");
      fillForm(null);
      return load();
    }).catch(function (e) { toast("保存失败: " + e.message, true); });
  });

  $("cancelBtn").addEventListener("click", function () { fillForm(null); });
  $("refreshBtn").addEventListener("click", load);

  $("list").addEventListener("click", function (ev) {
    var btn = ev.target.closest("button[data-act]");
    if (!btn) { return; }
    var name = btn.getAttribute("data-name");
    var act = btn.getAttribute("data-act");
    if (act === "use") {
      btn.disabled = true;
      post("/api/use", { name: name }).then(function (r) {
        toast(r.message || "已应用");
        return load();
      }).catch(function (e) { toast("应用失败: " + e.message, true); btn.disabled = false; });
    } else if (act === "edit") {
      var p = state.providers.filter(function (x) { return x.name === name; })[0];
      if (p) { fillForm(p); window.scrollTo({ top: document.body.scrollHeight, behavior: "smooth" }); }
    } else if (act === "del") {
      if (!confirm("删除供应商 " + name + "？（不会自动恢复已应用的配置）")) { return; }
      api("/api/providers?name=" + encodeURIComponent(name), {
        method: "DELETE",
        headers: { "Content-Type": "application/json" }
      }).then(function (r) {
        toast(r.message || "已删除");
        if (editing === name) { fillForm(null); }
        return load();
      }).catch(function (e) { toast("删除失败: " + e.message, true); });
    }
  });

  $("applyBtn").addEventListener("click", function () {
    post("/api/apply", {}).then(function (r) {
      toast(r.message || "已应用");
      return load();
    }).catch(function (e) { toast("应用失败: " + e.message, true); });
  });

  $("restoreBtn").addEventListener("click", function () {
    if (!confirm("恢复 Claude Desktop 为官方 1P 模式，并移除本工具写入的 Claude Code / Codex 配置？")) { return; }
    post("/api/restore", {}).then(function (r) {
      toast(r.message || "已恢复");
      return load();
    }).catch(function (e) { toast("恢复失败: " + e.message, true); });
  });

  fillForm(null);
  load();
})();
</script>
</body>
</html>
`
