// Throwaway test: verifies player discovery against a simulated WTF folder.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { findSavedVariablesFile, parseSavedVariables, discoverCharacters, getPlayerInfo } from '../server/player.js';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wowtest-'));
const charDir = path.join(root, 'WTF', 'Account', 'ABCD1234', 'Thrall', 'Thalric');
fs.mkdirSync(charDir, { recursive: true });

const svContent = `RPHelperDB = {
  ["tone"] = "Neutral",
  ["player"] = {
    ["name"] = "Thalric",
    ["realm"] = "Draenor",
    ["race"] = "Human",
    ["raceToken"] = "Human",
    ["class"] = "Paladin",
    ["classToken"] = "PALADIN",
    ["level"] = 74,
    ["spec"] = "Retribution",
    ["sex"] = "Male",
    ["updatedAt"] = "2026-11-10 21:00",
  },
}`;
fs.writeFileSync(path.join(charDir, 'RPHelperDB.lua'), svContent);

const sv = findSavedVariablesFile(root);
console.log('sv found:', Boolean(sv));
const parsed = parseSavedVariables(fs.readFileSync(sv, 'utf8'));
console.log('parsed:', JSON.stringify(parsed, null, 2));
const chars = discoverCharacters(root);
console.log('chars:', JSON.stringify(chars.map((c) => ({ n: c.name, r: c.realm }))));
const info = getPlayerInfo({ wowRoot: root });
console.log('getPlayerInfo:', JSON.stringify(info, null, 2));

// Also test the folder-only fallback (no SavedVariables file)
fs.rmSync(path.join(charDir, 'RPHelperDB.lua'));
const fallback = getPlayerInfo({ wowRoot: root });
console.log('fallback:', JSON.stringify(fallback, null, 2));

fs.rmSync(root, { recursive: true, force: true });
console.log('OK');