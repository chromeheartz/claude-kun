#!/usr/bin/env node
// 클로드쿤 Claude Code 훅. UserPromptSubmit / Stop 공용.
// 앱이 안 떠 있으면 항상 그냥 통과(exit 0). Claude Code를 막는 일은 없음.
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

const ROOT = path.join(os.homedir(), ".token-watch");
const INBOX = path.join(ROOT, "inbox");
const OUTBOX = path.join(ROOT, "outbox");
const WAIT_MS = 90_000;
const TAIL_BYTES = 262_144;

/**
 * 앱 설정(~/.token-watch/lang)에 맞춘 차단 문구
 * @param {string} reason
 * @returns {string}
 */
function msg(reason) {
  let lang = "ko";
  try { lang = fs.readFileSync(path.join(ROOT, "lang"), "utf8").trim(); } catch {}
  return lang === "ja"
    ? "🧡 クロードくん: ちょっと待って、このまま送る?\n" + reason + "\n(そのままもう一度送れば通るよ)"
    : "🧡 클로드쿤: 잠깐! 이거 그냥 보내게?\n" + reason + "\n(그대로 다시 보내면 통과돼)";
}

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

function readStdin() {
  try { return JSON.parse(fs.readFileSync(0, "utf8")); } catch { return null; }
}

function appAlive() {
  try { return Date.now() - fs.statSync(path.join(ROOT, "alive")).mtimeMs < 5000; } catch { return false; }
}

function tailLines(file) {
  const fd = fs.openSync(file, "r");
  try {
    const size = fs.fstatSync(fd).size;
    const len = Math.min(size, TAIL_BYTES);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    const lines = buf.toString("utf8").split("\n");
    if (size > len) lines.shift(); // 잘린 첫 줄 버림
    return lines;
  } finally { fs.closeSync(fd); }
}

function isRealUserPrompt(e) {
  if (e.type !== "user" || !e.message) return false;
  const c = e.message.content;
  if (typeof c === "string") return true;
  return Array.isArray(c) && !c.some((b) => b && b.type === "tool_result");
}

// 마지막 사용자 프롬프트 이후의 assistant usage를 모아 턴 요약을 만든다.
function parseTranscript(file) {
  const out = { contextTokens: 0, model: "", output: 0, thinking: 0, newContext: 0 };
  if (!file || !fs.existsSync(file)) return out;
  const seen = new Set();
  let latest = null;
  for (const line of tailLines(file).reverse()) {
    if (!line.trim()) continue;
    let e; try { e = JSON.parse(line); } catch { continue; }
    if (isRealUserPrompt(e)) break;
    const u = e.type === "assistant" && e.message && e.message.usage;
    if (!u) continue;
    const mid = e.message.id || e.uuid;
    if (seen.has(mid)) continue; // 스트리밍으로 같은 메시지가 여러 줄에 나뉘어 기록됨
    seen.add(mid);
    if (!latest) { latest = u; out.model = e.message.model || ""; }
    out.output += u.output_tokens || 0;
    out.thinking += (u.output_tokens_details && u.output_tokens_details.thinking_tokens) || 0;
    out.newContext += u.cache_creation_input_tokens || 0;
  }
  if (latest) {
    out.contextTokens = (latest.input_tokens || 0) + (latest.cache_read_input_tokens || 0) + (latest.cache_creation_input_tokens || 0);
  }
  return out;
}

function writeInbox(id, obj) {
  const tmp = path.join(INBOX, id + ".tmp");
  fs.writeFileSync(tmp, JSON.stringify(obj));
  fs.renameSync(tmp, path.join(INBOX, id + ".json"));
}

function waitOutbox(id) {
  const f = path.join(OUTBOX, id + ".json");
  const deadline = Date.now() + WAIT_MS;
  while (Date.now() < deadline) {
    if (fs.existsSync(f)) {
      try { const r = JSON.parse(fs.readFileSync(f, "utf8")); fs.unlinkSync(f); return r; } catch {}
    }
    sleep(100);
  }
  try { fs.unlinkSync(path.join(INBOX, id + ".json")); } catch {}
  return null;
}

function main() {
  const input = readStdin();
  if (!input) return;
  fs.mkdirSync(INBOX, { recursive: true });
  fs.mkdirSync(OUTBOX, { recursive: true });
  if (!appAlive()) return;

  const event = input.hook_event_name;
  const sessionId = input.session_id || "";
  const t = parseTranscript(input.transcript_path);
  const id = crypto.randomUUID();

  if (event === "Stop") {
    if (!t.model) return;
    writeInbox(id, { event: "turn", id, sessionId, turn: {
      ts: Date.now() / 1000, sessionId, model: t.model,
      output: t.output, thinking: t.thinking, newContext: t.newContext, contextTokens: t.contextTokens,
    }});
    return;
  }

  if (event === "UserPromptSubmit") {
    const prompt = input.prompt || "";
    // 막힌 뒤 같은 프롬프트를 그대로 다시 보내면 통과
    const hashFile = path.join(ROOT, `last-blocked-${sessionId}.txt`);
    const h = crypto.createHash("sha1").update(prompt).digest("hex");
    if (fs.existsSync(hashFile)) {
      const prev = fs.readFileSync(hashFile, "utf8");
      fs.unlinkSync(hashFile);
      if (prev === h) return;
    }
    writeInbox(id, { event: "prompt", id, sessionId, prompt, contextTokens: t.contextTokens, model: t.model });
    const r = waitOutbox(id);
    if (r && r.decision === "block") {
      fs.writeFileSync(hashFile, h);
      process.stdout.write(JSON.stringify({ decision: "block", reason: msg(r.reason) }));
    }
  }
}

try { main(); } catch { /* 훅 오류는 절대 Claude Code를 막지 않음 */ }
