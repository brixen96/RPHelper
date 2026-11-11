// Restores Emil's real SavedVariables after test-lanes.mjs overwrote them.
// Data reconstructed from the diagnostic exports read earlier today.
// (If the game is still running it will overwrite this with its in-memory
// copy on the next /reload anyway — this protects the closed-game case.)
import fs from 'node:fs';

const SV = 'C:/Program Files (x86)/World of Warcraft/_forever_/WTF/Account/JEGERSEJ12/SavedVariables/RPHelper.lua';

const events = [
  '15:02:17 RELOAD firing (suggestions)',
  '15:02:17 SEND suggestions id=1794405737-8036 sceneLen=17',
  '15:01:08 RELOAD firing (chat)',
  '15:01:08 SEND chat id=1794405668-5702 len=5',
  '15:00:14 RELOAD firing (draft)',
  '15:00:14 SEND draft id=1794405614-9045',
  '14:59:30 REPLY matched id=1794394457-4749 kind=draft',
  '14:59:30 WAIT chat attempt=1 handoffKind=draft handoffId=1794394457-4749',
  '14:59:30 LOAD handoff kind=draft id=1794394457-4749 gen=2026-11-11T12:26:30.567Z',
  '14:59:30 LOAD reqStatus=pending reqKind=draft reqId=1794394457-4749 chatPending=1794394244-2568',
  '11:54:17 RELOAD firing (draft)',
  '11:54:17 SEND draft id=1794394457-4749',
  '11:50:45 RELOAD firing (chat)',
  '11:50:44 SEND chat id=1794394244-2568 len=38',
  '11:47:35 RELOAD firing (chat)',
  '11:47:35 SEND chat id=1794394055-9333 len=6',
  '11:47:13 REPLY matched id=1794392903-4724 kind=suggestions',
  '11:47:13 WAIT chat attempt=1 handoffKind=suggestions handoffId=1794392903-4724',
  '11:47:13 LOAD handoff kind=suggestions id=1794392903-4724 gen=2026-11-11T10:47:11.796Z',
  '11:47:13 LOAD reqStatus=pending reqKind=suggestions reqId=1794392903-4724 chatPending=1794390455-2884',
  '11:28:23 RELOAD firing (suggestions)',
  '11:28:23 SEND suggestions id=1794392903-4724 sceneLen=13',
  '10:47:35 RELOAD firing (chat)',
  '10:47:35 SEND chat id=1794390455-2884 len=5',
  '10:47:23 WAIT chat attempt=2 handoffKind=chat handoffId=1794387498-8179',
  '10:47:23 LOAD handoff kind=chat id=1794387498-8179 gen=2026-11-11T08:58:26.931Z',
  '10:47:23 LOAD reqStatus=pending reqKind=chat reqId=1794389831-4035 chatPending=1794389831-4035',
  '10:43:32 WAIT chat attempt=1 handoffKind=chat handoffId=1794387498-8179',
  '10:43:32 LOAD handoff kind=chat id=1794387498-8179 gen=2026-11-11T08:58:26.931Z',
  '10:43:32 LOAD reqStatus=pending reqKind=chat reqId=1794389831-4035 chatPending=1794389831-4035',
  '10:37:11 RELOAD firing (chat)',
  '10:37:11 SEND chat id=1794389831-4035 len=5',
  '10:36:58 WAIT chat attempt=1 handoffKind=chat handoffId=1794387498-8179',
  '10:36:58 LOAD handoff kind=chat id=1794387498-8179 gen=2026-11-11T08:58:26.931Z',
  '10:36:58 LOAD reqStatus=pending reqKind=chat reqId=1794389423-4635 chatPending=1794389423-4635',
];

const chatHistory = [
  'Hello! I am about to send A LOT of green items to my guild mate Troll Mage named Paghfire Zuljinz.',
  'Hello',
  'Hello!',
  'Hello! :D',
  'Hello',
  'Hello',
  'hello',
];

const personality = 'Undead Priest, Male, Healer, The Grim Reaper. Being a healer is deciding who is ready to enter the underworld (death, the enemy) and who is not (life, friends and allies),';

const esc = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');

const chatJson = '[' + chatHistory.map((t) => `{"r":"u","t":"${esc(t)}"}`).join(',') + ']';

const luaStr = (s) => `"${esc(s)}"`;

const lines = [];
lines.push('RPHelperDB = {');
lines.push(`  ["tone"] = "Neutral",`);
lines.push(`  ["count"] = 3,`);
lines.push(`  ["sceneDraft"] = ${luaStr('Greeting Paghfire')},`);
lines.push(`  ["personality"] = ${luaStr(personality)},`);
lines.push(`  ["quirks"] = "",`);
lines.push(`  ["chatJson"] = ${luaStr(chatJson)},`);
lines.push('  ["chatHistory"] = {');
for (const t of chatHistory) {
  lines.push('    {');
  lines.push(`      ["r"] = "u",`);
  lines.push(`      ["t"] = ${luaStr(t)},`);
  lines.push('    },');
}
lines.push('  },');
lines.push('  ["events"] = {');
for (const e of events) lines.push(`    ${luaStr(e)},`);
lines.push('  },');
lines.push(`  ["eventsText"] = ${luaStr(events.join('\n'))},`);
lines.push('  ["player"] = {');
lines.push('    ["name"] = "Brix",');
lines.push(`    ["realm"] = ${luaStr('CAMWOW EU5 Realm 9 RP PvP')},`);
lines.push('    ["race"] = "Undead",');
lines.push('    ["raceToken"] = "Scourge",');
lines.push('    ["class"] = "Priest",');
lines.push('    ["classToken"] = "PRIEST",');
lines.push('    ["level"] = 21,');
lines.push('    ["sex"] = "Male",');
lines.push(`    ["updatedAt"] = ${luaStr('2026-11-11 11:15')},`);
lines.push('  },');
// Pending suggestions request — the watcher will regenerate the answer
// (the test overwrote the handoff), then the addon displays it on load.
// Unanswered chat from 15:01 — the new chat lane will answer it now.
lines.push('  ["chatPendingId"] = "1794405668-5702",');
lines.push('  ["chatPendingText"] = "hello",');
lines.push('  ["chatPending"] = {');
lines.push('    ["id"] = "1794405668-5702",');
lines.push('    ["text"] = "hello",');
lines.push('    ["attempts"] = 0,');
lines.push('  },');
lines.push('  ["reqId"] = "1794405737-8036",');
lines.push('  ["reqStatus"] = "pending",');
lines.push('  ["reqKind"] = "suggestions",');
lines.push('  ["reqAttempts"] = 0,');
lines.push(`  ["reqScene"] = ${luaStr('Greeting Paghfire')},`);
lines.push('  ["reqTone"] = "Neutral",');
lines.push('  ["reqCount"] = 3,');
lines.push(`  ["reqPersonality"] = ${luaStr(personality)},`);
lines.push('  ["reqQuirks"] = "",');
lines.push('}');

fs.writeFileSync(SV, lines.join('\n') + '\n', 'utf8');
console.log('SV restored to real user state:', SV);