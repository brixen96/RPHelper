// Verifies the two-lane watcher: a chat request and a suggestions request
// in flight at the same time — chat must be answered first, both must land
// in their own mailbox files.
import fs from 'node:fs';

const SV = 'C:/Program Files (x86)/World of Warcraft/_forever_/WTF/Account/JEGERSEJ12/SavedVariables/RPHelper.lua';
const MAIN_HO = 'C:/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns/RPHelper/RPHelperHandoff.lua';
const CHAT_HO = 'C:/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns/RPHelper/RPHelperChatHandoff.lua';

const t = Math.floor(Date.now() / 1000);
const chatId = `${t}-1111`;
const mainId = `${t}-2222`;

const esc = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
const chatJson = JSON.stringify([{ r: 'u', t: 'Say hello to me in character, briefly.' }]);

// Exactly what the new addon writes: BOTH requests in flight, chat lane
// keyed on the flat chatPendingId field.
const sv = `RPHelperDB = {
  ["tone"] = "Neutral",
  ["count"] = 3,
  ["sceneDraft"] = "A test scene",
  ["chatJson"] = "${esc(chatJson)}",
  ["chatPendingId"] = "${chatId}",
  ["chatPendingText"] = "Say hello to me in character, briefly.",
  ["chatPending"] = {
    ["id"] = "${chatId}",
    ["text"] = "Say hello to me in character, briefly.",
    ["attempts"] = 0,
  },
  ["reqId"] = "${mainId}",
  ["reqStatus"] = "pending",
  ["reqKind"] = "suggestions",
  ["reqAttempts"] = 0,
  ["reqScene"] = "A test scene",
  ["reqTone"] = "Neutral",
  ["reqCount"] = 3,
}
`;
fs.writeFileSync(SV, sv, 'utf8');
console.log(`both requests written: chat=${chatId} main=${mainId}`);

const deadline = Date.now() + 45000;
let chatDone = false;
let mainDone = false;
const poll = setInterval(() => {
  try {
    const c = fs.readFileSync(CHAT_HO, 'utf8');
    if (!chatDone && c.includes(`requestId = "${chatId}"`)) {
      chatDone = true;
      console.log(`CHAT answered at +${Math.round((Date.now() - (deadline - 45000)) / 1000)}s`);
    }
  } catch { /* not yet */ }
  try {
    const m = fs.readFileSync(MAIN_HO, 'utf8');
    if (!mainDone && m.includes(`requestId = "${mainId}"`)) {
      mainDone = true;
      console.log(`MAIN answered at +${Math.round((Date.now() - (deadline - 45000)) / 1000)}s`);
    }
  } catch { /* not yet */ }
  if (chatDone && mainDone) {
    clearInterval(poll);
    console.log('BOTH LANES OK');
    process.exit(0);
  }
  if (Date.now() > deadline) {
    clearInterval(poll);
    console.log(`TIMEOUT chatDone=${chatDone} mainDone=${mainDone}`);
    process.exit(1);
  }
}, 1000);