#!/usr/bin/env bun

const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const crypto = require("node:crypto");
const { spawn } = require("node:child_process");

const root = path.resolve(__dirname, "..");
const envPath = path.join(root, "config", "bridge.env");
const defaultRedirectUri = "http://127.0.0.1:7531/callback";
const openApiBase = process.env.FEISHU_OPENAPI_BASE || "https://open.feishu.cn";

function readEnvFile(file) {
  const lines = fs.existsSync(file) ? fs.readFileSync(file, "utf8").split(/\r?\n/) : [];
  const map = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const idx = trimmed.indexOf("=");
    if (idx < 0) continue;
    let value = trimmed.slice(idx + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    map[trimmed.slice(0, idx).trim()] = value;
  }
  return { lines, map };
}

function writeEnvValues(file, values) {
  const { lines } = readEnvFile(file);
  const seen = new Set();
  const next = lines.map((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#") || !trimmed.includes("=")) return line;
    const key = trimmed.slice(0, trimmed.indexOf("=")).trim();
    if (!Object.prototype.hasOwnProperty.call(values, key)) return line;
    seen.add(key);
    return `${key}=${values[key] || ""}`;
  });

  for (const [key, value] of Object.entries(values)) {
    if (!seen.has(key)) next.push(`${key}=${value || ""}`);
  }

  fs.writeFileSync(file, next.join("\n").replace(/\n*$/, "\n"), "utf8");
}

async function postJson(url, body, token) {
  const headers = { "Content-Type": "application/json; charset=utf-8" };
  if (token) headers.Authorization = `Bearer ${token}`;

  const res = await fetch(url, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    return { code: res.status, msg: text };
  }
}

async function getAppAccessToken(appId, appSecret) {
  const data = await postJson(`${openApiBase}/open-apis/auth/v3/app_access_token/internal`, {
    app_id: appId,
    app_secret: appSecret,
  });
  if (data.code !== 0 || !data.app_access_token) {
    throw new Error(`failed to get app_access_token: ${data.msg || data.code}`);
  }
  return data.app_access_token;
}

async function exchangeUserToken(appToken, code) {
  const data = await postJson(`${openApiBase}/open-apis/authen/v1/access_token`, {
    grant_type: "authorization_code",
    code,
  }, appToken);

  if (data.code !== 0 || !data.data?.access_token) {
    throw new Error(`failed to exchange user_access_token: ${data.msg || data.code}`);
  }
  return data.data;
}

function openUrl(url) {
  try {
    if (process.platform === "win32") {
      spawn("cmd", ["/c", "start", "", url], { detached: true, stdio: "ignore" }).unref();
    } else if (process.platform === "darwin") {
      spawn("open", [url], { detached: true, stdio: "ignore" }).unref();
    } else {
      spawn("xdg-open", [url], { detached: true, stdio: "ignore" }).unref();
    }
  } catch {
    // The URL is printed below as a fallback.
  }
}

async function main() {
  const { map } = readEnvFile(envPath);
  const appId = map.FEISHU_APP_ID || process.env.FEISHU_APP_ID;
  const appSecret = map.FEISHU_APP_SECRET || process.env.FEISHU_APP_SECRET;
  const redirectUri = map.FEISHU_OAUTH_REDIRECT_URI || process.env.FEISHU_OAUTH_REDIRECT_URI || defaultRedirectUri;

  if (!appId || !appSecret) {
    throw new Error("missing FEISHU_APP_ID or FEISHU_APP_SECRET in config/bridge.env");
  }

  const callbackUrl = new URL(redirectUri);
  const state = crypto.randomBytes(16).toString("hex");
  const authUrl = new URL(`${openApiBase}/open-apis/authen/v1/index`);
  authUrl.searchParams.set("app_id", appId);
  authUrl.searchParams.set("redirect_uri", redirectUri);
  authUrl.searchParams.set("state", state);

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url || "/", redirectUri);
      if (url.pathname !== callbackUrl.pathname) {
        res.writeHead(404);
        res.end("Not found");
        return;
      }

      const error = url.searchParams.get("error");
      if (error) {
        res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
        res.end(`Feishu authorization failed: ${error}`);
        server.close();
        return;
      }

      if (url.searchParams.get("state") !== state) {
        res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
        res.end("State mismatch.");
        server.close();
        return;
      }

      const code = url.searchParams.get("code");
      if (!code) {
        res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
        res.end("Missing authorization code.");
        server.close();
        return;
      }

      const appToken = await getAppAccessToken(appId, appSecret);
      const tokenData = await exchangeUserToken(appToken, code);
      const expiresAt = tokenData.expires_in ? String(Date.now() + Number(tokenData.expires_in) * 1000) : "";

      writeEnvValues(envPath, {
        FEISHU_OAUTH_REDIRECT_URI: redirectUri,
        FEISHU_USER_ACCESS_TOKEN: tokenData.access_token || "",
        FEISHU_REFRESH_TOKEN: tokenData.refresh_token || "",
        FEISHU_USER_TOKEN_EXPIRES_AT: expiresAt,
      });

      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end("<h3>Feishu user authorization saved.</h3><p>You can close this page.</p>");
      console.log("Saved FEISHU_USER_ACCESS_TOKEN and FEISHU_REFRESH_TOKEN to config/bridge.env.");
      server.close();
    } catch (error) {
      res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
      res.end(error instanceof Error ? error.message : String(error));
      console.error(error instanceof Error ? error.message : String(error));
      server.close();
    }
  });

  server.listen(Number(callbackUrl.port || 80), callbackUrl.hostname, () => {
    console.log(`Listening for Feishu OAuth callback on ${redirectUri}`);
    console.log(`Open this URL if the browser does not open automatically:\n${authUrl.toString()}`);
    openUrl(authUrl.toString());
  });
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
