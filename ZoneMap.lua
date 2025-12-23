-- ZoneMap.lua
--
-- Visualizes ADT tile grids and zone boundaries on the world map.

local ADDON_NAME, addon = ...
_G[ADDON_NAME] = addon

print(ADDON_NAME .. " loaded")

-- -------------------------
-- Storage for tile grids
-- -------------------------
addon.tileGrids = addon.tileGrids or {}
addon._tileCache = addon._tileCache or {}

-- -------------------------
-- u32 LE reader
-- -------------------------
local function read_u32_le(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  if not b1 then return 0 end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- -------------------------
-- Base64 decoder
-- -------------------------
local _b64vals = {}
do
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #alphabet do
    _b64vals[alphabet:byte(i)] = i - 1
  end
  _b64vals[string.byte("-")] = _b64vals[string.byte("+")]
  _b64vals[string.byte("_")] = _b64vals[string.byte("/")]
end

local function base64_decode(s)
  if not s then return nil end
  s = s:gsub("%s+", "")
  local out = {}
  local i, len = 1, #s
  while i <= len do
    local c1, c2, c3, c4 = s:byte(i, i + 3)
    i = i + 4
    if not c1 or not c2 then break end
    local v1, v2 = _b64vals[c1], _b64vals[c2]
    if v1 == nil or v2 == nil then return nil end
    local pad3 = (c3 == 61) or (c3 == nil)
    local pad4 = (c4 == 61) or (c4 == nil)
    local v3 = pad3 and 0 or _b64vals[c3]
    local v4 = pad4 and 0 or _b64vals[c4]
    if (not pad3 and v3 == nil) or (not pad4 and v4 == nil) then return nil end
    local n = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if not pad3 then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
    if not pad4 then out[#out + 1] = string.char(n % 256) end
  end
  return table.concat(out)
end

-- -------------------------
-- Tile decode: base64 -> raw bytes
-- -------------------------
local function decode_tile_blob(blob)
  if not blob then return nil end
  return base64_decode(blob)
end

local function tile_key(tileX, tileY)
  return tileY * 64 + tileX
end

local function area_id_from_raw(raw, chunkX, chunkY)
  local idx = chunkY * 16 + chunkX
  local offset = idx * 4 + 1
  return read_u32_le(raw, offset)
end

-- -------------------------
-- Simple LRU cache
-- -------------------------
local function new_cache(max)
  return { max = max or 64, map = {}, keys = {}, size = 0 }
end

local function cache_get(c, key)
  return c.map[key]
end

local function cache_put(c, key, value)
  if c.map[key] then c.map[key] = value; return end
  c.map[key] = value
  c.keys[#c.keys + 1] = key
  c.size = c.size + 1
  if c.size > c.max then
    local old = table.remove(c.keys, 1)
    c.map[old] = nil
    c.size = c.size - 1
  end
end

local function get_cache(gridName)
  local c = addon._tileCache[gridName]
  if not c then c = new_cache(64); addon._tileCache[gridName] = c end
  return c
end

-- -------------------------
-- Public API: Register tile grids (called by data files)
-- -------------------------
function addon:RegisterTileGrid(name, grid)
  self.tileGrids[name] = grid
  addon._tileCache[name] = new_cache(64)
  local count = 0
  if grid.tiles then for _ in pairs(grid.tiles) do count = count + 1 end end
  print(ADDON_NAME .. ": Registered " .. name .. " (" .. count .. " tiles)")
end

-- -------------------------
-- Public API: Get area name from ID
-- -------------------------
local areaInfoWarned = {}

function addon:GetAreaName(areaID)
  if not areaID or areaID == 0 then return nil end
  
  if not addon.AreaInfo then
    if not areaInfoWarned["no_areainfo"] then
      print("|cffff0000ZoneMap ERROR: AreaInfo not loaded! Run Rust tool to generate Data/AreaInfo.lua|r")
      areaInfoWarned["no_areainfo"] = true
    end
    return "Unknown"
  end
  
  if not addon.AreaInfo[areaID] then
    if not areaInfoWarned[areaID] then
      print(string.format("|cffffff00ZoneMap: Unknown areaID %d (not in AreaInfo)|r", areaID))
      areaInfoWarned[areaID] = true
    end
    return "Unknown_" .. areaID
  end
  
  return addon.AreaInfo[areaID].name
end

-- =========================================================
-- Position calculation helpers
-- =========================================================

local createVec2 = CreateVector2D or Vector2D_Create

local function continent_name_prefix_grid(continentMapID)
  if continentMapID == 1414 then return "Kalimdor", "kalimdor", "Kalimdor" end
  if continentMapID == 1415 then return "Eastern Kingdoms", "azeroth", "Azeroth" end
  return ("continent:" .. tostring(continentMapID)), nil, nil
end

local function get_continent_map_id(uiMapID)
  if not (C_Map and C_Map.GetMapInfo and Enum and Enum.UIMapType) then return nil end
  local cur = uiMapID
  while cur and cur ~= 0 do
    local info = C_Map.GetMapInfo(cur)
    if not info then break end
    if info.mapType == Enum.UIMapType.Continent then
      return cur
    end
    cur = info.parentMapID
  end
  return nil
end

local function get_world_pos(mapID, nx, ny)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and createVec2) then return nil end
  local pos = createVec2(nx, ny)
  local _, worldPos = C_Map.GetWorldPosFromMapPos(mapID, pos)
  if not worldPos then return nil end
  return worldPos
end

-- =========================================================
-- ADT tile calculation constants
-- =========================================================
local ADT_TILE_SIZE = 533.33333
local ADT_HALF_SIZE = ADT_TILE_SIZE * 32  -- 17066.67

-- =========================================================
-- /adtgrid - Toggle ADT tile grid overlay on world map
-- =========================================================
local gridOverlay = nil
local gridEnabled = false
local gridLines = {}
local gridLabels = {}

local function CreateGridOverlay()
  if gridOverlay then return gridOverlay end
  
  local frame = CreateFrame("Frame", "ZoneMapGridOverlay", WorldMapFrame:GetCanvas())
  frame:SetAllPoints()
  frame:SetFrameStrata("HIGH")
  
  gridOverlay = frame
  return frame
end

local function UpdateGridOverlay()
  if not gridOverlay or not gridEnabled then return end
  
  -- Hide existing elements
  for _, line in ipairs(gridLines) do
    line:Hide()
  end
  for _, label in ipairs(gridLabels) do
    label:Hide()
  end
  
  -- Get current map
  local mapID = WorldMapFrame:GetMapID()
  if not mapID then return end
  
  local canvas = WorldMapFrame:GetCanvas()
  local canvasWidth, canvasHeight = canvas:GetSize()
  if canvasWidth == 0 or canvasHeight == 0 then return end
  
  -- Get world bounds for the current map
  local p00 = get_world_pos(mapID, 0, 0)
  local p11 = get_world_pos(mapID, 1, 1)
  if not (p00 and p11) then return end
  
  -- Calculate which tiles are visible
  local minWX, maxWX = math.min(p00.x, p11.x), math.max(p00.x, p11.x)
  local minWY, maxWY = math.min(p00.y, p11.y), math.max(p00.y, p11.y)
  
  local minTileX = math.max(0, math.floor((ADT_HALF_SIZE - maxWY) / ADT_TILE_SIZE) - 1)
  local maxTileX = math.min(63, math.ceil((ADT_HALF_SIZE - minWY) / ADT_TILE_SIZE) + 1)
  local minTileY = math.max(0, math.floor((ADT_HALF_SIZE - maxWX) / ADT_TILE_SIZE) - 1)
  local maxTileY = math.min(63, math.ceil((ADT_HALF_SIZE - minWX) / ADT_TILE_SIZE) + 1)
  
  local lineIdx = 0
  local labelIdx = 0
  
  -- Draw vertical lines (tile X boundaries)
  for tileX = minTileX, maxTileX + 1 do
    local worldY_line = ADT_HALF_SIZE - tileX * ADT_TILE_SIZE
    local nx = (worldY_line - p00.y) / (p11.y - p00.y)
    
    if nx >= -0.5 and nx <= 1.5 then
      lineIdx = lineIdx + 1
      local line = gridLines[lineIdx]
      if not line then
        line = gridOverlay:CreateLine(nil, "OVERLAY")
        line:SetThickness(2)
        gridLines[lineIdx] = line
      end
      
      line:SetColorTexture(1, 1, 0, 0.6)
      line:SetStartPoint("TOPLEFT", canvas, nx * canvasWidth, 0)
      line:SetEndPoint("BOTTOMLEFT", canvas, nx * canvasWidth, -canvasHeight)
      line:Show()
    end
  end
  
  -- Draw horizontal lines (tile Y boundaries)
  for tileY = minTileY, maxTileY + 1 do
    local worldX_line = ADT_HALF_SIZE - tileY * ADT_TILE_SIZE
    local ny = (worldX_line - p00.x) / (p11.x - p00.x)
    
    if ny >= -0.5 and ny <= 1.5 then
      lineIdx = lineIdx + 1
      local line = gridLines[lineIdx]
      if not line then
        line = gridOverlay:CreateLine(nil, "OVERLAY")
        line:SetThickness(2)
        gridLines[lineIdx] = line
      end
      
      line:SetColorTexture(1, 1, 0, 0.6)
      line:SetStartPoint("TOPLEFT", canvas, 0, -ny * canvasHeight)
      line:SetEndPoint("TOPRIGHT", canvas, canvasWidth, -ny * canvasHeight)
      line:Show()
    end
  end
  
  -- Check zoom level for labels
  local continentMapID = get_continent_map_id(mapID)
  local isZoomedIn = (mapID ~= continentMapID)
  local visibleTilesX = maxTileX - minTileX
  local visibleTilesY = maxTileY - minTileY
  local showLabels = isZoomedIn or (visibleTilesX <= 15 and visibleTilesY <= 15)
  
  -- Draw labels at tile centers
  if showLabels then
    for tileX = minTileX, maxTileX do
      for tileY = minTileY, maxTileY do
        local worldY_center = ADT_HALF_SIZE - (tileX + 0.5) * ADT_TILE_SIZE
        local worldX_center = ADT_HALF_SIZE - (tileY + 0.5) * ADT_TILE_SIZE
        
        local nx = (worldY_center - p00.y) / (p11.y - p00.y)
        local ny = (worldX_center - p00.x) / (p11.x - p00.x)
        
        if nx >= -0.1 and nx <= 1.1 and ny >= -0.1 and ny <= 1.1 then
          labelIdx = labelIdx + 1
          local label = gridLabels[labelIdx]
          if not label then
            label = gridOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            gridLabels[labelIdx] = label
          end
          
          label:ClearAllPoints()
          label:SetPoint("CENTER", canvas, "TOPLEFT", nx * canvasWidth, -ny * canvasHeight)
          label:SetText(string.format("%d,%d", tileX, tileY))
          label:SetTextColor(1, 1, 0, 0.9)
          label:Show()
        end
      end
    end
  end
end

local function ToggleGridOverlay(enable)
  if enable == nil then
    gridEnabled = not gridEnabled
  else
    gridEnabled = enable
  end
  
  if gridEnabled then
    CreateGridOverlay()
    gridOverlay:Show()
    
    if not gridOverlay.hooked then
      hooksecurefunc(WorldMapFrame, "OnMapChanged", UpdateGridOverlay)
      WorldMapFrame:HookScript("OnShow", UpdateGridOverlay)
      gridOverlay.hooked = true
    end
    
    UpdateGridOverlay()
    print("|cff00ff00ADT Grid overlay ENABLED|r")
  else
    if gridOverlay then
      gridOverlay:Hide()
    end
    print("|cffff0000ADT Grid overlay DISABLED|r")
  end
end

SLASH_ADTGRID1 = "/adtgrid"
SlashCmdList.ADTGRID = function()
  ToggleGridOverlay()
end

-- Update grid when map changes
if WorldMapFrame then
  WorldMapFrame:HookScript("OnShow", function()
    if gridEnabled then
      C_Timer.After(0.1, UpdateGridOverlay)
    end
  end)
end

-- =========================================================
-- Color and area info helpers 
-- =========================================================
local zoneColorCache = {}

local function AreaGivesExplorationXP(areaID)
  if addon.AreaInfo and addon.AreaInfo[areaID] then
    local level = addon.AreaInfo[areaID].explorationLevel
    return level and level > 0
  end
  return false
end

local colorWarned = {}

local function GetAreaColor(areaID)
  if zoneColorCache[areaID] then
    return unpack(zoneColorCache[areaID])
  end
  
  if not addon.AreaInfo then
    if not colorWarned["no_areainfo"] then
      print("|cffff0000ZoneMap ERROR: AreaInfo not loaded!|r")
      colorWarned["no_areainfo"] = true
    end
    zoneColorCache[areaID] = {1, 0, 1}
    return 1, 0, 1
  end
  
  local info = addon.AreaInfo[areaID]
  
  if not info or not info.color then
    if not colorWarned[areaID] then
      print(string.format("|cffffff00ZoneMap: No color for areaID %d|r", areaID))
      colorWarned[areaID] = true
    end
    -- Generate fallback color
    local golden_ratio = 0.618033988749895
    local hue = ((areaID * golden_ratio) % 1.0)
    local s, v = 0.65, 0.85
    local c = v * s
    local x = c * (1 - math.abs((hue * 6) % 2 - 1))
    local m = v - c
    local r, g, b
    local h_sector = math.floor(hue * 6)
    if h_sector == 0 then r, g, b = c, x, 0
    elseif h_sector == 1 then r, g, b = x, c, 0
    elseif h_sector == 2 then r, g, b = 0, c, x
    elseif h_sector == 3 then r, g, b = 0, x, c
    elseif h_sector == 4 then r, g, b = x, 0, c
    else r, g, b = c, 0, x
    end
    r, g, b = r + m, g + m, b + m
    zoneColorCache[areaID] = {r, g, b}
    return r, g, b
  end
  
  local color = info.color
  zoneColorCache[areaID] = color
  return color[1], color[2], color[3]
end

-- =========================================================
-- Draw all zones for the currently open map
-- =========================================================
local fillOverlay = nil
local fillTextures = {}
local fillLabels = {}
local fillEnabled = false

-- Exact area names to exclude (large water bodies that overwhelm zone rendering)
local EXCLUDED_AREAS = {
  ["The Great Sea"] = true,
  ["South Seas"] = true,
  ["South Sea"] = true,
  ["The Forbidding Sea"] = true,
  ["The Veiled Sea"] = true,
  ["Twisting Nether"] = true,
}

local function ShouldExcludeArea(areaID)
  if not addon.AreaInfo or not addon.AreaInfo[areaID] then return false end
  local name = addon.AreaInfo[areaID].name
  return name and EXCLUDED_AREAS[name]
end

-- Get all area IDs that belong to a root parent (excluding seas/oceans)
local function GetAreasForRootParent(rootParentID)
  local areas = {}
  local excluded = 0
  if addon.AreaHierarchy and addon.AreaHierarchy[rootParentID] then
    for areaID, _ in pairs(addon.AreaHierarchy[rootParentID].children) do
      if not ShouldExcludeArea(areaID) then
        areas[areaID] = true
      else
        excluded = excluded + 1
      end
    end
  end
  return areas, excluded
end

-- Core fill update function
local function UpdateFillOverlay(silent)
  if not fillEnabled then return end
  
  -- Get map info
  local mapID = WorldMapFrame:GetMapID()
  if not mapID then
    if not silent then print("Open world map first!") end
    return
  end
  
  local canvas = WorldMapFrame:GetCanvas()
  local canvasWidth, canvasHeight = canvas:GetSize()
  if canvasWidth == 0 then
    if not silent then print("Map canvas not ready") end
    return
  end
  
  local p00 = get_world_pos(mapID, 0, 0)
  local p11 = get_world_pos(mapID, 1, 1)
  if not (p00 and p11) then
    return  -- Silently fail for invalid maps
  end
  
  -- Get grid
  local continentMapID = get_continent_map_id(mapID)
  local _, _, gridName = continent_name_prefix_grid(continentMapID)
  local grid = gridName and addon.tileGrids[gridName]
  
  if not grid or not grid.tiles then
    -- Hide overlay if no grid data (e.g., continent view)
    if fillOverlay then fillOverlay:Hide() end
    return
  end
  
  -- Check required data
  if not addon.AreaInfo or not addon.AreaHierarchy or not addon.MapToArea then
    return
  end
  
  -- Look up area ID from the current map
  local mapInfo = addon.MapToArea[mapID]
  if not mapInfo then
    -- Map not in our data - hide overlay (e.g., continent or instance)
    if fillOverlay then fillOverlay:Hide() end
    return
  end
  
  local mapAreaID = mapInfo.areaId
  local mapName = mapInfo.name
  
  -- Get root parent
  local rootParentID = addon.AreaInfo[mapAreaID] and addon.AreaInfo[mapAreaID].rootParentId or mapAreaID
  local rootName = addon.AreaHierarchy[rootParentID] and addon.AreaHierarchy[rootParentID].name or mapName
  
  if not silent then
    print(string.format("|cff00ff00Drawing zones for map: %s (mapID: %d, rootAreaID: %d)|r", rootName, mapID, rootParentID))
  end
  
  -- Get all area IDs that share this root parent (excluding seas/oceans)
  local validAreas, excludedCount = GetAreasForRootParent(rootParentID)
  local areaCount = 0
  for _ in pairs(validAreas) do areaCount = areaCount + 1 end
  if not silent then
    local excludeMsg = excludedCount > 0 and string.format(" (excluded %d sea/ocean areas)", excludedCount) or ""
    print(string.format("  Found %d sub-areas in this zone%s", areaCount, excludeMsg))
  end
  
  -- Ensure overlay exists and is visible
  if not fillOverlay then return end
  fillOverlay:Show()
  
  -- Hide old textures and labels
  for _, tex in ipairs(fillTextures) do
    tex:Hide()
  end
  for _, label in ipairs(fillLabels) do
    label:Hide()
  end
  
  -- First pass: count total chunks to draw
  local totalChunks = 0
  for key, blob in pairs(grid.tiles) do
    local raw = decode_tile_blob(blob)
    if raw then
      for chunkY = 0, 15 do
        for chunkX = 0, 15 do
          local areaID = area_id_from_raw(raw, chunkX, chunkY)
          if areaID and areaID ~= 0 and validAreas[areaID] then
            totalChunks = totalChunks + 1
          end
        end
      end
    end
  end
  
  if not silent then
    print(string.format("  Total chunks to draw: %d", totalChunks))
  end
  
  local texIdx = 0
  local baseChunkSize = ADT_TILE_SIZE / 16
  local allAreaCounts = {}
  local tilesScanned = 0
  local chunksDrawn = 0
  local areaCentroids = {}
  
  -- Second pass: draw chunks
  for key, blob in pairs(grid.tiles) do
    local raw = decode_tile_blob(blob)
    if raw then
      tilesScanned = tilesScanned + 1
      
      local tileY = math.floor(key / 64)
      local tileX = key % 64
      
      for chunkY = 0, 15 do
        for chunkX = 0, 15 do
          local areaID = area_id_from_raw(raw, chunkX, chunkY)
          
          if areaID and areaID ~= 0 and validAreas[areaID] then
            allAreaCounts[areaID] = (allAreaCounts[areaID] or 0) + 1
            
            local chunkOffsetRow = (chunkX - 7.5) / 16
            local chunkOffsetCol = (chunkY - 7.5) / 16
            local chunkWorldY = ADT_HALF_SIZE - (tileX + 0.5 + chunkOffsetRow) * ADT_TILE_SIZE
            local chunkWorldX = ADT_HALF_SIZE - (tileY + 0.5 + chunkOffsetCol) * ADT_TILE_SIZE
            
            local nx = (chunkWorldY - p00.y) / (p11.y - p00.y)
            local ny = (chunkWorldX - p00.x) / (p11.x - p00.x)
            
            local chunkNormWidth = baseChunkSize / math.abs(p11.y - p00.y)
            local chunkNormHeight = baseChunkSize / math.abs(p11.x - p00.x)
            
            local pixelX = nx * canvasWidth
            local pixelY = ny * canvasHeight
            local pixelW = chunkNormWidth * canvasWidth * 1.05
            local pixelH = chunkNormHeight * canvasHeight * 1.05
            
            if not areaCentroids[areaID] then
              areaCentroids[areaID] = { sumX = 0, sumY = 0, count = 0 }
            end
            areaCentroids[areaID].sumX = areaCentroids[areaID].sumX + pixelX
            areaCentroids[areaID].sumY = areaCentroids[areaID].sumY + pixelY
            areaCentroids[areaID].count = areaCentroids[areaID].count + 1
            
            texIdx = texIdx + 1
            local tex = fillTextures[texIdx]
            if not tex then
              tex = fillOverlay:CreateTexture(nil, "ARTWORK")
              fillTextures[texIdx] = tex
            end
            
            local r, g, b = GetAreaColor(areaID)
            tex:SetColorTexture(r, g, b, 0.4)
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", canvas, "TOPLEFT", pixelX - pixelW/2, -(pixelY - pixelH/2))
            tex:SetSize(pixelW, pixelH)
            tex:Show()
            
            chunksDrawn = chunksDrawn + 1
          end
        end
      end
    end
  end
  
  -- Draw labels at centroids
  local labelIdx = 0
  for areaID, centroid in pairs(areaCentroids) do
    if centroid.count >= 2 then
      local avgX = centroid.sumX / centroid.count
      local avgY = centroid.sumY / centroid.count
      
      if avgX >= 0 and avgX <= canvasWidth and avgY >= 0 and avgY <= canvasHeight then
        labelIdx = labelIdx + 1
        local label = fillLabels[labelIdx]
        if not label then
          label = fillOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
          label:SetFont(label:GetFont(), 8, "OUTLINE")
          fillLabels[labelIdx] = label
        end
        
        local r, g, b = GetAreaColor(areaID)
        label:SetTextColor(r * 0.6, g * 0.6, b * 0.6, 1)
        label:ClearAllPoints()
        label:SetPoint("CENTER", canvas, "TOPLEFT", avgX, -avgY)
        local suffix = AreaGivesExplorationXP(areaID) and "*" or ""
        label:SetText(areaID .. suffix)
        label:Show()
      end
    end
  end
  
  if not silent then
    print(string.format("Scanned %d tiles, drew %d chunks, %d labels", tilesScanned, chunksDrawn, labelIdx))
    
    -- Print area ID summary
    print("Sub-zones found:")
    for aid, count in pairs(allAreaCounts) do
      local name = addon:GetAreaName(aid) or "?"
      print(string.format("  %d (%s): %d chunks", aid, name, count))
    end
  end
end

-- Toggle fill overlay
local function ToggleFillOverlay()
  fillEnabled = not fillEnabled
  
  if fillEnabled then
    -- Create overlay if needed
    if not fillOverlay then
      fillOverlay = CreateFrame("Frame", "ZoneMapFillOverlay", WorldMapFrame:GetCanvas())
      fillOverlay:SetAllPoints()
      fillOverlay:SetFrameStrata("TOOLTIP")
      fillOverlay:SetFrameLevel(200)
    end
    
    -- Hook map changes if not already hooked
    if not fillOverlay.hooked then
      hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
        UpdateFillOverlay(true)  -- Silent update on map change
      end)
      fillOverlay.hooked = true
    end
    
    UpdateFillOverlay(false)  -- Initial update with messages
    print("|cff00ff00Zone fill overlay ENABLED|r - updates when map changes")
  else
    if fillOverlay then
      fillOverlay:Hide()
      for _, tex in ipairs(fillTextures) do
        tex:Hide()
      end
      for _, label in ipairs(fillLabels) do
        label:Hide()
      end
    end
    print("|cffff0000Zone fill overlay DISABLED|r")
  end
end


-- =========================================================
-- Map button to toggle zone fill
-- =========================================================
local function CreateMapButton()
  if not WorldMapFrame then return end
  
  -- Parent to ScrollContainer so it stays fixed when zooming
  local parent = WorldMapFrame.ScrollContainer or WorldMapFrame
  local button = CreateFrame("Button", "ZoneMapToggleButton", parent, "UIPanelButtonTemplate")
  button:SetSize(80, 22)
  button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, -50)
  button:SetText("Zones")
  button:SetFrameStrata("TOOLTIP")
  button:SetFrameLevel(500)
  
  local function UpdateButtonState()
    if fillEnabled then
      button:SetText("Zones ON")
      button:GetNormalTexture():SetVertexColor(0.2, 0.8, 0.2)
    else
      button:SetText("Zones")
      button:GetNormalTexture():SetVertexColor(1, 1, 1)
    end
  end
  
  button:SetScript("OnClick", function()
    ToggleFillOverlay()
    UpdateButtonState()
  end)
  
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Toggle Zone Overlay")
    GameTooltip:AddLine("Shows sub-zone boundaries", 1, 1, 1)
    GameTooltip:AddLine("* = gives exploration XP", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  
  UpdateButtonState()
  return button
end

-- Create button when map loads
if WorldMapFrame then
  WorldMapFrame:HookScript("OnShow", function()
    if not ZoneMapToggleButton then
      CreateMapButton()
    end
  end)
end
