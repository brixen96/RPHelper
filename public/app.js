/* RPHelper settings page — the generation GUI lives in-game now. */
const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------
async function loadStatus() {
  try {
    const res = await fetch('/api/status');
    const s = await res.json();
    const bar = $('statusBar');
    if (s.hasApiKey) {
      bar.textContent = `✅ AI ready (${s.model}) · watcher active`;
      bar.className = 'status ok';
    } else {
      bar.textContent = '⚠️ No API key — offline templates only (edit config.json)';
      bar.className = 'status warn';
    }
    $('model').value = s.model || '—';
    $('handoffPath').value = s.handoffPath || '—';
    $('svPath').value = s.svPath || '';
    $('svPath').placeholder = s.svPath ? '' : 'not found — log in once and /reload';
  } catch (err) {
    $('statusBar').textContent = `🔴 server unreachable: ${err.message}`;
  }
}

// ---------------------------------------------------------------------------
// Persistence (localStorage so you don't retype your character sheet)
// ---------------------------------------------------------------------------
const FIELDS = ['charName', 'charRace', 'charPersonality', 'charQuirks'];
function saveLocal() {
  const data = {};
  FIELDS.forEach((id) => (data[id] = $(id).value));
  localStorage.setItem('rphelper', JSON.stringify(data));
}
function loadLocal() {
  try {
    const data = JSON.parse(localStorage.getItem('rphelper') || '{}');
    FIELDS.forEach((id) => {
      if (data[id] !== undefined) $(id).value = data[id];
    });
  } catch { /* ignore */ }
}

// ---------------------------------------------------------------------------
// Auto-fill from the game (server reads the addon's SavedVariables on disk)
// ---------------------------------------------------------------------------
async function pullFromGame() {
  const meta = $('playerMeta');
  meta.textContent = '⏳ checking game data…';
  try {
    const res = await fetch('/api/player');
    const data = await res.json();
    if (!data.found) {
      meta.textContent = `⏳ ${data.hint || 'no character data found yet'}`;
      return;
    }
    const p = data.player || {};
    const raceClass = [p.race, p.class].filter(Boolean).join(' ');
    const raceClassFull = p.spec && raceClass ? `${raceClass} (${p.spec})` : raceClass;
    if (p.name) $('charName').value = p.name;
    if (raceClassFull) $('charRace').value = raceClassFull;
    const full = [p.name, p.realm].filter(Boolean).join('-');
    const lvl = p.level ? ` · lvl ${p.level}` : '';
    const src =
      data.source === 'savedvariables'
        ? 'full data from SavedVariables'
        : 'name/realm only — /reload in game once for class & race';
    meta.textContent = `✅ ${full}${lvl} · ${src}`;
    saveLocal();
  } catch (err) {
    meta.textContent = `🔴 ${err.message}`;
  }
}

// ---------------------------------------------------------------------------
// Wire up
// ---------------------------------------------------------------------------
$('btnPull').addEventListener('click', pullFromGame);
FIELDS.forEach((id) => $(id).addEventListener('change', saveLocal));

loadLocal();
loadStatus();
setInterval(loadStatus, 10000);