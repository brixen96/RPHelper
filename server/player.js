/**
 * Player auto-discovery: reads the RPHelper addon's SavedVariables file from
 * the WoW WTF folder (the addon writes name/class/race there on /reload or
 * logout), with a fallback that scrapes character name+realm from the WTF
 * folder structure itself.
 */
import fs from 'node:fs';
import path from 'node:path';

const WOW_ROOT_CANDIDATES = [
  'C:\\Program Files (x86)\\World of Warcraft\\_forever_',
  'C:\\Program Files\\World of Warcraft\\_forever_',
  'D:\\World of Warcraft\\_forever_',
  'E:\\World of Warcraft\\_forever_',
  'C:\\Program Files (x86)\\World of Warcraft\\_retail_',
  'C:\\Program Files\\World of Warcraft\\_retail_',
  'C:\\Program Files (x86)\\Steam\\steamapps\\common\\World of Warcraft\\_retail_',
  'D:\\World of Warcraft\\_retail_',
  'E:\\World of Warcraft\\_retail_',
  'F:\\World of Warcraft\\_retail_',
  'G:\\World of Warcraft\\_retail_',
  'D:\\Games\\World of Warcraft\\_retail_',
  'E:\\Games\\World of Warcraft\\_retail_',
];

const PLAYER_KEYS = ['name', 'realm', 'race', 'raceToken', 'class', 'classToken', 'level', 'spec', 'sex', 'updatedAt'];

/** Locate the _retail_ root: config.wowRoot -> derived from savedVariablesPath -> known candidates. */
export function deriveWowRoot(config) {
  if (config?.wowRoot && fs.existsSync(config.wowRoot)) return config.wowRoot;
  const hp = String(config?.savedVariablesPath || '').replace(/\//g, '\\');
  const marker = '\\Interface\\AddOns\\';
  const idx = hp.indexOf(marker);
  if (idx > 0) {
    const root = hp.slice(0, idx);
    if (fs.existsSync(root)) return root;
  }
  return WOW_ROOT_CANDIDATES.find((c) => fs.existsSync(c)) || null;
}

/**
 * Find the newest addon SavedVariables file under WTF\Account.
 * CRITICAL: WoW names SV files after the ADDON FOLDER (RPHelper.lua),
 * not after the variable inside it (RPHelperDB.lua). Account-wide
 * (## SavedVariables:) files live in WTF\Account\<acct>\SavedVariables\,
 * per-character ones in WTF\Account\<acct>\<realm>\<char>\SavedVariables\.
 * Newest mtime wins. RPHelperDB.lua kept as a legacy fallback name.
 */
export function findSavedVariablesFile(wowRoot) {
  const svNames = new Set(['RPHelper.lua', 'RPHelperDB.lua']);
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
      } else if (svNames.has(e.name)) {
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
  return best ? best.path : null;
}

/** Fallback: enumerate characters from WTF folder names (name + realm only), newest first. */
export function discoverCharacters(wowRoot) {
  const accountDir = path.join(wowRoot, 'WTF', 'Account');
  const listDirs = (d) => {
    try {
      return fs
        .readdirSync(d, { withFileTypes: true })
        .filter((e) => e.isDirectory())
        .map((e) => e.name);
    } catch {
      return [];
    }
  };
  const out = [];
  for (const account of listDirs(accountDir)) {
    if (account === 'SavedVariables') continue; // account-wide SV folder, not a realm
    for (const realm of listDirs(path.join(accountDir, account))) {
      for (const char of listDirs(path.join(accountDir, account, realm))) {
        const charDir = path.join(accountDir, account, realm, char);
        let mtime = 0;
        try {
          mtime = fs.statSync(charDir).mtimeMs;
        } catch {
          /* ignore */
        }
        // Character folders are either "Name" or "Name-Realm" (WoW names never contain '-')
        const dash = char.indexOf('-');
        const name = dash > 0 ? char.slice(0, dash) : char;
        const realmName = dash > 0 ? char.slice(dash + 1) : realm;
        out.push({ name, realm: realmName, path: charDir, mtime });
      }
    }
  }
  return out.sort((a, b) => b.mtime - a.mtime);
}

/**
 * Single-pass Lua string unescape — ordered sequential replaces corrupt
 * sequences like \\n (escaped backslash + n) inside JSON values.
 * Exported so the diagnostic exporter can decode event strings too.
 */
export function unescapeLuaString(s) {
  return String(s).replace(/\\(u[0-9a-fA-F]{4}|.)/g, (_, g) => {
    switch (g[0]) {
      case 'n': return '\n';
      case 't': return '\t';
      case 'r': return '\r';
      case 'a': return '\x07';
      case 'b': return '\b';
      case 'f': return '\f';
      case 'v': return '\v';
      case '0': return '\0';
      case 'u': return String.fromCharCode(parseInt(g.slice(1), 16) || 0);
      default: return g; // quotes, backslash, everything else
    }
  });
}

/**
 * Tolerant flattening parser for the simple key=value Lua tables the addon
 * writes. Collects string and number values keyed by name; table values are
 * skipped (their inner keys flatten into the same dict, which is fine since
 * the player keys are unique).
 */
export function parseSavedVariables(text) {
  const out = {};
  const re = /\[?"?([A-Za-z_]\w*)"?\]?\s*=\s*(?:"((?:[^"\\]|\\.)*)"|(-?\d+(?:\.\d+)?))/g;
  let m;
  while ((m = re.exec(text))) {
    const key = m[1];
    if (m[2] !== undefined) {
      out[key] = unescapeLuaString(m[2]);
    } else if (m[3] !== undefined && out[key] === undefined) {
      out[key] = Number(m[3]);
    }
  }
  return out;
}

/** Main entry: what does the game know about the current player? */
export function getPlayerInfo(config) {
  const wowRoot = deriveWowRoot(config);
  if (!wowRoot) {
    return { found: false, hint: 'WoW install not found — set "wowRoot" in config.json' };
  }

  const sv = findSavedVariablesFile(wowRoot);
  if (sv) {
    try {
      const parsed = parseSavedVariables(fs.readFileSync(sv, 'utf8'));
      if (parsed.name) {
        const player = {};
        for (const k of PLAYER_KEYS) {
          if (parsed[k] !== undefined) player[k] = parsed[k];
        }
        return { found: true, source: 'savedvariables', path: sv, player };
      }
    } catch (err) {
      console.warn(`[player] failed to read ${sv}: ${err.message}`);
    }
  }

  const chars = discoverCharacters(wowRoot);
  if (chars.length > 0) {
    const c = chars[0];
    return {
      found: true,
      source: 'folders',
      path: c.path,
      player: { name: c.name, realm: c.realm },
    };
  }

  return { found: false, hint: 'No character data yet — log in once and type /reload, then try again.' };
}