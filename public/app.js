/* RPHelper companion UI */
const $ = (id) => document.getElementById(id);

const state = {
  suggestions: [],
  status: null,
};

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------
async function loadStatus() {
  try {
    const res = await fetch('/api/status');
    state.status = await res.json();
    const bar = $('statusBar');
    if (state.status.hasApiKey) {
      bar.textContent = `✅ AI ready (${state.status.model}) · handoff: ${state.status.handoffSource}`;
      bar.className = 'status ok';
    } else {
      bar.textContent = '⚠️ No API key — offline templates only (copy config.example.json → config.json)';
      bar.className = 'status warn';
    }
  } catch (err) {
    $('statusBar').textContent = `🔴 server unreachable: ${err.message}`;
  }
}

// ---------------------------------------------------------------------------
// Collect payload
// ---------------------------------------------------------------------------
function collectPayload() {
  return {
    character: {
      name: $('charName').value.trim(),
      raceClass: $('charRace').value.trim(),
      personality: $('charPersonality').value.trim(),
      quirks: $('charQuirks').value.trim(),
    },
    scene: {
      setting: $('sceneSetting').value.trim(),
      withWhom: $('sceneWith').value.trim(),
      recent: $('sceneRecent').value.trim(),
    },
    tone: $('tone').value,
    count: Number($('count').value),
  };
}

// ---------------------------------------------------------------------------
// Generate
// ---------------------------------------------------------------------------
async function generate() {
  const btn = $('btnGenerate');
  btn.disabled = true;
  btn.textContent = '⏳ Writing…';
  $('genMeta').textContent = '';
  try {
    const res = await fetch('/api/generate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(collectPayload()),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || res.statusText);
    state.suggestions = data.suggestions;
    renderSuggestions();
    $('genMeta').textContent = `source: ${data.source}${data.source === 'offline' ? ' (add an API key for real AI)' : ''}`;
    $('btnSend').disabled = state.suggestions.length === 0;
  } catch (err) {
    $('genMeta').textContent = `🔴 ${err.message}`;
  } finally {
    btn.disabled = false;
    btn.textContent = '✨ Generate suggestions';
  }
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------
function renderSuggestions() {
  const box = $('suggestions');
  box.innerHTML = '';
  box.classList.toggle('empty', state.suggestions.length === 0);
  if (state.suggestions.length === 0) {
    box.innerHTML = '<p class="placeholder">Nothing yet — fill in the scene and hit Generate.</p>';
    return;
  }
  state.suggestions.forEach((text, i) => {
    const div = document.createElement('div');
    div.className = 'suggestion';

    const idx = document.createElement('span');
    idx.className = 'idx';
    idx.textContent = `${i + 1}.`;

    const ta = document.createElement('textarea');
    ta.rows = 2;
    ta.value = text;
    ta.addEventListener('input', () => {
      state.suggestions[i] = ta.value;
    });

    div.append(idx, ta);
    div.addEventListener('click', (e) => {
      if (e.target === ta) return;
      navigator.clipboard.writeText(ta.value);
      flash(div, 'copied ✓');
    });
    box.appendChild(div);
  });
}

function flash(el, msg) {
  const tag = document.createElement('span');
  tag.className = 'copied';
  tag.textContent = msg;
  el.appendChild(tag);
  setTimeout(() => tag.remove(), 1200);
}

// ---------------------------------------------------------------------------
// Send to game (handoff file)
// ---------------------------------------------------------------------------
async function sendToGame() {
  const btn = $('btnSend');
  btn.disabled = true;
  btn.textContent = '⏳ Sending…';
  try {
    const payload = collectPayload();
    payload.suggestions = state.suggestions;
    const res = await fetch('/api/handoff', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || res.statusText);
    $('genMeta').textContent = `✅ Sent to ${data.path} — now type /reload in WoW, then /rph`;
  } catch (err) {
    $('genMeta').textContent = `🔴 ${err.message}`;
  } finally {
    btn.disabled = false;
    btn.textContent = '➡️ Send to game';
  }
}

// ---------------------------------------------------------------------------
// Persistence (localStorage so you don't retype your character sheet)
// ---------------------------------------------------------------------------
const FIELDS = ['charName', 'charRace', 'charPersonality', 'charQuirks', 'sceneSetting', 'sceneWith', 'sceneRecent', 'tone', 'count'];
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
async function pullFromGame(onlyEmpty = false) {
  const meta = $('playerMeta');
  meta.textContent = '⏳ checking game data…';
  try {
    const res = await fetch('/api/player');
    const data = await res.json();
    if (!data.found) {
      meta.textContent = `⏳ ${data.hint || 'no character data found yet'}`;
      return null;
    }
    const p = data.player || {};
    const raceClass = [p.race, p.class].filter(Boolean).join(' ');
    const raceClassFull = p.spec && raceClass ? `${raceClass} (${p.spec})` : raceClass;
    if (p.name && (!onlyEmpty || !$('charName').value.trim())) $('charName').value = p.name;
    if (raceClassFull && (!onlyEmpty || !$('charRace').value.trim())) $('charRace').value = raceClassFull;
    const full = [p.name, p.realm].filter(Boolean).join('-');
    const lvl = p.level ? ` · lvl ${p.level}` : '';
    const src =
      data.source === 'savedvariables'
        ? 'full data from SavedVariables'
        : 'name/realm only — /reload in game once for class & race';
    meta.textContent = `✅ ${full}${lvl} · ${src}`;
    saveLocal();
    return p;
  } catch (err) {
    meta.textContent = `🔴 ${err.message}`;
    return null;
  }
}

// ---------------------------------------------------------------------------
// Wire up
// ---------------------------------------------------------------------------
$('btnGenerate').addEventListener('click', generate);
$('btnSend').addEventListener('click', sendToGame);
$('btnPull').addEventListener('click', () => pullFromGame(false));
FIELDS.forEach((id) => $(id).addEventListener('change', saveLocal));

loadLocal();
loadStatus();
pullFromGame(true);