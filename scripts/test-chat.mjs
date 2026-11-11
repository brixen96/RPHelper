// Throwaway test: writes a chat request exactly as the addon would
// (escaped JSON history with quotes/backslashes/newlines) and verifies the
// watcher answers it with kind="chat".
import fs from 'node:fs';

const SV = 'C:/Program Files (x86)/World of Warcraft/_forever_/WTF/Account/JEGERSEJ12/93/Brix-Reaper/RPHelperDB.lua';

const history = [
  { r: 'u', t: 'Help me write a short letter: "Hey, the tavern burned down\\nline 2"' },
  { r: 'a', t: 'Sure - here is a draft.' },
  { r: 'u', t: 'Make it sadder' },
];
const json = JSON.stringify(history);
// Lua-escape the JSON string exactly like the addon does
const luaEscaped = json.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');

const sv = `RPHelperDB = {
  ["tone"] = "Neutral",
  ["reqId"] = "1794410000-4444",
  ["reqStatus"] = "pending",
  ["reqKind"] = "chat",
  ["chatJson"] = "${luaEscaped}",
  ["chatPendingText"] = "Make it sadder",
}
`;
fs.writeFileSync(SV, sv, 'utf8');
console.log('chat request written to', SV);
console.log('--- raw chatJson line ---');
console.log(sv.split('\n').find((l) => l.includes('chatJson')).slice(0, 160) + '...');