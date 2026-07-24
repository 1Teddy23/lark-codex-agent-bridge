#!/usr/bin/env bun

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn, spawnSync } = require("node:child_process");

function writeJsonLine(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function findCodexBin() {
  const candidates = [
    process.env.CODEX_BIN,
    path.join(process.env.LOCALAPPDATA || "", "OpenAI", "Codex", "bin", "codex.exe"),
    path.join(process.env.USERPROFILE || "", ".codex", ".sandbox-bin", "codex.exe"),
    "codex",
  ].filter(Boolean);

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
    const where = spawnSync(process.platform === "win32" ? "where" : "which", [candidate], {
      encoding: "utf8",
      windowsHide: true,
    });
    const found = where.stdout?.split(/\r?\n/).find(Boolean);
    if (where.status === 0 && found) return found.trim();
  }

  throw new Error("Codex CLI was not found. Set CODEX_BIN or install Codex CLI.");
}

function parseArgs(argv) {
  let workspace = process.cwd();
  let model = "";
  let resumeId = "";
  let outputFormat = "stream-json";
  let promptParts = [];

  for (let i = 0; i < argv.length; i++) {
    const arg = String(argv[i]);
    if (arg === "--workspace" && i + 1 < argv.length) {
      workspace = String(argv[++i]);
      continue;
    }
    if (arg === "--model" && i + 1 < argv.length) {
      model = String(argv[++i]);
      continue;
    }
    if (arg === "--resume" && i + 1 < argv.length) {
      resumeId = String(argv[++i]);
      continue;
    }
    if (arg === "--output-format" && i + 1 < argv.length) {
      outputFormat = String(argv[++i]);
      continue;
    }
    if (arg === "--") {
      promptParts = argv.slice(i + 1).map(String);
      break;
    }
  }

  const prompt = promptParts.length ? promptParts.join(" ") : argv.map(String).join(" ");
  return { workspace, model, resumeId, outputFormat, prompt };
}

const { workspace, model, resumeId, outputFormat, prompt } = parseArgs(process.argv.slice(2));
const bridgeOutput = outputFormat !== "text";
const codexBin = findCodexBin();
const runId = crypto.randomUUID().replace(/-/g, "");
const tempDir = path.join(os.tmpdir(), "lark-agent-codex");
fs.mkdirSync(tempDir, { recursive: true });

const eventsPath = path.join(tempDir, `${runId}.events.jsonl`);
const stderrPath = path.join(tempDir, `${runId}.stderr.log`);
const lastPath = path.join(tempDir, `${runId}.last.txt`);

let threadId = "";
let assistantText = "";
let stderrText = "";
let child = null;
let timedOut = false;
let completionGraceHandle = null;
const timeoutMs = Number.parseInt(process.env.CODEX_AGENT_TIMEOUT_MS || "0", 10);

function sessionId() {
  return threadId || runId;
}

function appendEventLine(line) {
  try {
    fs.appendFileSync(eventsPath, `${line}\n`, "utf8");
  } catch {
    // Diagnostics are best-effort; bridge output should keep flowing.
  }
}

function emitTool(subtype, command, output = "", exitCode = 0) {
  if (!bridgeOutput) return;

  const tool = { args: { command: command || "command" } };
  if (subtype === "completed") {
    let content = String(output || "").trim();
    if (!content) content = `exit code ${exitCode ?? 0}`;
    if (content.length > 1200) content = content.slice(0, 1200);
    tool.result = { success: { content } };
  }

  writeJsonLine({
    type: "tool_call",
    subtype,
    session_id: sessionId(),
    tool_call: {
      shellToolCall: tool,
    },
  });
}

function emitAssistant(text) {
  if (!text) return;
  assistantText += text;
  if (!bridgeOutput) return;

  writeJsonLine({
    type: "assistant",
    session_id: sessionId(),
    message: {
      role: "assistant",
      content: [{ type: "text", text }],
    },
  });
}

function processCodexLine(line) {
  const trimmed = line.trim();
  if (!trimmed.startsWith("{")) return;

  let event;
  try {
    event = JSON.parse(trimmed);
  } catch {
    return;
  }

  if (event.type === "thread.started" && event.thread_id) {
    threadId = String(event.thread_id);
    if (bridgeOutput) {
      writeJsonLine({ type: "thinking", session_id: sessionId(), text: "codex thread started" });
    }
    return;
  }

  if (event.type === "turn.started") {
    if (bridgeOutput) {
      writeJsonLine({ type: "thinking", session_id: sessionId(), text: "codex turn started" });
    }
    return;
  }

  if (event.type === "turn.completed") {
    // Codex can emit the final response but leave its CLI process alive. Give
    // normal shutdown a short grace period, then release the bridge using the
    // response already received on the event stream.
    if (assistantText.trim() && !completionGraceHandle) {
      completionGraceHandle = setTimeout(() => {
        if (child && child.exitCode === null && !child.killed) {
          killChildTree();
        }
      }, 15_000);
    }
    return;
  }

  if ((event.type === "item.started" || event.type === "item.completed") && event.item) {
    const item = event.item;

    if (item.type === "agent_message" && event.type === "item.completed" && item.text) {
      emitAssistant(String(item.text));
      return;
    }

    if (item.type === "command_execution") {
      const command = String(item.command || "command");
      if (event.type === "item.started") {
        emitTool("started", command);
      } else {
        emitTool("completed", command, item.aggregated_output || "", item.exit_code ?? 0);
      }
      return;
    }

    if (String(item.type || "").match(/tool|mcp|web/i)) {
      const name = String(item.name || item.type || "tool");
      if (event.type === "item.started") {
        emitTool("started", name);
      } else {
        emitTool("completed", name, item.output || item.result || "", 0);
      }
      return;
    }

    if (item.type === "reasoning" && item.summary) {
      if (bridgeOutput) {
        writeJsonLine({ type: "thinking", session_id: sessionId(), text: String(item.summary) });
      }
    }
    return;
  }

  if (bridgeOutput && event.type === "error") {
    writeJsonLine({
      type: "result",
      subtype: "error",
      session_id: sessionId(),
      error: String(event.message || trimmed),
    });
  }
}

function cleanup() {
  if (process.env.CODEX_ADAPTER_KEEP_LOGS === "1") return;
  for (const file of [eventsPath, stderrPath, lastPath]) {
    try {
      fs.rmSync(file, { force: true });
    } catch {
      // Best-effort cleanup.
    }
  }
}

function killChildTree() {
  if (!child || !child.pid) return;

  try {
    if (process.platform === "win32") {
      spawnSync("taskkill", ["/pid", String(child.pid), "/t", "/f"], {
        windowsHide: true,
        stdio: "ignore",
      });
      return;
    }
    child.kill("SIGTERM");
  } catch {
    // Process may already be gone.
  }
}

if (bridgeOutput) {
  writeJsonLine({ type: "thinking", text: "codex exec started" });
}

const commonArgs = [
  "--json",
  "--output-last-message",
  lastPath,
  "--skip-git-repo-check",
  "--dangerously-bypass-approvals-and-sandbox",
];

if (model && model !== "auto") {
  commonArgs.push("--model", model);
}

const resumeLooksValid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(resumeId);
const codexArgs = resumeLooksValid
  ? ["exec", "resume", ...commonArgs, resumeId, prompt]
  : ["exec", ...commonArgs, "--cd", workspace, "--", prompt];

try {
  child = spawn(codexBin, codexArgs, {
    cwd: workspace,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  if (bridgeOutput) {
    writeJsonLine({
      type: "result",
      subtype: "error",
      session_id: sessionId(),
      error: message,
    });
  } else {
    process.stdout.write(message);
  }
  process.exit(0);
}

let timeoutHandle = null;
if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
  timeoutHandle = setTimeout(() => {
    timedOut = true;
    if (bridgeOutput) {
      writeJsonLine({
        type: "thinking",
        session_id: sessionId(),
        text: `Codex task timed out after ${Math.round(timeoutMs / 1000)} seconds`,
      });
    }
    killChildTree();
  }, timeoutMs);
}

let stdoutBuffer = "";
child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  stdoutBuffer += chunk;
  const lines = stdoutBuffer.split(/\r?\n/);
  stdoutBuffer = lines.pop() || "";
  for (const line of lines) {
    appendEventLine(line);
    processCodexLine(line);
  }
});

child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  stderrText += chunk;
});

child.on("error", (error) => {
  if (timeoutHandle) clearTimeout(timeoutHandle);
  if (completionGraceHandle) clearTimeout(completionGraceHandle);
  const message = error instanceof Error ? error.message : String(error);
  if (bridgeOutput) {
    writeJsonLine({
      type: "result",
      subtype: "error",
      session_id: sessionId(),
      error: message,
    });
  } else {
    process.stdout.write(message);
  }
  cleanup();
  process.exit(0);
});

child.on("close", (code) => {
  if (timeoutHandle) clearTimeout(timeoutHandle);
  if (completionGraceHandle) clearTimeout(completionGraceHandle);
  if (stdoutBuffer.trim()) {
    appendEventLine(stdoutBuffer);
    processCodexLine(stdoutBuffer);
  }

  if (stderrText.trim()) {
    try {
      fs.writeFileSync(stderrPath, stderrText.trim(), "utf8");
    } catch {
      // Best-effort diagnostics.
    }
  }

  if (!assistantText && fs.existsSync(lastPath)) {
    const last = fs.readFileSync(lastPath, "utf8").trim();
    if (last) emitAssistant(last);
  }

  if (!bridgeOutput) {
    process.stdout.write(assistantText || stderrText.trim() || "");
    cleanup();
    process.exit(0);
  }

  if (timedOut) {
    writeJsonLine({
      type: "result",
      subtype: "error",
      session_id: sessionId(),
      error: `Codex task timed out after ${Math.round(timeoutMs / 1000)} seconds`,
    });
    cleanup();
    process.exit(0);
  }

  if (code !== 0 && !assistantText) {
    writeJsonLine({
      type: "result",
      subtype: "error",
      session_id: sessionId(),
      error: stderrText.trim() || `Codex CLI exited with code ${code}`,
    });
    cleanup();
    process.exit(0);
  }

  if (!assistantText) {
    emitAssistant(stderrText.trim() || "(no output)");
  }

  writeJsonLine({
    type: "result",
    session_id: sessionId(),
    result: assistantText,
  });

  cleanup();
  process.exit(0);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    if (timeoutHandle) clearTimeout(timeoutHandle);
    if (completionGraceHandle) clearTimeout(completionGraceHandle);
    killChildTree();
    cleanup();
    process.exit(0);
  });
}
