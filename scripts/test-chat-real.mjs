// Simulates EXACTLY what the fixed ns.SendChat() writes into SavedVariables,
// then waits for the watcher to answer. Verifies the real addon path.
import fs from 'node:fs';

const SV = 'C:/Program Files (x86)/World of Warcraft/_forever_/WTF/Account/JEGERSEJ12/93/Brix-Reaper/RPHelperDB.lua';
const HANDOFF = 'C:/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns/RPHelper/RPHelperHandoff.lua';

const reqId = `${Math.floor(Date.now() / 1000)}-${Math.floor(1000 + Math.random() * 9000)}`;
const text = 'Test: does the real chat path work now?';

// Escape exactly like ChatJson() does in Lua
const history = [{ r: 'u', t: text }];
const chatJson = '[' + history.map((e) => {
  const t = e.t.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
  return `{"r":"${e.r}","t":"${t}"}`;
}).join(',') + ']';

// Escape the JSON string for the Lua file (like luaString does)
const luaEsc = chatJson.replace(/\\/g, '\\\\').replace(/"/g, '\\"');

const sv = `RPHelperDB = {
  ["tone"] = "Neutral",
  ["count"] = 3,
  ["chatPending"] = {
    ["id"] = "${reqId}",
    ["text"] = "${text.replace(/"/g, '\\"')}",
    ["attempts"] = 0,
  },
  ["chatJson"] = "${luaEsc}",
  ["chatPendingText"] = "${text.replace(/"/g, '\\"')}",
  ["reqId"] = "${reqId}",
  ["reqStatus"] = "pending",
  ["reqKind"] = "chat",
  ["reqAttempts"] = 0,
}
`;
fs.writeFileSync(SV, sv, 'utf8');
console.log(`request written (reqId=${reqId}), waiting for watcher...`);

// Poll the handoff file for up to 30s
const deadline = Date.now() + 30000;
const poll = setInterval(() => {
  try {
    const h = fs.readFileSync(HANDOFF, 'utf8');
    if (h.includes(`requestId = "${reqId}"`)) {
      clearInterval(poll);
      console.log('--- HANDOFF RECEIVED ---');
      console.log(h);
      process.exit(0);
    }
  } catch { /* not yet */ }
  if (Date.now() > deadline) {
    clearInterval(poll);
    console.log('TIMEOUT: no reply after 30s');
    console.log('--- current handoff ---');
    try { console.log(fs.readFileSync(HANDOFF, 'utf8')); } catch { console.log('(missing)'); }
    process.exit(1);
  }
}, 1000);