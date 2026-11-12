// ---------------------------------------------------------------------------
// Guild layer — MongoDB Atlas (WoWForever DB, `guild` collection).
// One document: { _id: "guild", name, members: [{ name, race, class, level,
// personality, quirks, note, updatedBy, updatedAt }], updatedAt }.
// Every watcher instance with the same connection string shares the roster,
// so the AI on any member's machine knows the whole guild.
// All calls are best-effort: Atlas being unreachable must never break the
// local watcher — callers get null and fall back to local data.
// ---------------------------------------------------------------------------
import { MongoClient } from 'mongodb';

let client = null;
let dbHandle = null;
let connecting = false;
let disabled = false;
const GUILD_ID = 'guild';

export function guildEnabled(config) {
  return Boolean(config?.mongodb?.uri) && !disabled;
}

async function ensureDb(config) {
  if (disabled) return null;
  if (dbHandle) return dbHandle;
  if (connecting) return null; // first caller is still connecting
  connecting = true;
  try {
    client = new MongoClient(config.mongodb.uri, {
      serverSelectionTimeoutMS: 4000, // fail fast — never stall the poll loop
      connectTimeoutMS: 4000,
    });
    await client.connect();
    dbHandle = client.db(config.mongodb.db || 'WoWForever');
    connecting = false;
    return dbHandle;
  } catch (err) {
    connecting = false;
    disabled = true; // stop retrying this session (log once, keep serving)
    console.error(`[guild] MongoDB unavailable: ${err.message}`);
    return null;
  }
}

function normalizeMember(m) {
  if (!m || !m.name) return null;
  return {
    name: String(m.name).trim(),
    race: String(m.race || '').trim(),
    class: String(m.class || '').trim(),
    level: m.level ? Number(m.level) : null,
    personality: String(m.personality || '').trim(),
    quirks: String(m.quirks || '').trim(),
    note: String(m.note || '').trim(),
    updatedBy: String(m.updatedBy || '').trim(),
    updatedAt: new Date().toISOString(),
  };
}

/** Full roster (or null when unavailable). */
export async function getGuild(config) {
  const db = await ensureDb(config);
  if (!db) return null;
  try {
    const doc = await db.collection('guild').findOne({ _id: GUILD_ID });
    if (!doc) return { name: config?.guild?.name || 'Guild', members: [] };
    return { name: doc.name || 'Guild', members: Array.isArray(doc.members) ? doc.members : [] };
  } catch (err) {
    console.error(`[guild] read failed: ${err.message}`);
    return null;
  }
}

/** Upsert one member (by name, case-insensitive). Returns roster or null. */
export async function upsertMember(config, member) {
  const clean = normalizeMember(member);
  if (!clean) return null;
  const db = await ensureDb(config);
  if (!db) return null;
  try {
    const col = db.collection('guild');
    await col.updateOne(
      { _id: GUILD_ID },
      {
        $set: { name: config?.guild?.name || 'Guild', updatedAt: new Date().toISOString() },
        $pull: { members: { name: new RegExp(`^${escapeRegex(clean.name)}$`, 'i') } },
      }
    );
    await col.updateOne(
      { _id: GUILD_ID },
      { $push: { members: clean }, $set: { updatedAt: new Date().toISOString() } },
      { upsert: true }
    );
    return getGuild(config);
  } catch (err) {
    console.error(`[guild] upsert failed: ${err.message}`);
    return null;
  }
}

/** Merge live data into an existing member (preserves personality/quirks/
 * note — heartbeats only refresh the live fields). Returns roster or null. */
export async function mergeMember(config, live) {
  if (!live || !live.name) return null;
  const db = await ensureDb(config);
  if (!db) return null;
  try {
    const col = db.collection('guild');
    const doc = await col.findOne({ _id: GUILD_ID });
    const members = (doc && Array.isArray(doc.members) ? doc.members : []);
    const idx = members.findIndex((m) => String(m.name).toLowerCase() === String(live.name).toLowerCase());
    const base = idx >= 0 ? members[idx] : { name: String(live.name) };
    const merged = {
      ...base,
      name: String(live.name),
      race: live.race || base.race || '',
      class: live.class || base.class || '',
      level: live.level ?? base.level ?? null,
      spec: live.spec || base.spec || '',
      zone: live.zone || '',
      money: live.money ?? null,
      itemLevel: live.itemLevel ?? null,
      hp: live.hp ?? null,
      hpMax: live.hpMax ?? null,
      realm: live.realm || base.realm || '',
      updatedBy: 'heartbeat',
      updatedAt: new Date().toISOString(),
    };
    if (idx >= 0) members[idx] = merged;
    else members.push(merged);
    await col.updateOne(
      { _id: GUILD_ID },
      { $set: { members, updatedAt: new Date().toISOString() } },
      { upsert: true }
    );
    return { name: (doc && doc.name) || config?.guild?.name || 'Guild', members };
  } catch (err) {
    console.error(`[guild] merge failed: ${err.message}`);
    return null;
  }
}

/** Remove a member by name. Returns roster or null. */
export async function removeMember(config, name) {
  const db = await ensureDb(config);
  if (!db) return null;
  try {
    await db.collection('guild').updateOne(
      { _id: GUILD_ID },
      { $pull: { members: { name: new RegExp(`^${escapeRegex(String(name || '').trim())}$`, 'i') } } }
    );
    return getGuild(config);
  } catch (err) {
    console.error(`[guild] remove failed: ${err.message}`);
    return null;
  }
}

/** Persist the guild name into the shared document (config is local-only). */
export async function setGuildName(config, name) {
  const db = await ensureDb(config);
  if (!db) return null;
  try {
    await db.collection('guild').updateOne(
      { _id: GUILD_ID },
      { $set: { name: String(name), updatedAt: new Date().toISOString() } },
      { upsert: true }
    );
    return getGuild(config);
  } catch (err) {
    console.error(`[guild] set name failed: ${err.message}`);
    return null;
  }
}

function escapeRegex(s) {
  return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Roster formatted for AI prompts (empty string when unavailable). */
export function guildPromptBlock(guild) {
  if (!guild || !Array.isArray(guild.members) || guild.members.length === 0) return '';
  const lines = guild.members.map((m) => {
    const who = [m.race, m.class].filter(Boolean).join(' ') || 'unknown race/class';
    const lvl = m.level ? `, lvl ${m.level}` : '';
    const pers = m.personality ? ` — ${m.personality}` : '';
    const quirks = m.quirks ? ` [quirks: ${m.quirks}]` : '';
    const note = m.note ? ` (${m.note})` : '';
    return `- ${m.name} (${who}${lvl})${pers}${quirks}${note}`;
  });
  return [
    `GUILD ROSTER (${guild.members.length} members) — the player's guildmates; use their real details when they appear in scenes:`,
    ...lines,
    '',
  ].join('\n');
}