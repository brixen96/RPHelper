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
local VERSION = "0.2.8"

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
local rows = {}

local TONES = { "Neutral", "Warm/Friendly", "Gruff/Tough", "Witty/Flirty", "Formal/Noble", "Mysterious" }
local COUNTS = { 2, 3, 4, 5 }

-- Chat capture: rolling buffer of recent IC speech / emotes for the scene box
local chatLines = {}
local MAX_CHAT_LINES = 12

-- Shared request plumbing (declared early: chat + suggestion flows both use it)
local WAIT_INTERVAL = 2
local MAX_ATTEMPTS = 45    -- 90s auto-reload window for suggestions/draft
local CHAT_MAX_ATTEMPTS = 60 -- 120s for chat replies

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

-- Prefer the CLIENT's C_Timer for scheduling reloads: our shim fires from
-- raw OnUpdate context, which this client silently ignores for reloads
-- (proven: shim-timer chains never produced a LOAD). Click-synchronous
-- reloads work; client-timer context is the remaining candidate.
local function AfterDelay(delay, fn)
  local g = _G.C_Timer
  if g and g.After then
    g.After(delay, fn)
  else
    C_Timer.After(delay, fn) -- our shim (local)
  end
end

-- ---------------------------------------------------------------------------
-- SafeReload — reloads are the ONLY channel to the watcher (SavedVariables
-- hit disk on reload; addons have no file/network IO). This client:
--   • IGNORES reloads fired during the load sequence (ADDON_LOADED) —
--     verified: wait-chain try 1 fired at LOAD+0s, silently no-op'd;
--   • IGNORES legacy ReloadUI/ConsoleExec/SlashCmd from timer contexts;
--   • HONORS C_UI.Reload from click context (proven: send → LOAD 4s later).
-- Plan: C_UI.Reload immediately (click path), RETRY it from a timer (the
-- load-sequence path), then escalate through legacy mechanisms. A
-- generation counter supersedes stale chains so a new Send is never
-- swallowed by a dying chain (that bug stranded a message for 5 minutes).
-- ---------------------------------------------------------------------------
local RELOAD_PLAN = {
  { name = "C_UI.Reload", wait = 3, fn = function()
      if C_UI and C_UI.Reload then C_UI.Reload() return true end
      return false
    end },
  { name = "C_UI.Reload(timer)", wait = 4, fn = function()
      if C_UI and C_UI.Reload then C_UI.Reload() return true end
      return false
    end },
  { name = "ConsoleExec", wait = 4, fn = function() ConsoleExec("reloadui") return true end },
  { name = "ReloadUI", wait = 4, fn = function() ReloadUI() return true end },
  { name = "SlashCmd", wait = 4, fn = function()
      if SlashCmdList and SlashCmdList["RELOAD"] then SlashCmdList["RELOAD"]() return true end
      return false
    end },
}
local reloadGen = 0

local function SafeReload(reason)
  reloadGen = reloadGen + 1
  local gen = reloadGen
  local step = 0
  local function attempt()
    if gen ~= reloadGen then
      LogEvent("RELOAD superseded by newer request (" .. tostring(reason) .. ")")
      return
    end
    step = step + 1
    local m = RELOAD_PLAN[step]
    if not m then
      if db then db.reloadMechanism = nil end -- don't claim a mechanism "ok" on failure
      LogEvent("RELOAD all mechanisms FAILED (" .. tostring(reason) .. ")")
      print("|cffffcc00RPHelper|r auto-reload failed - type /reload manually, then send RPHelperLog.txt to the dev")
      if panel and panel.statusFs then
        panel.statusFs:SetText("Auto-reload failed - type /reload manually.")
      end
      return
    end
    local ok, called = pcall(m.fn)
    LogEvent(("RELOAD try %d/%d %s ok=%s called=%s (%s)"):format(
      step, #RELOAD_PLAN, m.name, tostring(ok), tostring(called), tostring(reason)))
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
  local g = _G.C_Timer
  local label = g and g.After and "client-timer" or "shim-timer"
  local function fire()
    LogEvent("RELOAD scheduled fired via " .. label .. " (" .. tostring(reason) .. ")")
    SafeReload(reason)
  end
  if g and g.After then
    g.After(delay, fire)
  else
    C_Timer.After(delay, fire)
  end
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

-- ---------------------------------------------------------------------------
-- Suggestion rows
-- ---------------------------------------------------------------------------
local function CreateRow(parent, index)
  local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
  row:SetHeight(44)
  row:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  })
  row:SetBackdropColor(0.12, 0.10, 0.08, 0.9)
  row:SetBackdropBorderColor(0.35, 0.28, 0.16, 1)

  local num = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  num:SetPoint("LEFT", 8, 0)
  num:SetTextColor(0.8, 0.65, 0.3)
  num:SetText(index .. ".")

  local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  text:SetPoint("LEFT", num, "RIGHT", 8, 0)
  text:SetPoint("RIGHT", row, "RIGHT", -8, 0)
  text:SetJustifyH("LEFT")
  text:SetWordWrap(true)
  row.textFs = text

  row:SetScript("OnEnter", function(self)
    self:SetBackdropColor(0.2, 0.17, 0.1, 1)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Click to insert into chat", 1, 1, 1)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function(self)
    self:SetBackdropColor(0.12, 0.10, 0.08, 0.9)
    GameTooltip:Hide()
  end)
  row:SetScript("OnClick", function()
    InsertIntoChat(row.suggestion or "")
  end)

  return row
end

local function LayoutRows(suggestions)
  local container = panel.rowsContainer
  for _, row in ipairs(rows) do row:Hide() end
  wipe(rows)

  local gap = 6
  local height = (container:GetHeight() - gap * (#suggestions - 1)) / #suggestions
  height = math.max(26, math.min(height, 70))

  for i, suggestion in ipairs(suggestions) do
    local row = rows[i] or CreateRow(container, i)
    rows[i] = row
    row.suggestion = suggestion
    row.textFs:SetText(suggestion)
    row:ClearAllPoints()
    if i == 1 then
      row:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
      row:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
    else
      row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, -gap)
      row:SetPoint("TOPRIGHT", rows[i - 1], "BOTTOMRIGHT", 0, -gap)
    end
    row:SetHeight(height)
    row:Show()
  end
end

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
  f:SetSize(460, 760)
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

  -- Plain EditBox with backdrop: InputScrollFrameTemplate throws Lua errors
  -- on this client (InputBoxTemplates.lua:102 error storms in General.log).
  local function MakeInputBox(parent, w, h, multiline, maxLetters)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(w, h)
    box:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Buttons\\WHITE8X8",
      edgeSize = 1,
    })
    box:SetBackdropColor(0, 0, 0, 0.6)
    box:SetBackdropBorderColor(0.35, 0.28, 0.16, 1)
    box:SetFontObject("GameFontHighlight")
    box:SetTextInsets(6, 6, 4, 4)
    box:SetMaxLetters(maxLetters or 400)
    if multiline then box:SetMultiLine(true) end
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
  end

  -- Scene box: each box sits 24px below the previous element so its label
  -- (8px above the box) always has clearance, even when status wraps to 2 lines
  local sceneBox = MakeInputBox(f, 400, 48, true, 400)
  sceneBox:SetPoint("TOPLEFT", charInfo, "BOTTOMLEFT", -4, -24)
  sceneBox:SetText(db and db.sceneDraft or "")
  f.sceneBox = sceneBox

  local sceneLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sceneLabel:SetPoint("BOTTOMLEFT", sceneBox, "TOPLEFT", 2, 8)
  sceneLabel:SetText("Scene / what just happened:")
  f.sceneLabel = sceneLabel

  -- Character sheet: personality
  local personalityBox = MakeInputBox(f, 400, 36, true, 300)
  personalityBox:SetPoint("TOPLEFT", sceneBox, "BOTTOMLEFT", 0, -24)
  personalityBox:SetText(db and db.personality or "")
  f.personalityBox = personalityBox

  local personalityLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  personalityLabel:SetPoint("BOTTOMLEFT", personalityBox, "TOPLEFT", 2, 8)
  personalityLabel:SetText("Personality:")

  -- Character sheet: speech quirks
  local quirksBox = MakeInputBox(f, 400, 36, true, 300)
  quirksBox:SetPoint("TOPLEFT", personalityBox, "BOTTOMLEFT", 0, -24)
  quirksBox:SetText(db and db.quirks or "")
  f.quirksBox = quirksBox

  local quirksLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  quirksLabel:SetPoint("BOTTOMLEFT", quirksBox, "TOPLEFT", 2, 8)
  quirksLabel:SetText("Speech quirks:")

  -- Persist the sheet on every keystroke: SavedVariables are written by the
  -- game on /reload or logout, so the current db always survives restarts.
  -- (Keeps the template's own OnTextChanged handler for scroll behavior.)
  local function hookSheetSave(box, key)
    local orig = box:GetScript("OnTextChanged")
    box:SetScript("OnTextChanged", function(self, userInput)
      -- pcall: a template handler error must never abort the save
      if orig then pcall(orig, self, userInput) end
      if db then db[key] = self:GetText() end
    end)
  end
  hookSheetSave(sceneBox, "sceneDraft")
  hookSheetSave(personalityBox, "personality")
  hookSheetSave(quirksBox, "quirks")

  -- Tone dropdown
  local dropdown = CreateFrame("Frame", "RPHelperToneDropdown", f, "UIDropDownMenuTemplate")
  dropdown:SetPoint("TOPLEFT", quirksBox, "BOTTOMLEFT", -6, -14)
  UIDropDownMenu_SetWidth(dropdown, 130)
  UIDropDownMenu_SetText(dropdown, db and db.tone or "Neutral")
  UIDropDownMenu_Initialize(dropdown, function(self, level)
    for _, tone in ipairs(TONES) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = tone
      info.checked = (tone == (db and db.tone or "Neutral"))
      info.func = function()
        db.tone = tone
        UIDropDownMenu_SetText(dropdown, tone)
        CloseDropDownMenus()
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  f.toneDropdown = dropdown

  -- Count dropdown
  local countDd = CreateFrame("Frame", "RPHelperCountDropdown", f, "UIDropDownMenuTemplate")
  countDd:SetPoint("LEFT", dropdown, "RIGHT", 40, 0)
  UIDropDownMenu_SetWidth(countDd, 50)
  UIDropDownMenu_SetText(countDd, tostring(db and db.count or 3))
  UIDropDownMenu_Initialize(countDd, function(self, level)
    for _, n in ipairs(COUNTS) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = tostring(n)
      info.checked = (n == (db and db.count or 3))
      info.func = function()
        db.count = n
        UIDropDownMenu_SetText(countDd, tostring(n))
        CloseDropDownMenus()
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  f.countDd = countDd

  -- Button row: on its OWN row below the dropdowns — tone + count + both
  -- buttons on one row overflowed the panel (visible overlap in screenshot)
  -- pcall wrappers: any error prints to chat instead of dying silently
  -- (this is how the missing-C_Timer bug stayed invisible for so long)
  local function safeCall(fn)
    local ok, err = pcall(fn)
    if not ok then
      LogEvent("ERROR " .. tostring(err))
      print("|cffffcc00RPHelper|r error: " .. tostring(err))
    end
  end

  local draftBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  draftBtn:SetSize(110, 24)
  draftBtn:SetPoint("TOPRIGHT", quirksBox, "BOTTOMRIGHT", 0, -48)
  draftBtn:SetText("AI sheet draft")
  draftBtn:SetScript("OnClick", function() safeCall(ns.RequestDraft) end)
  f.draftBtn = draftBtn

  local generate = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  generate:SetSize(150, 24)
  generate:SetPoint("RIGHT", draftBtn, "LEFT", -8, 0)
  generate:SetText("Write suggestions")
  generate:SetScript("OnClick", function() safeCall(ns.RequestSuggestions) end)
  f.generateBtn = generate

  -- Suggestions container (fixed height so the chat section below has room)
  local container = CreateFrame("Frame", nil, f)
  container:SetPoint("TOPLEFT", quirksBox, "BOTTOMLEFT", 0, -82)
  container:SetPoint("TOPRIGHT", quirksBox, "BOTTOMRIGHT", 0, -82)
  container:SetHeight(170)
  f.rowsContainer = container

  -- AI chat section (merged into the main panel — only /rph needed)
  local chatLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  chatLabel:SetPoint("TOPLEFT", container, "BOTTOMLEFT", 0, -10)
  chatLabel:SetText("AI Chat - letters, replies, RP etiquette:")

  local chatScroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  chatScroll:SetPoint("TOPLEFT", chatLabel, "BOTTOMLEFT", 0, -6)
  chatScroll:SetPoint("BOTTOMRIGHT", -36, 116)
  local chatHistoryBox = CreateFrame("EditBox", nil, chatScroll)
  chatHistoryBox:SetSize(400, 400)
  chatHistoryBox:SetMultiLine(true)
  chatHistoryBox:SetAutoFocus(false)
  chatHistoryBox:SetFontObject("GameFontHighlight")
  chatHistoryBox:SetText("")
  chatHistoryBox:Disable()
  chatScroll:SetScrollChild(chatHistoryBox)
  f.chatHistoryBox = chatHistoryBox
  f.chatScroll = chatScroll

  local chatInput = MakeInputBox(f, 400, 40, false, 600)
  chatInput:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 46)
  chatInput:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 46)
  chatInput:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    ns.SendChat()
  end)
  f.chatInput = chatInput

  local chatInputLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  chatInputLabel:SetPoint("BOTTOMLEFT", chatInput, "TOPLEFT", 2, 4)
  chatInputLabel:SetText("Message the AI (Enter to send):")

  local sendBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  sendBtn:SetSize(90, 24)
  sendBtn:SetPoint("BOTTOMRIGHT", -16, 14)
  sendBtn:SetText("Send")
  sendBtn:SetScript("OnClick", function()
    local ok, err = pcall(ns.SendChat)
    if not ok then
      LogEvent("ERROR " .. tostring(err))
      print("|cffffcc00RPHelper|r error: " .. tostring(err))
    end
  end)
  f.sendBtn = sendBtn

  local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  clearBtn:SetSize(90, 24)
  clearBtn:SetPoint("RIGHT", sendBtn, "LEFT", -8, 0)
  clearBtn:SetText("Clear")
  clearBtn:SetScript("OnClick", function()
    db.chatHistory = {}
    ns.RefreshChat()
  end)
  f.clearBtn = clearBtn

  local copyBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  copyBtn:SetSize(80, 24)
  copyBtn:SetPoint("RIGHT", clearBtn, "LEFT", -8, 0)
  copyBtn:SetText("Copy log")
  copyBtn:SetScript("OnClick", function() ns.ExportLog() end)
  f.copyBtn = copyBtn

  -- Footer hint (short — sits left of the Send/Clear buttons)
  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 16, 20)
  hint:SetText("/rph help")

  -- Persist the sheet whenever the panel closes (SavedVariables save on reload/logout)
  f:SetScript("OnHide", function(self)
    if not db then return end
    db.sceneDraft = self.sceneBox:GetText()
    db.personality = self.personalityBox:GetText()
    db.quirks = self.quirksBox:GetText()
  end)

  f:Hide()
  panel = f
  return f
end

-- ---------------------------------------------------------------------------
-- AI chat panel (multi-turn discussion: letters, replies, RP etiquette)
-- History lives in SavedVariables as a JSON string; the watcher reads it,
-- calls the AI, and writes the reply back — same reload handshake.
-- ---------------------------------------------------------------------------
local function ChatHistory()
  if not db then return {} end
  if type(db.chatHistory) ~= "table" then db.chatHistory = {} end
  return db.chatHistory
end

local function ChatPending()
  if not db then return "" end
  if type(db.chatPending) ~= "table" then db.chatPending = {} end
  return db.chatPending
end

local function ChatJson()
  local parts = {}
  for _, e in ipairs(ChatHistory()) do
    local role = e.r == "a" and "a" or "u"
    local text = tostring(e.t or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
    parts[#parts + 1] = ('{"r":"%s","t":"%s"}'):format(role, text)
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function ChatAppend(role, text)
  local h = ChatHistory()
  h[#h + 1] = { r = role, t = text }
  while #h > 40 do table.remove(h, 1) end
end

function ns.RefreshChat()
  if not panel then CreatePanel() end
  local lines = {}
  for _, e in ipairs(ChatHistory()) do
    if e.r == "a" then
      lines[#lines + 1] = "|cffffcc00RPHelper:|r " .. tostring(e.t or "")
    else
      lines[#lines + 1] = "|cff1eff00You:|r " .. tostring(e.t or "")
    end
  end
  if #lines == 0 then
    lines[1] = "|cff9d9d9dNo conversation yet. Ask about a letter, a reply, or RP etiquette.|r"
  end
  panel.chatHistoryBox:SetText(table.concat(lines, "\n\n"))
  -- Newest message visible from the start: multiline EditBoxes auto-grow to
  -- content height inside a ScrollFrame, so range = content - viewport.
  local range = panel.chatHistoryBox:GetHeight() - panel.chatScroll:GetHeight()
  if range > 0 then
    panel.chatScroll:SetVerticalScroll(range)
  end
  panel:Show()
end

function ns.SendChat()
  if not db then return end
  if not panel then CreatePanel() end
  local text = strtrim(panel.chatInput:GetText() or "")
  if text == "" then return end
  ChatAppend("u", text)
  local reqId = RequestId()
  db.chatPending = { id = reqId, text = text, attempts = 0 }
  db.chatJson = ChatJson()
  -- Flat id field: the watcher's chat lane keys on this, so a newer
  -- suggestions/draft send (which overwrites reqId) can't cancel it.
  db.chatPendingId = reqId
  db.chatPendingText = text
  db.reqId = reqId
  db.reqStatus = "pending"
  db.reqKind = "chat"
  db.reqAttempts = 0
  db.lastError = nil
  panel.chatInput:SetText("")
  ns.RefreshChat()
  if TrySaveNow() then
    -- Request already on disk: NO reload at click. One delayed reload picks
    -- up the reply (the handoff file is only readable at load time).
    LogEvent(("SEND chat id=%s len=%d saved-no-reload"):format(reqId, #text))
    panel.statusFs:SetText("Sending... reply arrives in a few seconds (one reload, not now).")
    print("|cffffcc00RPHelper|r sending chat message (no reload)...")
    SafeReloadLater(5, "post-send-chat")
  else
    LogEvent(("SEND chat id=%s len=%d"):format(reqId, #text))
    panel.statusFs:SetText("Sending chat message... reloading UI, reply arrives in a moment.")
    print("|cffffcc00RPHelper|r sending chat message - reloading...")
    SafeReload("send-chat") -- click-synchronous: proven to work
  end
end

-- Called on load: if the companion answered the pending chat message,
-- append it and reload once more to display (same bounded wait as requests).
local function CheckChatReply()
  local handoff = GetChatHandoff()
  local pending = ChatPending()
  if not (pending and pending.id) then return false end
  if handoff and handoff.kind == "chat" and handoff.requestId and tostring(handoff.requestId) == tostring(pending.id) then
    LogEvent("REPLY chat matched id=" .. tostring(pending.id))
    db.chatPending = nil
    db.chatPendingId = nil
    db.chatPendingText = nil
    db.reqStatus = "done"
    if handoff.error then
      ChatAppend("a", "[error] " .. tostring(handoff.error))
      print("|cffffcc00RPHelper|r chat AI error: " .. tostring(handoff.error))
    else
      ChatAppend("a", tostring(handoff.chatReply or "(empty reply)"))
      print("|cffffcc00RPHelper|r chat reply received!")
    end
    -- Show it NOW — no reload needed to display (history + pending clear
    -- persist together atomically on the next reload/logout).
    ns.Refresh()
    return true
  end
  -- Not answered yet: bounded wait-reload loop
  ns.RefreshChat()
  local attempts = pending.attempts or 0
  if attempts >= CHAT_MAX_ATTEMPTS then
    -- Auto-reload window exhausted: KEEP the pending request (a late reply
    -- still displays on the next load) but stop the reload storm.
    if not pending.gaveUp then
      pending.gaveUp = true
      LogEvent("WAIT chat gave up - kept pending for late display")
      print("|cffffcc00RPHelper|r still waiting on the watcher - see RPHelperLog.txt. The reply will appear on the next reload.")
    end
    return true
  end
  attempts = attempts + 1
  pending.attempts = attempts
  LogEvent(("WAIT chat attempt=%d handoffKind=%s handoffId=%s"):format(
    attempts, tostring(handoff and handoff.kind), tostring(handoff and handoff.requestId)))
  panel.statusFs:SetText(("Waiting for AI reply... (attempt %d/%d)"):format(attempts, CHAT_MAX_ATTEMPTS))
  SafeReloadLater(WAIT_INTERVAL, "wait-chat") -- timer context, NOT load context
  return false
end

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
    updatedAt = date("%Y-%m-%d %H:%M"),
  }
  UpdateCharInfo()
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
  -- Live-update the scene box if the panel is open and the box is empty
  if panel and panel.sceneBox and strtrim(panel.sceneBox:GetText() or "") == "" then
    panel.sceneBox:SetText(table.concat(chatLines, "\n"))
    if db then db.sceneDraft = panel.sceneBox:GetText() end
  end
end

-- ---------------------------------------------------------------------------
-- Request flow
-- ---------------------------------------------------------------------------
-- Writes a pending request into SavedVariables and reloads the UI so the
-- game persists them to disk (where the companion app can read them).
function ns.RequestSuggestions()
  if not db then return end
  local scene = panel and panel.sceneBox and panel.sceneBox:GetText() or ""
  scene = strtrim(scene)
  if scene == "" then
    if panel and panel.statusFs then
      panel.statusFs:SetText("Describe the scene first (or use /rph set <scene>).")
    end
    return
  end
  db.sceneDraft = scene
  db.personality = strtrim(panel.personalityBox:GetText() or "")
  db.quirks = strtrim(panel.quirksBox:GetText() or "")
  -- NOTE: do NOT clear chatPending here — chat and suggestions now run on
  -- independent watcher lanes and can be in flight at the same time.
  db.waitGaveUp = nil
  db.reqId = RequestId()
  db.reqStatus = "pending"
  db.reqKind = "suggestions"
  db.reqAttempts = 0
  db.lastError = nil
  db.reqScene = scene
  db.reqTone = db.tone or "Neutral"
  db.reqCount = db.count or 3
  db.reqPersonality = db.personality
  db.reqQuirks = db.quirks
  if panel and panel.statusFs then
    panel.statusFs:SetText("Sending request... reloading UI, suggestions arrive in a moment.")
  end
  -- Schedule the reload FIRST — if anything below fails, the handshake
  -- must still happen (this ordering bug is why requests never sent)
  if TrySaveNow() then
    LogEvent(("SEND suggestions id=%s sceneLen=%d saved-no-reload"):format(db.reqId, #scene))
    panel.statusFs:SetText("Sending... suggestions arrive in a few seconds (one reload, not now).")
    print("|cffffcc00RPHelper|r sending request (no reload)...")
    SafeReloadLater(5, "post-send-suggestions")
  else
    LogEvent(("SEND suggestions id=%s sceneLen=%d"):format(db.reqId, #scene))
    print("|cffffcc00RPHelper|r sending request - reloading...")
    SafeReload("send-suggestions") -- click-synchronous: proven to work
  end
end

-- AI sheet draft: asks the companion to expand the personality notes into a
-- polished personality + speech quirks draft (same reload handshake).
function ns.RequestDraft()
  if not db then return end
  db.personality = strtrim(panel.personalityBox:GetText() or "")
  db.quirks = strtrim(panel.quirksBox:GetText() or "")
  db.waitGaveUp = nil
  db.reqId = RequestId()
  db.reqStatus = "pending"
  db.reqKind = "draft"
  db.reqAttempts = 0
  db.lastError = nil
  db.reqScene = db.sceneDraft or ""
  db.reqTone = db.tone or "Neutral"
  db.reqCount = 1
  db.reqPersonality = db.personality
  db.reqQuirks = db.quirks
  if panel and panel.statusFs then
    panel.statusFs:SetText("Drafting sheet from your notes... reloading UI.")
  end
  if TrySaveNow() then
    LogEvent("SEND draft id=" .. db.reqId .. " saved-no-reload")
    print("|cffffcc00RPHelper|r drafting character sheet (no reload)...")
    SafeReloadLater(5, "post-send-draft")
  else
    LogEvent("SEND draft id=" .. db.reqId)
    print("|cffffcc00RPHelper|r drafting character sheet - reloading...")
    SafeReload("send-draft") -- click-synchronous: proven to work
  end
end

-- The addon can only see the companion's answer after a UI reload (the
-- handoff file is read at load time). While a request is pending we
-- schedule a reload every few seconds until the answer arrives or we hit
-- the attempt cap. (WAIT_INTERVAL / MAX_ATTEMPTS declared at top of file.)
local function ScheduleAnswerWait()
  if not (db and db.reqStatus == "pending") then return end
  local attempts = db.reqAttempts or 0
  if attempts >= MAX_ATTEMPTS then
    -- Auto-reload window exhausted: KEEP reqStatus pending so a LATE reply
    -- still displays on the next load — just stop the reload storm.
    if not db.waitGaveUp then
      db.waitGaveUp = true
      LogEvent("WAIT gave up - kept pending for late display")
      print("|cffffcc00RPHelper|r still waiting on the watcher - see RPHelperLog.txt. The reply will appear on the next reload.")
    end
    ns.Refresh()
    return
  end
  attempts = attempts + 1
  db.reqAttempts = attempts
  local h = GetHandoff()
  LogEvent(("WAIT attempt=%d handoffKind=%s handoffId=%s myId=%s"):format(
    attempts, tostring(h and h.kind), tostring(h and h.requestId), tostring(db.reqId)))
  -- Keep the panel visible during the wait so the reloads are obvious
  ns.Refresh()
  panel.statusFs:SetText(("Waiting for AI... (attempt %d/%d)"):format(attempts, MAX_ATTEMPTS))
  SafeReloadLater(WAIT_INTERVAL, "wait-main") -- timer context, NOT load context
end

-- Called on load: if the companion answered our request, show it;
-- otherwise keep waiting (bounded reload loop).
local function CheckHandoff()
  local handoff = GetHandoff()
  if not (db and db.reqStatus == "pending") then return false end
  if db.reqKind == "chat" then return false end -- chat answers go to CheckChatReply
  if handoff and handoff.requestId and tostring(handoff.requestId) == tostring(db.reqId) then
    LogEvent("REPLY matched id=" .. tostring(db.reqId) .. " kind=" .. tostring(handoff.kind))
    db.reqStatus = handoff.error and "failed" or "done"
    db.lastError = handoff.error
    if handoff.error then
      print("|cffffcc00RPHelper|r AI error: " .. tostring(handoff.error))
    elseif handoff.kind == "draft" then
      -- Apply the drafted sheet straight into the panel + SavedVariables
      if handoff.personality and handoff.personality ~= "" then
        db.personality = handoff.personality
        if panel then panel.personalityBox:SetText(handoff.personality) end
      end
      if handoff.quirks and handoff.quirks ~= "" then
        db.quirks = handoff.quirks
        if panel then panel.quirksBox:SetText(handoff.quirks) end
      end
      print("|cffffcc00RPHelper|r sheet draft ready - review it above.")
      if panel and panel.statusFs then
        panel.statusFs:SetText("Sheet draft applied - edit it, then Write suggestions.")
      end
    else
      print("|cffffcc00RPHelper|r suggestions ready!")
    end
    ns.Refresh()
    return true
  end
  ScheduleAnswerWait()
  return false
end

-- ---------------------------------------------------------------------------
-- Refresh / display
-- ---------------------------------------------------------------------------
function ns.Refresh()
  if not panel then CreatePanel() end
  UpdateCharInfo()
  ns.RefreshChat() -- keep the merged chat section in sync too
  local handoff = GetHandoff()
  if handoff and handoff.error then
    panel.statusFs:SetText(("AI error: %s — try again or check the companion app."):format(handoff.error))
    panel:Show()
    return
  end
  if handoff and handoff.kind == "draft" then
    panel.statusFs:SetText("Sheet draft applied - edit it, then Write suggestions.")
    panel:Show()
    return
  end
  if handoff and handoff.suggestions and #handoff.suggestions > 0 then
    panel.statusFs:SetText(("Updated %s  ·  tone: %s"):format(
      tostring(handoff.generatedAt or "?"):sub(1, 19),
      tostring(handoff.tone or "-")))
    LayoutRows(handoff.suggestions)
    panel:Show()
  else
    panel.statusFs:SetText("No suggestions yet - describe the scene and click Write suggestions.")
    panel:Show()
  end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
local function HandleSlash(msg)
  local cmd, rest = strsplit(" ", msg, 2)
  cmd = strlower(strtrim(cmd or ""))
  if cmd == "reload" then
    ns.Refresh()
  elseif cmd == "set" and rest and strtrim(rest) ~= "" then
    if not panel then CreatePanel() end
    panel.sceneBox:SetText(strtrim(rest))
    db.sceneDraft = strtrim(rest)
    ns.RequestSuggestions()
  elseif cmd == "tone" and rest then
    local wanted = strlower(strtrim(rest))
    for _, tone in ipairs(TONES) do
      if strlower(tone) == wanted then
        db.tone = tone
        if panel and panel.toneDropdown then
          UIDropDownMenu_SetText(panel.toneDropdown, tone)
        end
        print("|cffffcc00RPHelper|r tone set to " .. tone)
        return
      end
    end
    print("|cffffcc00RPHelper|r unknown tone. Options: " .. table.concat(TONES, ", "))
  elseif cmd == "chat" then
    ns.RefreshChat()
  elseif cmd == "version" or cmd == "v" then
    print(("|cffffcc00RPHelper|r version %s"):format(VERSION))
  elseif cmd == "log" or cmd == "export" then
    ns.ExportLog()
  elseif cmd == "show" then
    ns.ShowLogBox(db and db.eventsText or "(no log yet)")
  elseif cmd == "help" then
    print(("|cffffcc00RPHelper|r v%s commands:"):format(VERSION))
    print("  /rph — toggle panel")
    print("  /rph chat — AI chat panel (letters, replies, etiquette)")
    print("  /rph set <scene> — describe scene and generate")
    print("  /rph tone <name> — " .. table.concat(TONES, ", "))
    print("  /rph reload — refresh panel from last answer")
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
    if not CheckChatReply() and not CheckHandoff() then
      -- Show the panel automatically when there are suggestions to pick from.
      local handoff = GetHandoff()
      if handoff and handoff.suggestions and #handoff.suggestions > 0 then
        ns.Refresh()
      end
    end
    print(("|cffffcc00RPHelper|r v%s loaded — type |cffffcc00/rph|r for the panel, |cffffcc00/rph chat|r to talk to the AI."):format(VERSION))
  elseif event == "PLAYER_LOGIN" or event == "PLAYER_LEVEL_UP" then
    CapturePlayerInfo()
  elseif event == "PLAYER_ENTERING_WORLD" then
    CapturePlayerInfo()
  elseif event == "CHAT_MSG_SAY" or event == "CHAT_MSG_YELL"
      or event == "CHAT_MSG_EMOTE" or event == "CHAT_MSG_TEXT_EMOTE" then
    CaptureChatLine(arg1)
  end
end)