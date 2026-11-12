--[[ RPHelper — in-game RP response co-pilot
  Flow (no alt-tab needed):
    1. Player fills the scene in the panel and clicks "Write suggestions".
    2. The addon writes a pending request into its SavedVariables and
       triggers /reload (the game persists SavedVariables on reload).
    3. The companion app (running locally) polls the SavedVariables file,
       calls the AI, and writes answers into RPHelperHandoff.lua.
    4. The addon sees the fresh answer on load, auto-reloads once more,
       and shows the suggestions. Click one to insert it into chat.
]]
local ADDON_NAME, ns = ...

-- Bump this on every release — shown in the panel title and on load so the
-- player can confirm the installed version matches the repo.
local VERSION = "0.4.0"

-- ---------------------------------------------------------------------------
-- Client compat — this client (older private-server core) predates several
-- modern APIs. Missing C_Timer silently killed the reload handshake:
-- C_Timer.After (added in WoD) is what schedules ReloadUI after a request,
-- so without it SavedVariables were never written and the watcher never
-- saw a request. Shim it with a plain OnUpdate queue.
-- ---------------------------------------------------------------------------
local print = print or function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage(table.concat(parts, " "))
  end
end

local time = time or os.time
local date = date or os.date

local wipe = wipe or function(t)
  for k in pairs(t) do t[k] = nil end
  return t
end

-- Always use our own timer (never trust the client's C_Timer on this core):
-- a plain OnUpdate queue, no dependencies, works on every client version.
local timerQueue = {}
local timerDriver = CreateFrame("Frame")
timerDriver:Hide()
local timerAcc = 0
timerDriver:SetScript("OnUpdate", function(_, elapsed)
  timerAcc = timerAcc + elapsed
  if timerAcc < 0.05 then return end
  local dt = timerAcc
  timerAcc = 0
  for i = #timerQueue, 1, -1 do
    local item = timerQueue[i]
    item.remaining = item.remaining - dt
    if item.remaining <= 0 then
      table.remove(timerQueue, i)
      item.callback()
    end
  end
  if #timerQueue == 0 then timerDriver:Hide() end
end)
local C_Timer = {
  After = function(delay, callback)
    timerQueue[#timerQueue + 1] = { remaining = tonumber(delay) or 0, callback = callback }
    timerDriver:Show()
  end,
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local db = nil
local panel = nil

-- Chat capture: rolling buffer of recent IC speech / emotes for the scene box
local chatLines = {}
local MAX_CHAT_LINES = 12

-- Shared request plumbing (declared early: chat + suggestion flows both use it)
local WAIT_INTERVAL = 2
local MAX_ATTEMPTS = 45    -- 90s auto-reload window for suggestions/draft

local function RequestId()
  return tostring(time()) .. "-" .. tostring(math.random(1000, 9999))
end

local function GetHandoff()
  return RPHelperHandoffData
end

-- Chat replies live in their OWN mailbox file so a suggestions answer can
-- never overwrite a chat reply before the addon reads it.
local function GetChatHandoff()
  return RPHelperChatHandoffData
end

-- ---------------------------------------------------------------------------
-- Event log — ring buffer in SavedVariables so it survives reloads.
-- /rph log exports it to a file the player can send us for debugging.
-- ---------------------------------------------------------------------------
local LOG_MAX = 80

local function LogEvent(msg)
  if not db then return end
  if type(db.events) ~= "table" then db.events = {} end
  local stamp
  local ok, res = pcall(date, "%H:%M:%S")
  stamp = (ok and res) or "?"
  table.insert(db.events, 1, stamp .. " " .. tostring(msg))
  while #db.events > LOG_MAX do table.remove(db.events) end
  -- Mirror as one string: the watcher's parser flattens tables, so a plain
  -- string field is the reliable way for it to read the event log.
  db.eventsText = table.concat(db.events, "\n")
end

-- Prefer the SHIM timer (OnUpdate frame handler): frame handlers are the
-- same class as OnClick — and click reloads work 100% on this client,
-- while client-C_Timer reloads failed 100% (v0.3.0 evidence: every
-- timer chain failed, every Check click reloaded). Historical shim
-- failures were all inside the load/cooldown window, never cleanly
-- tested. Client C_Timer also appears to SWALLOW deliberate errors
-- (the 14:01:31 send never reached General.log).
local function AfterDelay(delay, fn)
  C_Timer.After(delay, fn) -- our shim (OnUpdate frame handler)
end

-- ---------------------------------------------------------------------------
-- SafeReload — reloads are the ONLY channel to the watcher (SavedVariables
-- hit disk on reload; addons have no file/network IO). Measured on this
-- client (v0.2.9 logs): reloads FAIL for ~40-50s after every load — every
-- attempt <37s after load failed, every attempt >=49s succeeded — an
-- anti-reload-loop cooldown, regardless of mechanism. So: try the chain
-- now; if it exhausts INSIDE the cooldown, wait it out and retry once.
-- Click/input context works once the cooldown expires; the Check button is
-- the guaranteed manual path. A generation counter supersedes stale chains
-- so a new Send is never swallowed by a dying chain.
-- ---------------------------------------------------------------------------
local RELOAD_COOLDOWN = 50 -- seconds after load before reloads are honored

-- ONLY non-restricted mechanisms: ConsoleExec and SlashCmd were dropped
-- (v0.3.1) — ConsoleExec is restricted for addons and SlashCmd routes
-- through protected slash handling; both produced the "Interface action
-- failed because of an AddOn" taint errors the player kept seeing.
local RELOAD_PLAN = {
  { name = "C_UI.Reload", wait = 3, fn = function()
      if C_UI and C_UI.Reload then C_UI.Reload() return true end
      return false
    end },
  { name = "C_UI.Reload(retry)", wait = 4, fn = function()
      if C_UI and C_UI.Reload then C_UI.Reload() return true end
      return false
    end },
  { name = "ReloadUI", wait = 4, fn = function() ReloadUI() return true end },
}
local reloadGen = 0

local function SafeReload(reason, fromClick, isRetry)
  reloadGen = reloadGen + 1
  local gen = reloadGen
  local step = 0
  local function sinceLoad()
    if db and db.loadedAt then return time() - db.loadedAt end
    return 999
  end

  -- Non-click origins inside the cooldown are futile (measured) — skip the
  -- chain and wait it out in one shot.
  if not fromClick and not isRetry and sinceLoad() < RELOAD_COOLDOWN then
    local wait = RELOAD_COOLDOWN - sinceLoad() + 2
    LogEvent(("RELOAD deferred %ds (cooldown, sinceLoad=%ds) (%s)"):format(wait, sinceLoad(), reason))
    if panel and panel.statusFs then
      panel.statusFs:SetText(("Waiting out client reload cooldown (~%ds)..."):format(wait))
    end
    AfterDelay(wait, function()
      if gen ~= reloadGen then return end -- superseded meanwhile
      SafeReload(reason .. "@cooldown", false, true)
    end)
    return
  end

  local function attempt()
    if gen ~= reloadGen then
      LogEvent("RELOAD superseded by newer request (" .. tostring(reason) .. ")")
      return
    end
    step = step + 1
    local m = RELOAD_PLAN[step]
    if not m then
      -- Chain exhausted: if we were inside the cooldown, wait it out and
      -- retry once (this is what makes sends work right after a reload).
      if not isRetry and sinceLoad() < RELOAD_COOLDOWN then
        local wait = RELOAD_COOLDOWN - sinceLoad() + 2
        LogEvent(("RELOAD chain failed inside cooldown (sinceLoad=%ds) - deferring %ds (%s)"):format(sinceLoad(), wait, reason))
        if panel and panel.statusFs then
          panel.statusFs:SetText(("Reload blocked by client cooldown - retrying in ~%ds..."):format(wait))
        end
        AfterDelay(wait, function()
          if gen ~= reloadGen then return end
          SafeReload(reason .. "@cooldown", false, true)
        end)
        return
      end
      if db then db.reloadMechanism = nil end -- don't claim a mechanism "ok" on failure
      LogEvent(("RELOAD all mechanisms FAILED sinceLoad=%ds (%s)"):format(sinceLoad(), reason))
      print("|cffffcc00RPHelper|r auto-reload failed - click the Check button or type /reload, then send RPHelperLog.txt to the dev")
      if panel and panel.statusFs then
        panel.statusFs:SetText("Auto-reload failed - click Check or type /reload.")
      end
      return
    end
    local ok, called = pcall(m.fn)
    LogEvent(("RELOAD try %d/%d %s ok=%s called=%s sinceLoad=%ds (%s)"):format(
      step, #RELOAD_PLAN, m.name, tostring(ok), tostring(called), sinceLoad(), tostring(reason)))
    if ok and called == false then
      attempt() -- API missing on this client: escalate immediately
      return
    end
    if db then db.reloadMechanism = step end
    -- Watchdog: still alive after m.wait => that attempt was silently ignored.
    AfterDelay(m.wait, attempt)
  end
  attempt()
end

-- Schedule a reload from timer context (used by wait loops and the
-- post-send safety reload). Logs which timer fired for diagnostics.
local function SafeReloadLater(delay, reason)
  local function fire()
    LogEvent("RELOAD scheduled fired via shim-timer (" .. tostring(reason) .. ")")
    SafeReload(reason)
  end
  C_Timer.After(delay, fire) -- shim: OnUpdate frame handler (click-class context)
end

-- SaveAddOnVariables (if this client has it) flushes SavedVariables to disk
-- WITHOUT a reload — the watcher reads that file directly, so sends need no
-- reload at all. Probe result cached in db.saveApiWorks; falls back to the
-- proven click-sync reload path when unavailable.
local function TrySaveNow()
  if not db or not db.saveApiWorks then return false end
  local ok = pcall(function()
    if SaveAddOnVariables then
      SaveAddOnVariables(ADDON_NAME)
    elseif C_AddOns and C_AddOns.SaveAddOnVariables then
      C_AddOns.SaveAddOnVariables(ADDON_NAME)
    else
      error("SaveAddOnVariables vanished")
    end
  end)
  if not ok then
    db.saveApiWorks = false
    LogEvent("SAVE now failed - falling back to reload path")
  end
  return ok
end

local function ProbeSaveApi()
  local ok, err = pcall(function()
    if SaveAddOnVariables then
      SaveAddOnVariables(ADDON_NAME)
    elseif C_AddOns and C_AddOns.SaveAddOnVariables then
      C_AddOns.SaveAddOnVariables(ADDON_NAME)
    else
      error("SaveAddOnVariables not available")
    end
  end)
  db.saveApiWorks = ok
  LogEvent("SAVE probe: " .. (ok and "SaveAddOnVariables WORKS (no-reload sends enabled)" or ("no - " .. tostring(err))))
end

-- ---------------------------------------------------------------------------
-- Error channel (v0.3.0): General.log receives Lua errors in REAL-TIME
-- (verified: error storms logged per-second during play), so a deliberate
-- error carrying the request payload reaches the watcher with NO reload.
-- The watcher tails General.log for `RPHelperREQ:{json}`. A deferred reload
-- (+10s, cooldown-aware) remains as the guaranteed persistence fallback.
-- Emit is scheduled via timer so it escapes the buttons' pcall wrappers.
-- ---------------------------------------------------------------------------
local function EmitRequest(obj)
  local function esc(s)
    s = tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "")
    return '"' .. s .. '"'
  end
  local parts = {}
  for k, v in pairs(obj) do
    parts[#parts + 1] = esc(k) .. ":" .. esc(v)
  end
  -- level 0: no position prefix, keeps the log line parseable
  error("RPHelperREQ:{" .. table.concat(parts, ",") .. "}", 0)
end

local function EmitLater(obj)
  AfterDelay(0.05, function()
    EmitRequest(obj)
  end)
end

-- (BuildLogReport / ExportLog live after PlayerInfoText — Lua locals are
-- only visible after their declaration, see below.)

local function InsertIntoChat(text)
  if not text or text == "" then return end
  local editBox = ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend() or DEFAULT_CHAT_FRAME.editBox
  if editBox then
    editBox:SetText(text)
    ChatEdit_ActivateEditBox(editBox)
  end
end

-- (Suggestion rows removed in v0.4.0 — suggestions are generated and shown
-- in the browser; the addon only displays status.)

-- ---------------------------------------------------------------------------
-- Character info line (shows captured player data so the user can confirm
-- the addon is reading their character correctly)
-- ---------------------------------------------------------------------------
local function PlayerInfoText()
  local p = db and db.player
  if not p or not p.name then
    return "character: not captured yet - type /reload once in game"
  end
  local name = p.realm and (p.name .. "-" .. p.realm) or p.name
  local out = name
  local race, class = p.race or "", p.class or ""
  local rc = (race ~= "" and class ~= "") and (race .. " " .. class) or (race .. class)
  if rc ~= "" then out = out .. "  |  " .. rc end
  if p.spec then out = out .. " (" .. tostring(p.spec) .. ")" end
  if p.level then out = out .. "  |  lvl " .. tostring(p.level) end
  return out
end

local function UpdateCharInfo()
  if panel and panel.charInfoFs then
    panel.charInfoFs:SetText(PlayerInfoText())
  end
end

-- Diagnostic report (needs PlayerInfoText above — Lua local scoping)
local function BuildLogReport()
  local lines = {}
  lines[#lines + 1] = ("RPHelper diagnostic export v%s  %s"):format(VERSION, tostring(date and date("%Y-%m-%d %H:%M:%S") or "?"))
  if GetBuildInfo then
    local ok, v = pcall(GetBuildInfo)
    if ok and v then lines[#lines + 1] = "client build: " .. tostring(v) end
  end
  lines[#lines + 1] = "player: " .. PlayerInfoText()
  lines[#lines + 1] = "C_Timer shim: own OnUpdate queue (client has no C_Timer)"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- request state --"
  lines[#lines + 1] = ("reqStatus=%s reqKind=%s reqId=%s attempts=%s saveApi=%s"):format(
    tostring(db and db.reqStatus), tostring(db and db.reqKind),
    tostring(db and db.reqId), tostring(db and db.reqAttempts),
    tostring(db and db.saveApiWorks))
  local cp = db and db.chatPending
  lines[#lines + 1] = ("chatPending id=%s attempts=%s text=%s"):format(
    tostring(cp and cp.id), tostring(cp and cp.attempts),
    tostring(cp and cp.text and cp.text:sub(1, 60)))
  lines[#lines + 1] = ("tone=%s count=%s sceneLen=%d"):format(
    tostring(db and db.tone), tostring(db and db.count),
    db and db.sceneDraft and #db.sceneDraft or 0)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- handoff file --"
  local h = GetHandoff()
  if h then
    lines[#lines + 1] = ("kind=%s requestId=%s generatedAt=%s error=%s suggestions=%d"):format(
      tostring(h.kind), tostring(h.requestId), tostring(h.generatedAt),
      tostring(h.error), h.suggestions and #h.suggestions or 0)
  else
    lines[#lines + 1] = "(RPHelperHandoffData is nil - file not loaded or empty)"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "-- events (newest first) --"
  for _, e in ipairs(db and db.events or {}) do
    lines[#lines + 1] = tostring(e)
  end
  if not db or not db.events or #db.events == 0 then
    lines[#lines + 1] = "(no events recorded yet)"
  end
  return table.concat(lines, "\n")
end

-- The addon CANNOT write files (io sandboxed) or call CopyToClipboard
-- (protected API - triggers the "blocked from an action" popup). So:
--   1) stash the report in SavedVariables (eventsText) for the watcher,
--      which writes RPHelperLog.txt itself with full file access, and
--   2) show it in a selectable EditBox (normal text CAN be Ctrl+C'd).
function ns.ExportLog()
  if not db then
    print("|cffffcc00RPHelper|r not loaded yet")
    return
  end
  local text = BuildLogReport()
  db.eventsText = text
  ns.ShowLogBox(text)
  print("|cffffcc00RPHelper|r log shown in the box (select + Ctrl+C). The watcher also writes RPHelperLog.txt in the RPHelper folder.")
end

-- Selectable text box: WoW EditBoxes support normal select/copy, unlike
-- the chat frame (which Blizzard blocks for addons).
local logBox = nil
function ns.ShowLogBox(text)
  if not logBox then
    local f = CreateFrame("Frame", "RPHelperLogBox", UIParent, "BackdropTemplate")
    f:SetSize(560, 400)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    f:SetFrameStrata("FULLSCREEN")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("RPHelper log - select all + Ctrl+C")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() f:Hide() end)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -44)
    scroll:SetPoint("BOTTOMRIGHT", -36, 16)
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetSize(520, 340)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(box)
    f.editBox = box
    logBox = f
  end
  logBox.editBox:SetText(text or "")
  logBox.editBox:SetFocus()
  logBox:Show()
end

-- ---------------------------------------------------------------------------
-- Control panel
-- ---------------------------------------------------------------------------
local function CreatePanel()
  if panel then return panel end

  local f = CreateFrame("Frame", "RPHelperPanel", UIParent, "BackdropTemplate")
  f:SetSize(460, 560)
  f:SetPoint("CENTER", UIParent, "CENTER", 380, 0)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
  })
  f:SetFrameStrata("DIALOG")

  -- Title bar (version visible so the player can verify they're up to date)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -14)
  title:SetText("RPHelper v" .. VERSION)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)
  close:SetScript("OnClick", function() f:Hide() end)

  -- Status line (sequentially anchored so wrapping can never collide)
  local status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  status:SetPoint("TOP", title, "BOTTOM", 0, -6)
  status:SetWidth(400)
  status:SetJustifyH("CENTER")
  status:SetText("Ready - describe the scene below.")
  f.statusFs = status

  -- Character info line (name/realm | race class (spec) | lvl)
  local charInfo = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  charInfo:SetPoint("TOP", status, "BOTTOM", 0, -4)
  charInfo:SetWidth(400)
  charInfo:SetJustifyH("CENTER")
  charInfo:SetText(PlayerInfoText())
  f.charInfoFs = charInfo

  -- v0.4.0: the addon is a SENSOR + DISPLAY. All editing and generation
  -- lives in the browser (http://127.0.0.1:7331). In-game keeps: status,
  -- character line, Check, Copy log, scene capture, heartbeats.
  local info = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  info:SetPoint("TOP", charInfo, "BOTTOM", 0, -16)
  info:SetWidth(400)
  info:SetJustifyH("CENTER")
  info:SetText("Sheet, chat & suggestions live in the browser:")
  local url = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  url:SetPoint("TOP", info, "BOTTOM", 0, -4)
  url:SetWidth(400)
  url:SetJustifyH("CENTER")
  url:SetText("http://127.0.0.1:7331")

  local tip = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  tip:SetPoint("TOP", url, "BOTTOM", 0, -14)
  tip:SetWidth(400)
  tip:SetJustifyH("CENTER")
  tip:SetText("This panel feeds the site: character, scene capture, live status.")
  local copyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  copyBtn:SetSize(80, 24)
  copyBtn:SetPoint("BOTTOMRIGHT", -16, 14)
  copyBtn:SetText("Copy log")
  copyBtn:SetScript("OnClick", function() ns.ExportLog() end)
  f.copyBtn = copyBtn

  -- Check: guaranteed click-context reload (works once the client's reload
  -- cooldown has expired) — the manual floor when auto-reload can't fire.
  local checkBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  checkBtn:SetSize(70, 24)
  checkBtn:SetPoint("RIGHT", copyBtn, "LEFT", -8, 0)
  checkBtn:SetText("Check")
  checkBtn:SetScript("OnClick", function()
    if panel and panel.statusFs then panel.statusFs:SetText("Checking for a reply...") end
    SafeReload("check-click", true)
  end)
  f.checkBtn = checkBtn

  -- Footer hint (short — sits left of the Check/Copy log buttons)
  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 16, 20)
  hint:SetText("AI chat: 127.0.0.1:7331 · /rph help")

  f:Hide()
  panel = f
  return f
end

-- (Chat moved to the browser: http://127.0.0.1:7331 — instant, no reloads.
-- The addon keeps only scene/sheet/suggestions, which must stay in-game.)

-- ---------------------------------------------------------------------------
-- Player info capture (used by the companion app as fallback)
-- ---------------------------------------------------------------------------
local function CapturePlayerInfo()
  if not db then return end
  local name = UnitName("player")
  if not name or name == "" then return end
  local race, raceToken = UnitRace("player")
  local class, classToken = UnitClass("player")
  local sexCode = UnitSex("player")
  local specName
  if GetSpecialization then
    local specIndex = GetSpecialization()
    if specIndex then
      local _, sname = GetSpecializationInfo(specIndex)
      specName = sname
    end
  end
  db.player = {
    name = name,
    realm = GetRealmName(),
    race = race,
    raceToken = raceToken,
    class = class,
    classToken = classToken,
    level = UnitLevel("player"),
    spec = specName,
    sex = sexCode == 3 and "Female" or (sexCode == 2 and "Male" or nil),
    guild = GetGuildInfo and GetGuildInfo("player") or nil,
    zone = GetZoneText and GetZoneText() or nil,
    money = GetMoney and GetMoney() or nil,
    itemLevel = (function()
      if not GetAverageItemLevel then return nil end
      local ok, _, overall = pcall(GetAverageItemLevel)
      if ok and overall and tonumber(overall) then return math.floor(tonumber(overall) * 10) / 10 end
      return nil
    end)(),
    hp = UnitHealth and UnitHealth("player") or nil,
    hpMax = UnitHealthMax and UnitHealthMax("player") or nil,
    updatedAt = date("%Y-%m-%d %H:%M"),
  }
  UpdateCharInfo()
end

-- ---------------------------------------------------------------------------
-- Heartbeat: push the live player snapshot to the watcher every 2 minutes via
-- the error channel (popups suppressed with scriptErrors=0). Keeps the guild
-- website's character card fresh with zero reloads.
-- ---------------------------------------------------------------------------
local function PlayerJson()
  local p = db and db.player
  if not p then return "{}" end
  local function q(s)
    return '"' .. tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
  end
  local parts = {}
  for _, k in ipairs({ "name", "realm", "race", "class", "level", "spec", "guild", "zone", "money", "itemLevel", "hp", "hpMax", "updatedAt" }) do
    local v = p[k]
    if v ~= nil then
      parts[#parts + 1] = '"' .. k .. '":' .. (type(v) == "number" and tostring(v) or q(v))
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local hbGen = 0
local function EmitHeartbeat()
  hbGen = hbGen + 1
  EmitRequest({ kind = "heartbeat", id = "hb-" .. time() .. "-" .. hbGen, data = PlayerJson() })
end

local function ScheduleHeartbeat(delay)
  AfterDelay(delay, function()
    ScheduleHeartbeat(120) -- re-arm FIRST: EmitHeartbeat throws (by design)
    EmitHeartbeat()
  end)
end

-- ---------------------------------------------------------------------------
-- Chat capture (fills the scene box from real IC speech / emotes)
-- ---------------------------------------------------------------------------
local function IsSystemMessage(msg)
  local m = strlower(msg)
  local patterns = {
    "has come online", "has gone offline", "is now the", "wins the achievement",
    "has earned the achievement", "has gone from", "has joined the", "level up",
    "has reached level", "wins!", "has won", "defeats", "has defeated",
    "candidate", "votes needed", "queue for", "dungeon", "battleground",
    "rated battleground", "arena team", "has gone up", "has gone down",
    "has earned", "earned the title", "has been awarded", "has invited",
    "declines", "goes on a", "receives item", "creates:", "loot:",
    "has gone from level", "your group", "has joined a group", "leaves the group",
    "has gone up to", "has gone down to", "wins the duel", "you won",
  }
  for _, p in ipairs(patterns) do
    if strfind(m, p, 1, true) then return true end
  end
  return false
end

local function IsLfgNoise(msg)
  local m = strlower(msg)
  if strfind(m, "lfg", 1, true) or strfind(m, "lfm", 1, true) or strfind(m, "lf ", 1, true) then return true end
  if strfind(m, "wts", 1, true) or strfind(m, "wtb", 1, true) or strfind(m, "wtt", 1, true) then return true end
  if strfind(m, "+10", 1, true) or strfind(m, "+11", 1, true) or strfind(m, "+12", 1, true) then return true end
  if strfind(m, "m+", 1, true) or strfind(m, "mythic", 1, true) then return true end
  if strfind(m, "raid", 1, true) or strfind(m, "norm ", 1, true) or strfind(m, "heroic", 1, true) then return true end
  if strfind(m, "guild", 1, true) or strfind(m, "recruit", 1, true) then return true end
  if strfind(m, "boost", 1, true) or strfind(m, "carry", 1, true) then return true end
  if strfind(m, "mount", 1, true) or strfind(m, "token", 1, true) then return true end
  if strfind(m, "gold", 1, true) or strfind(m, "golds", 1, true) then return true end
  if strfind(m, "inv ", 1, true) or strfind(m, "inv,", 1, true) then return true end
  if strfind(m, "xmute", 1, true) or strfind(m, "enchant", 1, true) then return true end
  if strfind(m, "crafted", 1, true) or strfind(m, "leggo", 1, true) then return true end
  if strfind(m, "group for", 1, true) or strfind(m, "forming ", 1, true) then return true end
  if strfind(m, "need 1", 1, true) or strfind(m, "need 2", 1, true) or strfind(m, "need 3", 1, true) then return true end
  if strfind(m, "healer", 1, true) or strfind(m, "tank", 1, true) or strfind(m, "dps", 1, true) then return true end
  if strfind(m, "pst", 1, true) or strfind(m, "whisper", 1, true) then return true end
  if strfind(m, "anyone", 1, true) or strfind(m, "looking for", 1, true) then return true end
  if strfind(m, "any takers", 1, true) or strfind(m, "spot open", 1, true) then return true end
  if strfind(m, "selling", 1, true) or strfind(m, "buying", 1, true) then return true end
  if strfind(m, "cheap", 1, true) or strfind(m, "discount", 1, true) then return true end
  if strfind(m, "%d+/%d+") then return true end
  if strfind(m, "raid tonight", 1, true) or strfind(m, "sign up", 1, true) then return true end
  if strfind(m, "is looking for", 1, true) or strfind(m, "has come online", 1, true) then return true end
  if strfind(m, "has gone offline", 1, true) or strfind(m, "is now the", 1, true) then return true end
  if strfind(m, "wins the achievement", 1, true) or strfind(m, "has earned", 1, true) then return true end
  if strfind(m, "has joined", 1, true) or strfind(m, "has left", 1, true) then return true end
  if strfind(m, "goes on a", 1, true) or strfind(m, "has gone up", 1, true) then return true end
  if strfind(m, "has gone down", 1, true) or strfind(m, "level up", 1, true) then return true end
  if strfind(m, "has reached level", 1, true) or strfind(m, "wins!", 1, true) then return true end
  if strfind(m, "has won", 1, true) or strfind(m, "defeats", 1, true) then return true end
  if strfind(m, "has defeated", 1, true) or strfind(m, "candidate", 1, true) then return true end
  if strfind(m, "votes needed", 1, true) or strfind(m, "queue for", 1, true) then return true end
  if strfind(m, "dungeon", 1, true) or strfind(m, "battleground", 1, true) then return true end
  if strfind(m, "arena", 1, true) or strfind(m, "rated", 1, true) then return true end
  if strfind(m, "has been awarded", 1, true) or strfind(m, "has invited", 1, true) then return true end
  if strfind(m, "declines", 1, true) or strfind(m, "receives item", 1, true) then return true end
  if strfind(m, "creates:", 1, true) or strfind(m, "loot:", 1, true) then return true end
  if strfind(m, "your group", 1, true) or strfind(m, "leaves the group", 1, true) then return true end
  if strfind(m, "wins the duel", 1, true) or strfind(m, "you won", 1, true) then return true end
  if strfind(m, "has come online", 1, true) or strfind(m, "has gone offline", 1, true) then return true end
  return false
end

local function IsICLine(msg)
  -- Emote-style RP: *nods slowly*, /me actions, or quoted speech
  if strfind(msg, "*", 1, true) then return true end
  if strfind(msg, '"', 1, true) then return true end
  if strfind(msg, "'", 1, true) then return true end
  return false
end

local function CaptureChatLine(msg)
  if not msg or msg == "" then return end
  if IsSystemMessage(msg) then return end
  if IsLfgNoise(msg) then return end
  if not IsICLine(msg) then return end
  table.insert(chatLines, 1, strtrim(msg))
  while #chatLines > MAX_CHAT_LINES do
    table.remove(chatLines)
  end
  -- Capture into SavedVariables — the browser reads it as the scene fallback
  if db then db.sceneDraft = table.concat(chatLines, "\n") end
end

-- (Request flow + wait/reply loop removed in v0.4.0 — generation happens
-- over HTTP in the browser: POST /api/suggest, /api/draft. The addon only
-- feeds data: character, scene capture, heartbeats, status.)

-- ---------------------------------------------------------------------------
-- Refresh / display
-- ---------------------------------------------------------------------------
function ns.Refresh()
  if not panel then CreatePanel() end
  UpdateCharInfo()
  local handoff = GetHandoff()
  if handoff and handoff.error then
    panel.statusFs:SetText(("AI error: %s"):format(handoff.error))
  elseif handoff and handoff.suggestions and #handoff.suggestions > 0 then
    panel.statusFs:SetText(("Last suggestions: %s · tone: %s — open the browser"):format(
      tostring(handoff.generatedAt or "?"):sub(1, 19),
      tostring(handoff.tone or "-")))
  else
    panel.statusFs:SetText("Generate in the browser: http://127.0.0.1:7331")
  end
  panel:Show()
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
local function HandleSlash(msg)
  local cmd, rest = strsplit(" ", msg, 2)
  cmd = strlower(strtrim(cmd or ""))
  if cmd == "reload" then
    ns.Refresh()
  elseif cmd == "check" then
    if panel and panel.statusFs then panel.statusFs:SetText("Checking for a reply...") end
    SafeReload("check-slash", true)
  elseif cmd == "chat" or cmd == "web" then
    print("|cffffcc00RPHelper|r AI chat lives in the browser now: |cffffcc00http://127.0.0.1:7331|r")
  elseif cmd == "version" or cmd == "v" then
    print(("|cffffcc00RPHelper|r version %s"):format(VERSION))
  elseif cmd == "log" or cmd == "export" then
    ns.ExportLog()
  elseif cmd == "show" then
    ns.ShowLogBox(db and db.eventsText or "(no log yet)")
  elseif cmd == "help" then
    print(("|cffffcc00RPHelper|r v%s commands:"):format(VERSION))
    print("  /rph — toggle panel (sensor + status)")
    print("  /rph web — open the guild website URL")
    print("  /rph reload — refresh panel status")
    print("  /rph check — reload now to fetch a pending reply")
    print("  /rph log — show diagnostics (select + Ctrl+C)")
    print("  /rph show — reopen the log box")
  else
    if not panel then CreatePanel() end
    if panel:IsShown() then panel:Hide() else ns.Refresh() end
  end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_SAY")
eventFrame:RegisterEvent("CHAT_MSG_YELL")
eventFrame:RegisterEvent("CHAT_MSG_EMOTE")
eventFrame:RegisterEvent("CHAT_MSG_TEXT_EMOTE")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    RPHelperDB = RPHelperDB or { tone = "Neutral", count = 3 }
    db = RPHelperDB
    db.loadedAt = time() -- reload cooldown clock (SafeReload gates on this)
    math.random(time())
    SLASH_RPHELPER1 = "/rph"
    SlashCmdList.RPHELPER = HandleSlash
    CapturePlayerInfo()
    LogEvent(("LOAD reqStatus=%s reqKind=%s reqId=%s chatPending=%s"):format(
      tostring(db.reqStatus), tostring(db.reqKind), tostring(db.reqId),
      tostring(db.chatPending and db.chatPending.id)))
    local h = GetHandoff()
    LogEvent(("LOAD handoff kind=%s id=%s gen=%s"):format(
      tostring(h and h.kind), tostring(h and h.requestId), tostring(h and h.generatedAt)))
    local hc = GetChatHandoff()
    LogEvent(("LOAD chat-handoff kind=%s id=%s gen=%s"):format(
      tostring(hc and hc.kind), tostring(hc and hc.requestId), tostring(hc and hc.generatedAt)))
    if db.reloadMechanism then
      local rm = RELOAD_PLAN[db.reloadMechanism]
      LogEvent("RELOAD ok via " .. (rm and rm.name or tostring(db.reloadMechanism)))
      db.reloadMechanism = nil
    end
    ProbeSaveApi() -- SaveAddOnVariables => no-reload sends (io is unavailable)
    -- Hide deliberate error-channel popups (the RPHelperREQ emits). Real
    -- addon errors are still caught by our pcall wrappers + event log.
    -- Log the TRUE SetCVar result — v0.3.0 logged success unconditionally.
    do
      local ok, setOk = pcall(function()
        if C_CVar and C_CVar.SetCVar then
          return C_CVar.SetCVar("scriptErrors", "0")
        elseif SetCVar then
          return SetCVar("scriptErrors", "0")
        end
        return "no SetCVar API"
      end)
      LogEvent("scriptErrors=0 -> " .. (ok and tostring(setOk) or ("pcall err: " .. tostring(setOk))))
    end
    -- CVar channel probe: set rphNonce NOW and every 30s DURING play. If a
    -- new value shows up in config-cache.wtf without a reload in between,
    -- CVars flush mid-play => sends can skip the reload entirely (v0.3.0).
    local function setNonce()
      pcall(function()
        local nonce = tostring(time())
        if C_CVar and C_CVar.SetCVar then
          C_CVar.SetCVar("rphNonce", nonce)
        elseif SetCVar then
          SetCVar("rphNonce", nonce)
        else
          error("SetCVar not available")
        end
      end)
    end
    local ok, err = pcall(setNonce)
    LogEvent("CVAR probe: " .. (ok and "SetCVar ok - nonce ticking every 30s, watcher watches config-cache" or ("no - " .. tostring(err))))
    if ok then
      local tick
      tick = function()
        setNonce()
        AfterDelay(30, tick)
      end
      AfterDelay(30, tick)
    end
    -- Live data heartbeat: push the player snapshot to the watcher every 2
    -- minutes (error channel, popups suppressed) so the guild website stays
    -- fresh without any reloads.
    ScheduleHeartbeat(10)
    print(("|cffffcc00RPHelper|r v%s loaded — |cffffcc00/rph|r status · guild site: |cffffcc00http://127.0.0.1:7331|r"):format(VERSION))
  elseif event == "PLAYER_LOGIN" or event == "PLAYER_LEVEL_UP" then
    CapturePlayerInfo()
  elseif event == "PLAYER_ENTERING_WORLD" then
    CapturePlayerInfo()
  elseif event == "CHAT_MSG_SAY" or event == "CHAT_MSG_YELL"
      or event == "CHAT_MSG_EMOTE" or event == "CHAT_MSG_TEXT_EMOTE" then
    CaptureChatLine(arg1)
  end
end)