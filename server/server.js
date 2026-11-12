/**
 * RPHelper companion — background watcher + blank local status page.
 * Zero-dependency Node process:
 *  - polls the addon's SavedVariables file for in-game requests (1s)
 *  - calls the AI (OpenRouter) or falls back to offline templates
 *  - writes answers into the addon's RPHelperHandoff.lua
 *  - serves a minimal status page on 127.0.0.1:7331 (the GUI itself is in-game)
 */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findSavedVariablesFile, parseSavedVariables, deriveWowRoot, unescapeLuaString } from './player.js';
import { guildEnabled, getGuild, upsertMember, removeMember, setGuildName, mergeMember, guildPromptBlock } from './guild.js';

/** Repo root: module dir (dev) → exe dir (packaged) → cwd. */
function detectRoot() {
  const candidates = [];
  try { candidates.push(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')); } catch { /* bundled */ }
  try { candidates.push(path.dirname(process.execPath)); } catch { /* packaged exe */ }
  try { candidates.push(path.resolve(path.dirname(process.execPath), '..')); } catch { /* dist/ layout */ }
  candidates.push(process.cwd());
  for (const c of candidates) {
    if (
      fs.existsSync(path.join(c, 'config.example.json')) ||
      fs.existsSync(path.join(c, 'config.json'))
    ) {
      return c;
    }
  }
  return process.cwd();
}
const ROOT = detectRoot();
const REPO_ADDON_DIR = path.join(ROOT, 'Addon');
const PUBLIC_DIR = path.join(ROOT, 'public');

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
function loadConfig() {
  const cfgPath = path.join(ROOT, 'config.json');
  const examplePath = path.join(ROOT, 'config.example.json');
  const file = fs.existsSync(cfgPath) ? cfgPath : examplePath;
  try {
    // Strip UTF-8 BOM — PowerShell-written files carry one and JSON.parse chokes on it
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  } catch (err) {
    console.error(`[config] failed to read ${file}: ${err.message}`);
    return { port: 7331, handoffPath: '', openrouter: { apiKey: '', model: 'deepseek/deepseek-v4-flash' } };
  }
}
const config = loadConfig();
const PORT = config.port || 7331;
let chatBusy = false; // one browser chat request at a time

// Crash guards: a silent death means no AI replies in game and no clue why.
// Log loudly (and to a file) instead of exiting.
const LOG_FILE = path.join(ROOT, 'watcher.log');
function logCrash(kind, err) {
  const line = `[${new Date().toISOString()}] ${kind}: ${err && (err.stack || err.message) || err}\n`;
  try { fs.appendFileSync(LOG_FILE, line); } catch { /* best effort */ }
  console.error(line.trim());
}
process.on('uncaughtException', (err) => logCrash('uncaughtException', err));
process.on('unhandledRejection', (err) => logCrash('unhandledRejection', err));

// Every watcher event goes to watcher.log too — the player sends us ONE file.
function logLine(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch { /* best effort */ }
  console.log(line);
}

// Watcher stats, exposed on the status page
const stats = {
  startedAt: new Date().toISOString(),
  requestsServed: 0,
  lastRequestAt: null,
  lastError: null,
  lastPollAt: null,
};

// ---------------------------------------------------------------------------
// Handoff target resolution
// ---------------------------------------------------------------------------
const WOW_ADDON_DIR_CANDIDATES = [
  'C:\\Program Files (x86)\\World of Warcraft\\_forever_\\Interface\\AddOns\\RPHelper',
  'C:\\Program Files\\World of Warcraft\\_forever_\\Interface\\AddOns\\RPHelper',
  'C:\\Program Files (x86)\\World of Warcraft\\_retail_\\Interface\\AddOns\\RPHelper',
  'C:\\Program Files\\World of Warcraft\\_retail_\\Interface\\AddOns\\RPHelper',
  'C:\\Program Files (x86)\\Steam\\steamapps\\common\\World of Warcraft\\_retail_\\Interface\\AddOns\\RPHelper',
  'D:\\World of Warcraft\\_retail_\\Interface\\AddOns\\RPHelper',
  'E:\\World of Warcraft\\_retail_\\Interface\\AddOns\\RPHelper',
];

/** Returns { file, where } — where: 'config' | 'detected' | 'repo' */
function resolveHandoffTarget() {
  if (config.handoffPath && config.handoffPath.trim()) {
    return { file: config.handoffPath.trim(), where: 'config' };
  }
  for (const dir of WOW_ADDON_DIR_CANDIDATES) {
    if (fs.existsSync(dir)) {
      return { file: path.join(dir, 'RPHelperHandoff.lua'), where: 'detected' };
    }
  }
  return { file: path.join(REPO_ADDON_DIR, 'RPHelperHandoff.lua'), where: 'repo' };
}

/** Chat replies get their OWN mailbox file — a single shared handoff file
 * meant a chat reply could be overwritten by a suggestions answer before
 * the addon ever read it. */
function resolveChatHandoffTarget() {
  const main = resolveHandoffTarget();
  return { file: path.join(path.dirname(main.file), 'RPHelperChatHandoff.lua'), where: main.where };
}

// ---------------------------------------------------------------------------
// Lua serialization for the handoff file
// ---------------------------------------------------------------------------
function luaString(s) {
  return `"${String(s)
    .replace(/\\/g, '\\\\')
    .replace(/"/g, '\\"')
    .replace(/\r/g, '')
    .replace(/\n/g, '\\n')}"`;
}

function luaChatHistory(history) {
  const items = history
    .map((e) => `    { r = ${luaString(e.r || 'u')}, t = ${luaString(e.t || '')} },`)
    .join('\n');
  return `{\n${items}\n  }`;
}

function buildHandoffFile({ suggestions, scene, tone, requestId, error, kind, personality, quirks, chatReply, chatHistoryFull, globalName }) {
  const generatedAt = new Date().toISOString();
  const items = (suggestions || []).map((s) => `    ${luaString(s)},`).join('\n');
  // CRITICAL: the chat mailbox must assign ITS OWN global — writing
  // RPHelperHandoffData from the chat file clobbered the main global on
  // load (TOC order), so GetChatHandoff() was always nil and chat replies
  // could never display.
  const global = globalName || 'RPHelperHandoffData';
  return `-- Generated by RPHelper companion at ${generatedAt}
-- Safe to overwrite: the game never writes this file itself.
${global} = {
  generatedAt = ${luaString(generatedAt)},
  requestId = ${requestId ? luaString(String(requestId)) : 'nil'},
  kind = ${kind ? luaString(String(kind)) : 'nil'},
  error = ${error ? luaString(String(error)) : 'nil'},
  tone = ${luaString(tone || '')},
  scene = ${luaString(scene || '')},
  personality = ${personality !== undefined ? luaString(personality) : 'nil'},
  quirks = ${quirks !== undefined ? luaString(quirks) : 'nil'},
  chatReply = ${chatReply !== undefined ? luaString(chatReply) : 'nil'},
  chatHistoryFull = ${chatHistoryFull && chatHistoryFull.length ? luaChatHistory(chatHistoryFull) : 'nil'},
  suggestions = {
${items}
  },
}
`;
}

// ---------------------------------------------------------------------------
// AI generation
// ---------------------------------------------------------------------------
const SYSTEM_PROMPT = `You are a World of Warcraft roleplay writing coach helping a NEW RPPVP player reply in character.
Given the player's character sheet and the current scene, write in-character chat replies.
Rules:
- Write ONLY what the player would type in chat (no quotes around the whole reply, no "Player says:").
- Keep each reply short: 1-3 sentences, tavern-chat length. Emotes like *nods slowly* are welcome.
- Match the requested tone and the character's speech quirks exactly.
- Stay appropriate to the setting (Azeroth, no modern slang or references).
- Vary the 3 suggestions: one safe, one more expressive, one that advances the scene.
- Return ONLY JSON: {"suggestions":["...","...","..."]}`;

function extractJson(text) {
  try {
    return JSON.parse(text);
  } catch {
    /* fall through */
  }
  const match = text.match(/\{[\s\S]*\}/);
  if (match) {
    try {
      return JSON.parse(match[0]);
    } catch {
      /* fall through */
    }
  }
  return null;
}

const AI_TIMEOUT_MS = 30_000;

async function callAIMessages(messages) {
  const or = config.openrouter || {};
  if (!or.apiKey) return null;
  // Hard timeout: a hung fetch used to block the whole poller for tens of
  // minutes (processing=true, no logs) — every request behind it starved.
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(new Error(`AI request timed out after ${AI_TIMEOUT_MS / 1000}s`)), AI_TIMEOUT_MS);
  try {
    const res = await fetch(`${or.baseUrl || 'https://openrouter.ai/api/v1'}/chat/completions`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${or.apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: or.model || 'deepseek/deepseek-v4-flash',
        temperature: 0.9,
        messages,
      }),
      signal: ctrl.signal,
    });
    if (!res.ok) {
      const body = await res.text();
      throw new Error(`OpenRouter ${res.status}: ${body.slice(0, 300)}`);
    }
    const data = await res.json();
    return data?.choices?.[0]?.message?.content || '';
  } finally {
    clearTimeout(timer);
  }
}

function callAI(systemPrompt, userMsg) {
  return callAIMessages([
    { role: 'system', content: systemPrompt },
    { role: 'user', content: userMsg },
  ]);
}

async function generateWithAI(payload) {
  const or = config.openrouter || {};
  if (!or.apiKey) return null;

  const character = payload.character || {};
  const scene = payload.scene || {};
  const guildBlock = guildPromptBlock(await getGuild(config));
  const userMsg = [
    `CHARACTER SHEET`,
    `Name: ${character.name || 'unknown'}`,
    `Race/Class: ${character.raceClass || 'unknown'}`,
    `Personality: ${character.personality || 'friendly newcomer'}`,
    `Speech quirks: ${character.quirks || 'none'}`,
    ``,
    guildBlock,
    `SCENE`,
    `Setting: ${scene.setting || 'a tavern'}`,
    `Talking to: ${scene.withWhom || 'another player'}`,
    `What happened / topic: ${scene.recent || 'a casual conversation'}`,
    ``,
    `Tone: ${payload.tone || 'Neutral'}`,
    `Write ${payload.count || 3} distinct suggestions as JSON.`,
  ].join('\n');

  const content = await callAI(SYSTEM_PROMPT, userMsg);
  const parsed = extractJson(content);
  if (!parsed || !Array.isArray(parsed.suggestions) || parsed.suggestions.length === 0) {
    throw new Error(`AI returned no suggestions: ${content.slice(0, 200)}`);
  }
  return parsed.suggestions.map((s) => String(s).trim()).filter(Boolean);
}

// AI sheet draft: expands the user's personality notes into personality + quirks.
const DRAFT_SYSTEM_PROMPT = `You are a World of Warcraft roleplay character-sheet writer for a NEW RPPVP player.
Given rough personality notes (and the character's race/class), write a polished character sheet.
Rules:
- "personality": 1-2 sentences, third person, capturing the user's notes (keep their intent, just smooth the wording).
- "quirks": 2-4 short speech habits the character would actually type in chat (catchphrases, capitalization habits, emote style). Keep any quirks the user already mentioned.
- World-appropriate: Azeroth flavor, no modern slang.
- Return ONLY JSON: {"personality":"...","quirks":"..."}`;

async function generateDraftWithAI(payload) {
  const or = config.openrouter || {};
  if (!or.apiKey) return null;
  const character = payload.character || {};
  const guildBlock = guildPromptBlock(await getGuild(config));
  const userMsg = [
    `RACE/CLASS: ${character.raceClass || 'unknown'}`,
    `ROUGH NOTES: ${character.personality || '(none given)'}`,
    `EXISTING QUIRKS (keep these): ${character.quirks || '(none)'}`,
    guildBlock,
    `Write the sheet as JSON.`,
  ].join('\n');
  const content = await callAI(DRAFT_SYSTEM_PROMPT, userMsg);
  const parsed = extractJson(content);
  if (!parsed || (!parsed.personality && !parsed.quirks)) {
    throw new Error(`AI returned no draft: ${String(content).slice(0, 200)}`);
  }
  // The model sometimes returns quirks as an array — join into one line
  const quirks = Array.isArray(parsed.quirks)
    ? parsed.quirks.map((q) => String(q).trim()).filter(Boolean).join(' · ')
    : String(parsed.quirks || '').trim();
  return {
    personality: Array.isArray(parsed.personality)
      ? parsed.personality.join(' ')
      : String(parsed.personality || '').trim(),
    quirks,
  };
}

// AI chat: multi-turn discussion about letters, responses, RP etiquette.
const CHAT_SYSTEM_PROMPT = `You are RPHelper, a friendly World of Warcraft roleplay writing assistant for a NEW RPPVP player, chatting inside the game.
The player discusses drafts (letters, chat responses), asks for RP etiquette advice, or brainstorms character ideas.
Rules:
- Chat-sized answers: concise and practical; when asked to write in-character text (a letter, a reply), format it clearly and keep it short.
- Azeroth flavor for in-character samples; no modern references.
- Never write actions or dialogue for other players' characters.
- If essential context is missing, ask one short clarifying question.`;

// Server-side canonical chat history: survives reload-free sends (the
// addon's SavedVariables copy only updates on /reload, so between reloads
// the watcher owns the conversation and ships it back via chatHistoryFull).
const CHAT_HISTORY_FILE = path.join(ROOT, 'chat-history.json');
function loadChatHistory() {
  try {
    const h = JSON.parse(fs.readFileSync(CHAT_HISTORY_FILE, 'utf8').replace(/^\uFEFF/, ''));
    return Array.isArray(h) ? h : [];
  } catch {
    return [];
  }
}
function saveChatHistory(history) {
  try {
    fs.writeFileSync(CHAT_HISTORY_FILE, JSON.stringify(history.slice(-40)), 'utf8');
  } catch (err) {
    logLine(`chat history save failed: ${err.message}`);
  }
}

async function generateChatReply(history) {
  if (!config.openrouter?.apiKey) return null;
  const messages = (Array.isArray(history) ? history : [])
    .slice(-16)
    .map((e) => ({ role: e && e.r === 'a' ? 'assistant' : 'user', content: String((e && e.t) || '') }))
    .filter((m) => m.content);
  if (messages.length === 0 || messages[messages.length - 1].role !== 'user') {
    throw new Error('empty chat message');
  }
  const guildBlock = guildPromptBlock(await getGuild(config));
  const system = guildBlock ? `${CHAT_SYSTEM_PROMPT}\n\n${guildBlock}` : CHAT_SYSTEM_PROMPT;
  const content = await callAIMessages([{ role: 'system', content: system }, ...messages]);
  const text = String(content || '').trim();
  if (!text) throw new Error('AI returned empty chat reply');
  return text;
}

// Offline fallback so the app works with no API key.
function generateOffline(payload) {
  const scene = payload.scene || {};
  const who = (scene.withWhom || 'stranger').trim();
  const where = (scene.setting || 'the tavern').trim();
  const tone = payload.tone || 'Neutral';
  const pools = {
    Neutral: [
      `*glances up from ${where}* "Name's ${'__'} — and you are?"`,
      `*leans against the wall* "Quiet night, considering."`,
      `"Fair enough. What brings you to ${where}?"`,
      `*nods slowly* "Aye. Seen stranger things today."`,
    ],
    'Warm/Friendly': [
      `*smiles and shifts over to make room* "Pull up a chair — there's plenty of room."`,
      `"Ha! You'll get no cold shoulder from me. Sit down, friend."`,
      `*raises a mug* "To new faces then — welcome to ${where}."`,
    ],
    'Gruff/Tough': [
      `*arms crossed, one eyebrow raised* "Speak plain. I've no patience for riddles."`,
      `"Hmph. Words are cheap out here. Show me something real."`,
      `*taps the table twice* "You always this chatty, or is today special?"`,
    ],
    'Witty/Flirty': [
      `*grins* "Careful — keep talking like that and I might start to like you."`,
      `"Is that your best line? I'm willing to hear a second attempt."`,
      `*tilts head with a mock bow* "You have my attention. Do try to keep it."`,
    ],
    'Formal/Noble': [
      `*inclines head politely* "Well met. You honor ${where} with your presence."`,
      `"Indeed. A matter of some import, I take it?"`,
      `*places hand over heart* "Speak freely — courtesy costs me nothing."`,
    ],
    Mysterious: [
      `*says nothing for a long moment, then, quietly* "...That depends on who's asking."`,
      `*glances toward the shadows* "Some questions are safer left unasked."`,
      `"You feel it too, then. I was wondering when you'd notice."`,
    ],
  };
  const pool = pools[tone] || pools.Neutral;
  const count = Math.min(payload.count || 3, pool.length);
  // Deterministic-ish rotation so repeated clicks vary
  const offset = Math.floor(Math.random() * pool.length);
  const out = [];
  for (let i = 0; i < count; i++) {
    out.push(pool[(offset + i) % pool.length].replace('__', 'you tell me later'));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Minimal status page (blank by design — the GUI lives in-game)
// ---------------------------------------------------------------------------
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
};

function sendJson(res, status, obj) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(obj));
}

function serveStatic(req, res) {
  let urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (urlPath === '/') urlPath = '/index.html';
  const filePath = path.join(PUBLIC_DIR, urlPath);
  if (!filePath.startsWith(PUBLIC_DIR)) {
    res.writeHead(403);
    return res.end('forbidden');
  }
  fs.readFile(filePath, (err, buf) => {
    if (err) {
      res.writeHead(404);
      return res.end('not found');
    }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream' });
    res.end(buf);
  });
}

/** Browser chat: instant, no reload — the canonical conversation lives in
 * chat-history.json (shared with the addon's legacy chat lane). */
async function handleChatPost(req, res) {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', async () => {
    if (chatBusy) return sendJson(res, 429, { ok: false, error: 'still thinking about the last message…' });
    chatBusy = true;
    try {
      let text = '';
      try {
        text = String(JSON.parse(body || '{}').text || '').trim();
      } catch {
        return sendJson(res, 400, { ok: false, error: 'bad JSON' });
      }
      if (!text) return sendJson(res, 400, { ok: false, error: 'empty message' });
      if (!config.openrouter?.apiKey) {
        return sendJson(res, 503, { ok: false, error: 'No API key — add one to config.json and restart the watcher.' });
      }
      const history = loadChatHistory();
      history.push({ r: 'u', t: text });
      let reply = null;
      let error = null;
      try {
        reply = await generateChatReply(history);
      } catch (err) {
        error = err.message;
      }
      if (!reply) {
        history.pop(); // don't keep a message we couldn't answer
        logLine(`browser chat FAILED: ${error || 'empty reply'}`);
        return sendJson(res, 502, { ok: false, error: error || 'AI returned an empty reply' });
      }
      history.push({ r: 'a', t: reply });
      saveChatHistory(history);
      stats.lastRequestAt = new Date().toISOString();
      logLine(`browser chat (${text.length} chars) -> reply (${reply.length} chars)`);
      return sendJson(res, 200, { ok: true, reply, history });
    } catch (err) {
      logLine(`chat endpoint error: ${err.stack || err.message}`);
      return sendJson(res, 500, { ok: false, error: err.message });
    } finally {
      chatBusy = false;
    }
  });
}

/** Everything the frontend needs in one poll: status, character, latest
 * in-game suggestions, and the chat history. */
async function handleState(res) {
  const wowRoot = deriveWowRoot(config);
  const sv = wowRoot ? findSavedVariablesFile(wowRoot) : null;
  let svData = {};
  try {
    if (sv) svData = parseSavedVariables(fs.readFileSync(sv, 'utf8'));
  } catch { /* stale/missing is fine */ }
  const guild = await getGuild(config);
  let h = {};
  try {
    h = parseSavedVariables(fs.readFileSync(resolveHandoffTarget().file, 'utf8'));
  } catch { /* no handoff yet */ }
  const target = resolveHandoffTarget();
  return sendJson(res, 200, {
    ok: true,
    status: {
      model: config.openrouter?.model || null,
      hasApiKey: Boolean(config.openrouter?.apiKey),
      uptimeSec: Math.round(process.uptime()),
      requestsServed: stats.requestsServed,
      lastRequestAt: stats.lastRequestAt,
      lastError: stats.lastError,
      svPath: sv,
      handoffPath: target.file,
    },
    character: {
      name: svData.name || null,
      realm: svData.realm || null,
      race: svData.race || null,
      class: svData.class || null,
      level: svData.level || null,
      spec: svData.spec || null,
      guild: svData.guild || null,
      zone: svData.zone || null,
      money: svData.money ?? null,
      itemLevel: svData.itemLevel ?? null,
      hp: svData.hp ?? null,
      hpMax: svData.hpMax ?? null,
      updatedAt: svData.updatedAt || null,
    },
    scene: svData.sceneDraft || '',
    personality: svData.personality || '',
    quirks: svData.quirks || '',
    tone: svData.tone || 'Neutral',
    count: svData.count || 3,
    suggestions: Array.isArray(h.suggestions) ? h.suggestions : [],
    suggestionsAt: h.generatedAt || null,
    suggestionsTone: h.tone || null,
    suggestionsScene: h.scene || null,
    chat: loadChatHistory(),
    guild,
    guildEnabled: guildEnabled(config),
    guildName: config.guild?.name || (guild && guild.name) || '',
  });
}

/** Read a JSON request body as a promise. */
function readBody(req) {
  return new Promise((resolve) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => resolve(body));
  });
}

async function handleGuildMembers(req, res, url) {
  if (req.method === 'POST') {
    const body = await readBody(req);
    let member;
    try {
      member = JSON.parse(body || '{}');
    } catch {
      return sendJson(res, 400, { ok: false, error: 'bad JSON' });
    }
    if (!member.name || !String(member.name).trim()) {
      return sendJson(res, 400, { ok: false, error: 'name required' });
    }
    const guild = await upsertMember(config, member);
    if (!guild) return sendJson(res, 503, { ok: false, error: 'MongoDB unavailable (check config.mongodb.uri)' });
    logLine(`guild member upserted: ${member.name}`);
    return sendJson(res, 200, { ok: true, guild });
  }
  if (req.method === 'DELETE') {
    const name = url.searchParams.get('name');
    if (!name) return sendJson(res, 400, { ok: false, error: 'name query param required' });
    const guild = await removeMember(config, name);
    if (!guild) return sendJson(res, 503, { ok: false, error: 'MongoDB unavailable' });
    logLine(`guild member removed: ${name}`);
    return sendJson(res, 200, { ok: true, guild });
  }
  return sendJson(res, 405, { ok: false, error: 'use POST (upsert) or DELETE ?name=' });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://x');
    const { pathname } = url;
    if (pathname === '/api/chat' && req.method === 'POST') {
      return handleChatPost(req, res);
    }
    if (pathname === '/api/state' && req.method === 'GET') {
      return handleState(res);
    }
    if (pathname === '/api/guild' && req.method === 'GET') {
      const guild = await getGuild(config);
      return sendJson(res, guild ? 200 : 503, { ok: Boolean(guild), guild, enabled: guildEnabled(config) });
    }
    if (pathname === '/api/guild' && req.method === 'POST') {
      const body = await readBody(req);
      let name = '';
      try { name = String(JSON.parse(body || '{}').name || '').trim(); } catch { /* empty */ }
      if (!name) return sendJson(res, 400, { ok: false, error: 'name required' });
      config.guild = { ...(config.guild || {}), name };
      try {
        const cfgPath = path.join(ROOT, 'config.json');
        const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8').replace(/^\uFEFF/, ''));
        cfg.guild = { ...(cfg.guild || {}), name };
        fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2), 'utf8');
      } catch (err) {
        logLine(`guild name persist failed: ${err.message}`);
      }
      logLine(`guild name set: ${name}`);
      setGuildName(config, name).catch(() => {}); // also update the shared doc
      return sendJson(res, 200, { ok: true, name });
    }
    if (pathname === '/api/guild/members') {
      return handleGuildMembers(req, res, url);
    }
    if (pathname === '/api/log') {
      return sendJson(res, 200, {
        ok: true,
        text: buildDiagnosticText(),
        file: path.join(ROOT, 'RPHelperLog.txt'),
      });
    }
    if (pathname === '/api/status') {
      const target = resolveHandoffTarget();
      const wowRoot = deriveWowRoot(config);
      return sendJson(res, 200, {
        ok: true,
        hasApiKey: Boolean(config.openrouter?.apiKey),
        model: config.openrouter?.model || null,
        handoffPath: target.file,
        handoffSource: target.where,
        svPath: wowRoot ? findSavedVariablesFile(wowRoot) : null,
        uptimeSec: Math.round(process.uptime()),
        requestsServed: stats.requestsServed,
        lastRequestAt: stats.lastRequestAt,
        lastError: stats.lastError,
        lastPollAt: stats.lastPollAt,
        processingForSec: processing ? Math.round((Date.now() - processingSince) / 1000) : 0,
        lastMainId,
        lastChatId,
      });
    }
    if (req.method === 'GET') return serveStatic(req, res);
    res.writeHead(404);
    res.end('not found');
  } catch (err) {
    console.error(`[http] ${err.stack || err.message}`);
    sendJson(res, 500, { ok: false, error: err.message });
  }
});

// ---------------------------------------------------------------------------
// Game request watcher
// The addon writes a pending request (reqId/reqStatus/...) into its
// SavedVariables on /reload; we poll that file, generate, and write the
// answer into the handoff file. The addon auto-reloads once more to show it.
// lastProcessedId is persisted so a watcher/exe restart never re-fires an
// already-answered request.
// ---------------------------------------------------------------------------
const STATE_FILE = path.join(ROOT, '.rphelper-state.json');
function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    return {};
  }
}
function saveState(obj) {
  try {
    fs.writeFileSync(STATE_FILE, JSON.stringify(obj), 'utf8');
  } catch (err) {
    console.warn(`[state] could not persist: ${err.message}`);
  }
}
const _state = loadState();
let lastMainId = _state.lastMainId ?? _state.lastProcessedId ?? null; // migrate old key
let lastChatId = _state.lastChatId ?? null;
let errLogOffset = _state.errLogOffset ?? null; // General.log tail position (null = start at end)
// Processed-id set: single last-id dedupe broke when the error channel
// processed a NEW id — the stale (already-answered) SV id then looked
// "unprocessed" and re-fired, wasting an AI call.
let processedIds = new Set((_state.processedIds || []).map(String));
let lastSheetSig = _state.lastSheetSig ?? null; // guild sheet auto-push dedupe
let lastHeartbeatId = _state.lastHeartbeatId ?? null; // live snapshot dedupe
if (lastChatId) processedIds.add(String(lastChatId));
if (lastMainId) processedIds.add(String(lastMainId));
function markProcessed(id) {
  processedIds.add(String(id));
  while (processedIds.size > 60) {
    processedIds.delete(processedIds.values().next().value);
  }
}
let processing = false;
let processingSince = 0;
let stallLogged = false;

/** Process ONE request (serial — single handoff writer, but timeout-bounded).
 * lane 'chat' writes to the chat mailbox, 'main' to the suggestions mailbox. */
async function runRequest({ lane, reqId, parsed }) {
  processing = true;
  processingSince = Date.now();
  stallLogged = false;
  if (lane === 'chat') lastChatId = reqId;
  else lastMainId = reqId;
  markProcessed(reqId);
  try {
    const payload = {
      character: {
        name: parsed.name || 'unknown',
        raceClass: [parsed.race, parsed.class].filter(Boolean).join(' '),
        personality: parsed.reqPersonality || '',
        quirks: parsed.reqQuirks || '',
      },
      scene: {
        setting: parsed.reqScene || 'a tavern',
        withWhom: '',
        recent: parsed.reqTopic || '',
      },
      tone: parsed.reqTone || 'Neutral',
      count: Number(parsed.reqCount) || 3,
    };

    const isChat = lane === 'chat';
    const isDraft = !isChat && parsed.reqKind === 'draft';
    const kindLabel = isChat ? 'chat' : isDraft ? 'sheet draft' : payload.tone;
    logLine(`game request ${reqId} (${kindLabel}) - generating...`);
    let suggestions = null;
    let draft = null;
    let chatReply = null;
    let chatHistoryFull = null;
    let error = null;
    if (config.openrouter?.apiKey) {
      try {
        if (isChat) {
          // Server-side history (survives reload-free sends); fall back to
          // the addon's SavedVariables copy for the very first conversation.
          let history = loadChatHistory();
          if (history.length === 0) {
            try {
              history = JSON.parse(parsed.chatJson || '[]');
            } catch {
              history = [];
            }
            if (!Array.isArray(history)) history = [];
          }
          const pending = String(parsed.chatPendingText || '').trim();
          if (pending && (history.length === 0 || history[history.length - 1].t !== pending)) {
            history.push({ r: 'u', t: pending });
          }
          chatReply = await generateChatReply(history);
          if (chatReply) {
            history.push({ r: 'a', t: chatReply });
            saveChatHistory(history);
          }
          chatHistoryFull = history;
        } else if (isDraft) {
          draft = await generateDraftWithAI(payload);
        } else {
          suggestions = await generateWithAI(payload);
        }
      } catch (err) {
        error = err.message;
        logLine(`AI FAILED: ${err.message}`);
      }
    }
    if (!chatReply && !draft && !suggestions && !error) {
      if (isChat) {
        chatReply = "Offline mode: I can't chat without an API key. Add your OpenRouter key to config.json and restart the watcher.";
      } else if (isDraft) {
        draft = {
          personality: (payload.character.personality || 'A friendly adventurer').trim(),
          quirks: 'says "well met", keeps replies short, ends with a friendly sign-off',
        };
      } else {
        suggestions = generateOffline(payload);
      }
    }
    if (error) { suggestions = []; draft = null; chatReply = null; }

    const target = isChat ? resolveChatHandoffTarget() : resolveHandoffTarget();
    fs.mkdirSync(path.dirname(target.file), { recursive: true });
    fs.writeFileSync(
      target.file,
      buildHandoffFile({
        suggestions: suggestions || [],
        scene: payload.scene.setting,
        tone: payload.tone,
        requestId: String(reqId),
        error,
        kind: isChat ? 'chat' : isDraft ? 'draft' : 'suggestions',
        personality: draft ? draft.personality : undefined,
        quirks: draft ? draft.quirks : undefined,
        chatReply,
        chatHistoryFull,
        globalName: isChat ? 'RPHelperChatHandoffData' : 'RPHelperHandoffData',
      }),
      'utf8'
    );
    logLine(
      isChat
        ? `wrote chat reply${error ? ` (error: ${error})` : ''} -> ${target.file}`
        : isDraft
          ? `wrote sheet draft${error ? ` (error: ${error})` : ''} -> ${target.file}`
          : `wrote ${suggestions.length} suggestions${error ? ` (error: ${error})` : ''} -> ${target.file}`
    );
    stats.requestsServed += 1;
    stats.lastRequestAt = new Date().toISOString();
    stats.lastError = error || null;
  } catch (err) {
    logLine(`ERROR ${err.stack || err.message}`);
    stats.lastError = err.message;
  } finally {
    saveState({ lastMainId, lastChatId, errLogOffset, processedIds: [...processedIds] });
    processing = false;
  }
}

/** One poll tick: chat lane has PRIORITY (it used to starve behind main
 * requests), main lane skips chat-kind requests entirely. */
async function poll() {
  stats.lastPollAt = new Date().toISOString();
  if (processing) {
    const heldFor = Date.now() - processingSince;
    if (heldFor > 35_000 && !stallLogged) {
      stallLogged = true;
      logLine(`STALL: AI call running for ${Math.round(heldFor / 1000)}s (should be impossible with ${AI_TIMEOUT_MS / 1000}s timeout)`);
    }
    return;
  }

  // Error-channel requests first (fresh user actions, arrived without any
  // reload — the whole point of v0.3.0).
  if (pendingErrReqs.length) {
    const obj = pendingErrReqs.shift();
    const isChat = obj.kind === 'chat';
    const id = String(obj.id);
    if (!processedIds.has(id)) {
      await runRequest({ lane: isChat ? 'chat' : 'main', reqId: id, parsed: buildParsedFromError(obj) });
    }
    return;
  }

  const wowRoot = deriveWowRoot(config);
  if (!wowRoot) return;
  const sv = findSavedVariablesFile(wowRoot);
  if (!sv) return;

  let parsed;
  try {
    parsed = parseSavedVariables(fs.readFileSync(sv, 'utf8'));
  } catch {
    return;
  }

  // Chat lane — keyed on the flat chatPendingId field (immune to the main
  // request fields being overwritten by a newer suggestions/draft send).
  let chatId = parsed.chatPendingId ? String(parsed.chatPendingId) : null;
  if (!chatId && parsed.reqKind === 'chat' && parsed.reqStatus === 'pending' && parsed.reqId) {
    chatId = String(parsed.reqId); // legacy fallback (pre-0.2.4 addon)
  }
  if (chatId && !processedIds.has(chatId)) {
    await runRequest({ lane: 'chat', reqId: chatId, parsed });
    return;
  }

  // Main lane (suggestions / sheet draft)
  const reqId = parsed.reqId ? String(parsed.reqId) : null;
  if (reqId && !processedIds.has(reqId) && parsed.reqStatus === 'pending' && parsed.reqKind !== 'chat') {
    await runRequest({ lane: 'main', reqId, parsed });
  }

  // Auto-push this member's sheet to the shared guild roster when it changes
  // (each guildie's watcher syncs their OWN character to Atlas — that's how
  // the roster fills itself without anyone typing anything).
  if (guildEnabled(config) && parsed.name) {
    const sig = [parsed.name, parsed.level, parsed.personality, parsed.quirks].join('|');
    if (sig !== lastSheetSig) {
      lastSheetSig = sig;
      saveState({ lastMainId, lastChatId, errLogOffset, processedIds: [...processedIds], lastSheetSig });
      upsertMember(config, {
        name: parsed.name,
        race: parsed.race,
        class: parsed.class,
        level: parsed.level,
        personality: parsed.personality,
        quirks: parsed.quirks,
        updatedBy: 'addon',
      }).then((g) => {
        if (g) logLine(`guild sheet synced: ${parsed.name} (${g.members.length} members in roster)`);
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Diagnostic export — the WATCHER writes the log file (the addon itself
// cannot: io.open is sandboxed and CopyToClipboard is a protected API).
// Composed from the addon's SavedVariables events + handoff + watcher stats.
// ---------------------------------------------------------------------------
let lastExportedLog = '';
let lastExportErr = null;

// ---------------------------------------------------------------------------
// Error-channel requests (v0.3.0): the addon raises a deliberate Lua error
// carrying the request payload — General.log receives errors in REAL-TIME
// (verified: error storms logged with per-second timestamps during play),
// so sends need NO reload. SavedVariables remain the fallback path.
// ---------------------------------------------------------------------------
const pendingErrReqs = [];

function tailGeneralLog() {
  const wowRoot = deriveWowRoot(config);
  if (!wowRoot) return;
  const logPath = path.join(wowRoot, 'Logs', 'General.log');
  let size;
  try {
    size = fs.statSync(logPath).size;
  } catch {
    return;
  }
  if (errLogOffset === null) {
    errLogOffset = size; // first run: start at the end (ignore history)
    return;
  }
  if (size < errLogOffset) errLogOffset = 0; // truncated/rotated
  if (size === errLogOffset) return;
  let text;
  try {
    const fd = fs.openSync(logPath, 'r');
    const len = size - errLogOffset;
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, errLogOffset);
    fs.closeSync(fd);
    text = buf.toString('utf8');
    errLogOffset = size;
  } catch {
    return;
  }
  const re = /RPHelperREQ:(\{[^\r\n]*\})/g;
  let m;
  while ((m = re.exec(text))) {
    let obj;
    try {
      obj = JSON.parse(m[1]);
    } catch (err) {
      logLine(`REQ payload unparseable: ${err.message}`);
      continue;
    }
    const id = obj.id ? String(obj.id) : null;
    if (!id) continue;
    // Heartbeats are live player snapshots — merge into the roster, never
    // queue them as AI requests.
    if (obj.kind === 'heartbeat') {
      if (id === lastHeartbeatId) continue;
      lastHeartbeatId = id;
      try {
        const data = JSON.parse(obj.data || '{}');
        if (data.name && guildEnabled(config)) {
          mergeMember(config, data).then((g) => {
            if (g) logLine(`heartbeat: ${data.name} @ ${data.zone || '?'} (roster ${g.members.length})`);
          });
        }
      } catch (err) {
        logLine(`heartbeat parse failed: ${err.message}`);
      }
      saveState({ lastMainId, lastChatId, errLogOffset, processedIds: [...processedIds], lastSheetSig, lastHeartbeatId });
      continue;
    }
    if (processedIds.has(id)) continue;
    if (pendingErrReqs.some((p) => String(p.id) === id)) continue;
    pendingErrReqs.push(obj);
    logLine(`REQ via error channel: kind=${obj.kind} id=${id} (no reload needed)`);
  }
  saveState({ lastMainId, lastChatId, errLogOffset, processedIds: [...processedIds] });
}

/** Merge an error-channel payload with the last on-disk SavedVariables
 * (character info etc. is stable; payload fields override the stale ones). */
function buildParsedFromError(obj) {
  let disk = {};
  try {
    const wowRoot = deriveWowRoot(config);
    const sv = wowRoot ? findSavedVariablesFile(wowRoot) : null;
    if (sv) disk = parseSavedVariables(fs.readFileSync(sv, 'utf8'));
  } catch {
    /* stale disk is fine */
  }
  return {
    ...disk,
    reqKind: obj.kind,
    reqId: obj.id,
    reqStatus: 'pending',
    chatPendingId: obj.kind === 'chat' ? obj.id : undefined,
    chatPendingText: obj.kind === 'chat' ? String(obj.text || '') : undefined,
    reqScene: obj.scene ?? disk.reqScene,
    reqTone: obj.tone ?? disk.reqTone,
    reqCount: obj.count ?? disk.reqCount,
    reqPersonality: obj.personality ?? disk.reqPersonality,
    reqQuirks: obj.quirks ?? disk.reqQuirks,
  };
}

// CVar flush probe: the addon sets `rphNonce` via SetCVar at every load.
// Each NEW nonce value appearing in config-cache.wtf = a CVar flush event.
// If flushes happen during play (not just at reload), v0.3.0 can send
// requests over the CVar channel and kill the send-reload entirely.
let lastCvarNonce = null;
function checkCVarFlush() {
  const wowRoot = deriveWowRoot(config);
  if (!wowRoot) return;
  const accountDir = path.join(wowRoot, 'WTF', 'Account');
  let best = null;
  const walk = (dir, depth) => {
    if (depth > 5) return;
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        walk(full, depth + 1);
      } else if (e.name === 'config-cache.wtf') {
        let mtime = 0;
        try {
          mtime = fs.statSync(full).mtimeMs;
        } catch {
          continue;
        }
        if (!best || mtime > best.mtime) best = { path: full, mtime };
      }
    }
  };
  walk(accountDir, 0);
  if (!best) return;
  try {
    const text = fs.readFileSync(best.path, 'utf8');
    const m = text.match(/SET rphNonce\s+"([^"]*)"/);
    if (m && m[1] !== lastCvarNonce) {
      const age = Math.round((Date.now() - best.mtime) / 1000);
      logLine(`CVAR flush: rphNonce=${m[1]} (file age ${age}s) - correlate with LOAD times to judge mid-play flush`);
      lastCvarNonce = m[1];
    }
  } catch {
    /* unreadable - retry next tick */
  }
}

function extractAddonEvents(raw) {
  const block = raw.match(/\["events"\]\s*=\s*\{([\s\S]*?)\}/);
  if (!block) return [];
  const out = [];
  const re = /"((?:[^"\\]|\\.)*)"/g;
  let m;
  while ((m = re.exec(block[1]))) out.push(unescapeLuaString(m[1]));
  return out;
}

function buildDiagnosticText() {
  const wowRoot = deriveWowRoot(config);
  const sv = wowRoot ? findSavedVariablesFile(wowRoot) : null;
  const lines = [];
  lines.push(`RPHelper diagnostic export (watcher) ${new Date().toISOString()}`);
  lines.push(`model: ${config.openrouter?.model || '?'}  apiKey: ${config.openrouter?.apiKey ? 'configured' : 'MISSING'}`);
  lines.push(`uptime: ${Math.round(process.uptime())}s  served: ${stats.requestsServed}  last: ${stats.lastRequestAt || '-'}  lastError: ${stats.lastError || '-'}`);
  lines.push(`lastPoll: ${stats.lastPollAt || '-'}  processing: ${processing ? `${Math.round((Date.now() - processingSince) / 1000)}s` : 'no'}  lastMainId: ${lastMainId || '-'}  lastChatId: ${lastChatId || '-'}`);
  lines.push(`sv file: ${sv || 'NOT FOUND'}`);
  if (!sv) return lines.join('\n');

  let raw = '';
  let parsed = {};
  try {
    raw = fs.readFileSync(sv, 'utf8');
    parsed = parseSavedVariables(raw);
  } catch (err) {
    lines.push(`sv read error: ${err.message}`);
    return lines.join('\n');
  }

  let h = {};
  try {
    h = parseSavedVariables(fs.readFileSync(resolveHandoffTarget().file, 'utf8'));
  } catch { /* handoff missing/empty */ }

  lines.push('');
  lines.push('-- request state (from addon SavedVariables) --');
  lines.push(`reqStatus=${parsed.reqStatus} reqKind=${parsed.reqKind} reqId=${parsed.reqId} attempts=${parsed.reqAttempts}`);
  lines.push(`chatPendingId=${parsed.chatPendingId || '-'} chatPendingText=${parsed.chatPendingText || '-'}`);
  lines.push(`tone=${parsed.tone} count=${parsed.reqCount} scene=${parsed.reqScene || '-'}`);
  lines.push('');
  lines.push('-- handoff file (watcher answers) --');
  lines.push(`kind=${h.kind || '-'} requestId=${h.requestId || '-'} generatedAt=${h.generatedAt || '-'} error=${h.error || '-'} suggestions=${h.suggestions ? 'present' : 'none'}`);
  lines.push('');
  lines.push('-- player --');
  lines.push(`${parsed.name || '?'}-${parsed.realm || '?'} ${parsed.race || ''} ${parsed.class || ''} lvl ${parsed.level || '?'}`);
  lines.push('');
  lines.push('-- addon events (newest first) --');
  // eventsText is a plain string field the addon mirrors on every event —
  // the parser flattens tables, so this is the reliable path.
  const eventsText = String(parsed.eventsText || '').trim();
  const events = eventsText ? eventsText.split('\n') : extractAddonEvents(raw);
  if (events.length) lines.push(...events);
  else lines.push('(no events recorded)');
  return lines.join('\n');
}

function exportAddonLog() {
  try {
    const text = buildDiagnosticText();
    if (text === lastExportedLog) return;
    lastExportedLog = text;
    lastExportErr = null;
    fs.writeFileSync(path.join(ROOT, 'RPHelperLog.txt'), text, 'utf8');
  } catch (err) {
    if (err.message !== lastExportErr) {
      lastExportErr = err.message;
      logLine(`log export failed: ${err.message}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------
const target = resolveHandoffTarget();
const wowRoot = deriveWowRoot(config);
server.listen(PORT, '127.0.0.1', () => {
  console.log('RPHelper companion running');
  console.log(`  API key:  ${config.openrouter?.apiKey ? 'configured' : 'MISSING (offline templates only)'}`);
  console.log(`  Model:    ${config.openrouter?.model || 'deepseek/deepseek-v4-flash'}`);
  console.log(`  Handoff:  ${target.file} (${target.where})`);
  console.log(`  Requests: ${wowRoot ? findSavedVariablesFile(wowRoot) || 'not found yet (log in + /reload)' : 'WoW install not found'}`);
  console.log(`  Status:   http://127.0.0.1:${PORT} (blank page, health only)`);
  console.log(`  Log file: ${path.join(ROOT, 'RPHelperLog.txt')} (auto-updates)`);
  console.log('  Polling for in-game requests every 1s (chat lane has priority).');
});

// Self-rescheduling loop: the next tick is queued only after the current
// one finishes — a slow/hung tick can never silently skip future polls
// (unlike setInterval, which was part of the starvation problem).
async function pollLoop() {
  try {
    exportAddonLog();
    checkCVarFlush();
    tailGeneralLog();
    await poll();
  } catch (e) {
    logLine(`poll error: ${e.stack || e.message}`);
  }
  setTimeout(pollLoop, 1000);
}
pollLoop();