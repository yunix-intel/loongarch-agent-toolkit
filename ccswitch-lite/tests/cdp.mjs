// Tiny Chrome DevTools Protocol client for the Claude Desktop verification.
// Node 22+ provides a global WebSocket, so this has no dependencies.
import fs from "node:fs";

const base = process.env.CDP_BASE || "http://127.0.0.1:9222";

async function targets() {
  const r = await fetch(base + "/json");
  return r.json();
}

const list = await targets();
const page = list.find((t) => t.type === "page") || list[0];
if (!page) {
  console.error("no CDP page target");
  process.exit(2);
}
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.addEventListener("open", resolve, { once: true });
  ws.addEventListener("error", reject, { once: true });
});

let nextId = 0;
const pending = new Map();
ws.addEventListener("message", (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg);
    pending.delete(msg.id);
  }
});

function cmd(method, params = {}) {
  return new Promise((resolve) => {
    const id = ++nextId;
    pending.set(id, resolve);
    ws.send(JSON.stringify({ id, method, params }));
  });
}

const action = process.argv[2] || "text";
const arg = process.argv[3];

if (action === "text") {
  const r = await cmd("Runtime.evaluate", {
    expression: "document.body ? document.body.innerText : ''",
    returnByValue: true,
  });
  console.log(r.result?.result?.value ?? "");
} else if (action === "html") {
  const r = await cmd("Runtime.evaluate", {
    expression: "document.body ? document.body.innerHTML : ''",
    returnByValue: true,
  });
  console.log(r.result?.result?.value ?? "");
} else if (action === "eval") {
  const r = await cmd("Runtime.evaluate", {
    expression: arg,
    returnByValue: true,
    awaitPromise: true,
  });
  console.log(JSON.stringify(r.result?.result?.value ?? r.result, null, 2));
} else if (action === "shot") {
  const r = await cmd("Page.captureScreenshot", { format: "png" });
  if (!r.result?.data) {
    console.error(JSON.stringify(r));
    process.exit(1);
  }
  fs.writeFileSync(arg, Buffer.from(r.result.data, "base64"));
  console.log("saved " + arg);
} else if (action === "send") {
  const focus = await cmd("Runtime.evaluate", {
    expression: `(() => {
      const els = [...document.querySelectorAll('div[contenteditable="true"], textarea')]
        .filter(e => e.offsetParent !== null || e.getClientRects().length);
      if (!els.length) return { ok: false, count: 0 };
      const el = els[0];
      el.focus();
      return { ok: true, tag: el.tagName, cls: el.className, ph: el.getAttribute('placeholder') || el.getAttribute('data-placeholder') || '' };
    })()`,
    returnByValue: true,
  });
  console.log("focus:", JSON.stringify(focus.result?.result?.value));
  if (!focus.result?.result?.value?.ok) process.exit(3);
  await cmd("Input.insertText", { text: arg || "Hello from ccswitch-lite test" });
  await new Promise((r) => setTimeout(r, 500));
  for (const type of ["keyDown", "keyUp"]) {
    await cmd("Input.dispatchKeyEvent", {
      type,
      key: "Enter",
      code: "Enter",
      windowsVirtualKeyCode: 13,
      nativeVirtualKeyCode: 13,
    });
  }
  console.log("message sent");
} else {
  console.error("unknown action " + action);
  process.exit(2);
}
ws.close();
