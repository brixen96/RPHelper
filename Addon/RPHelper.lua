--[[ RPHelper — in-game suggestion panel
  Reads RPHelperHandoffData (written by the companion app) and shows the
  latest suggestions in a draggable frame. Click a suggestion to insert it
  into the chat edit box (you still press Enter yourself — nothing is sent
  automatically).
]]
local ADDON_NAME, ns = ...

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------
local db = nil
local panel = nil
local rows = {}

local TONES = { "Neutral", "Warm/Friendly", "Gruff/Tough", "Witty/Flirty", "Formal/Noble", "Mysterious" }

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
-- Panel
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

local function CreatePanel()
  if panel then return panel end

  local f = CreateFrame("Frame", "RPHelperPanel", UIParent, "BackdropTemplate")
  f:SetSize(420, 300)
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
  status:SetText("Waiting for suggestions from the companion app…")
  f.statusFs = status

  -- Tone dropdown
  local dropdown = CreateFrame("Frame", "RPHelperToneDropdown", f, "UIDropDownMenuTemplate")
  dropdown:SetPoint("TOPLEFT", 12, -44)
  UIDropDownMenu_SetWidth(dropdown, 140)
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

  -- Refresh button (re-reads the handoff file after /reload)
  local refresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  refresh:SetSize(90, 22)
  refresh:SetPoint("LEFT", dropdown, "RIGHT", 10, 0)
  refresh:SetText("Refresh")
  refresh:SetScript("OnClick", function() ns.Refresh() end)

  -- Suggestion rows container
  local container = CreateFrame("Frame", nil, f)
  container:SetPoint("TOPLEFT", 12, -78)
  container:SetPoint("BOTTOMRIGHT", -12, 12)
  f.rowsContainer = container

  f:Hide()
  panel = f
  return f
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
-- Player info capture (for the companion app's auto-fill)
-- ---------------------------------------------------------------------------
-- SavedVariables are written by the game on /reload or logout, so the app
-- sees the data after the player types /reload once.
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
-- Refresh / events
-- ---------------------------------------------------------------------------
function ns.Refresh()
  if not panel then CreatePanel() end
  local handoff = GetHandoff()
  if handoff and handoff.suggestions and #handoff.suggestions > 0 then
    panel.statusFs:SetText(("Updated %s  ·  tone: %s"):format(
      tostring(handoff.generatedAt or "?"):sub(1, 19),
      tostring(handoff.tone or "-")))
    LayoutRows(handoff.suggestions)
    panel:Show()
  else
    panel.statusFs:SetText("No suggestions yet — generate some in the companion app, then /reload.")
    panel:Show()
  end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    RPHelperDB = RPHelperDB or { tone = "Neutral" }
    db = RPHelperDB
    SLASH_RPHELPER1 = "/rph"
    SlashCmdList.RPHELPER = function(msg)
      if msg == "reload" then
        ns.Refresh()
      else
        if not panel then CreatePanel() end
        if panel:IsShown() then panel:Hide() else ns.Refresh() end
      end
    end
    print("|cffffcc00RPHelper|r loaded — type |cffffcc00/rph|r to toggle the panel.")
  elseif event == "PLAYER_LOGIN" or event == "PLAYER_LEVEL_UP" then
    CapturePlayerInfo()
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Show automatically if the companion app already wrote suggestions.
    local handoff = GetHandoff()
    if handoff and handoff.suggestions and #handoff.suggestions > 0 then
      ns.Refresh()
    end
  end
end)