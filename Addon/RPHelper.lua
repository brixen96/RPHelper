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

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local db = nil
local panel = nil
local rows = {}

local TONES = { "Neutral", "Warm/Friendly", "Gruff/Tough", "Witty/Flirty", "Formal/Noble", "Mysterious" }
local COUNTS = { 2, 3, 4, 5 }

local function GetHandoff()
  return RPHelperHandoffData
end

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
  height = math.max(36, math.min(height, 70))

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
-- Control panel
-- ---------------------------------------------------------------------------
local function CreatePanel()
  if panel then return panel end

  local f = CreateFrame("Frame", "RPHelperPanel", UIParent, "BackdropTemplate")
  f:SetSize(440, 560)
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

  -- Title bar
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -14)
  title:SetText("RPHelper")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)
  close:SetScript("OnClick", function() f:Hide() end)

  -- Status line
  local status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  status:SetPoint("TOP", title, "BOTTOM", 0, -6)
  status:SetWidth(400)
  status:SetJustifyH("CENTER")
  status:SetText("Ready — describe the scene below.")
  f.statusFs = status

  -- Scene box (labels get 8px clearance above their boxes — the screenshot
  -- showed them colliding with the status line and the box borders)
  local sceneBox = CreateFrame("EditBox", nil, f, "InputScrollFrameTemplate")
  sceneBox:SetPoint("TOPLEFT", 16, -64)
  sceneBox:SetSize(400, 48)
  sceneBox:SetFontObject("GameFontHighlight")
  sceneBox:SetMaxLetters(400)
  sceneBox:SetText(db and db.sceneDraft or "")
  f.sceneBox = sceneBox

  local sceneLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sceneLabel:SetPoint("BOTTOMLEFT", sceneBox, "TOPLEFT", 2, 8)
  sceneLabel:SetText("Scene / what just happened:")
  f.sceneLabel = sceneLabel

  -- Character sheet: personality
  local personalityBox = CreateFrame("EditBox", nil, f, "InputScrollFrameTemplate")
  personalityBox:SetPoint("TOPLEFT", 16, -126)
  personalityBox:SetSize(400, 36)
  personalityBox:SetFontObject("GameFontHighlight")
  personalityBox:SetMaxLetters(300)
  personalityBox:SetText(db and db.personality or "")
  f.personalityBox = personalityBox

  local personalityLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  personalityLabel:SetPoint("BOTTOMLEFT", personalityBox, "TOPLEFT", 2, 8)
  personalityLabel:SetText("Personality:")

  -- Character sheet: speech quirks
  local quirksBox = CreateFrame("EditBox", nil, f, "InputScrollFrameTemplate")
  quirksBox:SetPoint("TOPLEFT", 16, -176)
  quirksBox:SetSize(400, 36)
  quirksBox:SetFontObject("GameFontHighlight")
  quirksBox:SetMaxLetters(300)
  quirksBox:SetText(db and db.quirks or "")
  f.quirksBox = quirksBox

  local quirksLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  quirksLabel:SetPoint("BOTTOMLEFT", quirksBox, "TOPLEFT", 2, 8)
  quirksLabel:SetText("Speech quirks:")

  -- Tone dropdown
  local dropdown = CreateFrame("Frame", "RPHelperToneDropdown", f, "UIDropDownMenuTemplate")
  dropdown:SetPoint("TOPLEFT", 10, -226)
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

  -- Generate button
  local generate = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  generate:SetSize(150, 26)
  generate:SetPoint("LEFT", countDd, "RIGHT", 40, 0)
  generate:SetText("Write suggestions")
  generate:SetScript("OnClick", function() ns.RequestSuggestions() end)
  f.generateBtn = generate

  -- Suggestions container
  local container = CreateFrame("Frame", nil, f)
  container:SetPoint("TOPLEFT", 16, -262)
  container:SetPoint("BOTTOMRIGHT", -16, 40)
  f.rowsContainer = container

  -- Footer hint
  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 16, 14)
  hint:SetText("/rph toggle · /rph set <scene> · /rph tone <name> · /rph help")

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
end

-- ---------------------------------------------------------------------------
-- Request flow
-- ---------------------------------------------------------------------------
local function RequestId()
  return tostring(time()) .. "-" .. tostring(math.random(1000, 9999))
end

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
  db.reqId = RequestId()
  db.reqStatus = "pending"
  db.reqAttempts = 0
  db.lastError = nil
  db.reqScene = scene
  db.reqTone = db.tone or "Neutral"
  db.reqCount = db.count or 3
  db.reqPersonality = db.personality
  db.reqQuirks = db.quirks
  if panel and panel.statusFs then
    panel.statusFs:SetText("Sending request… reloading UI, suggestions arrive in a moment.")
  end
  print("|cffffcc00RPHelper|r sending request — UI reloads automatically…")
  C_Timer.After(0.4, function()
    ReloadUI()
  end)
end

-- The addon can only see the companion's answer after a UI reload (the
-- handoff file is read at load time). While a request is pending we
-- schedule a reload every few seconds until the answer arrives or we hit
-- the attempt cap.
local WAIT_INTERVAL = 2.5
local MAX_ATTEMPTS = 12

local function ScheduleAnswerWait()
  if not (db and db.reqStatus == "pending") then return end
  local attempts = (db.reqAttempts or 0) + 1
  db.reqAttempts = attempts
  if attempts > MAX_ATTEMPTS then
    db.reqStatus = "failed"
    db.lastError = "no answer — is the companion app running?"
    print("|cffffcc00RPHelper|r no answer from the companion app. Start it with: npm start")
    ns.Refresh()
    return
  end
  C_Timer.After(WAIT_INTERVAL, function()
    ReloadUI()
  end)
end

-- Called on load: if the companion answered our request, show it;
-- otherwise keep waiting (bounded reload loop).
local function CheckHandoff()
  local handoff = GetHandoff()
  if not (db and db.reqStatus == "pending") then return false end
  if handoff and handoff.requestId and tostring(handoff.requestId) == tostring(db.reqId) then
    db.reqStatus = handoff.error and "failed" or "done"
    db.lastError = handoff.error
    if handoff.error then
      print("|cffffcc00RPHelper|r AI error: " .. tostring(handoff.error))
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
  local handoff = GetHandoff()
  if handoff and handoff.error then
    panel.statusFs:SetText(("AI error: %s — try again or check the companion app."):format(handoff.error))
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
    panel.statusFs:SetText("No suggestions yet — describe the scene and click Write suggestions.")
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
  elseif cmd == "help" then
    print("|cffffcc00RPHelper|r commands:")
    print("  /rph — toggle panel")
    print("  /rph set <scene> — describe scene and generate")
    print("  /rph tone <name> — " .. table.concat(TONES, ", "))
    print("  /rph reload — refresh panel from last answer")
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
eventFrame:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    RPHelperDB = RPHelperDB or { tone = "Neutral", count = 3 }
    db = RPHelperDB
    math.random(time())
    SLASH_RPHELPER1 = "/rph"
    SlashCmdList.RPHELPER = HandleSlash
    CapturePlayerInfo()
    if not CheckHandoff() then
      -- Show the panel automatically when there are suggestions to pick from.
      local handoff = GetHandoff()
      if handoff and handoff.suggestions and #handoff.suggestions > 0 then
        ns.Refresh()
      end
    end
    print("|cffffcc00RPHelper|r loaded — type |cffffcc00/rph|r to open the panel.")
  elseif event == "PLAYER_LOGIN" or event == "PLAYER_LEVEL_UP" then
    CapturePlayerInfo()
  elseif event == "PLAYER_ENTERING_WORLD" then
    CapturePlayerInfo()
  end
end)