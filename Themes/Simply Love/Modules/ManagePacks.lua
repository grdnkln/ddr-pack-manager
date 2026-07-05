-- ManagePacks.lua
-- A drop-in Simply Love "module" (no SL theme files modified). Lives in the user
-- directory (~/.itgmania/Themes/Simply Love/Modules/) which ITGmania unions over the
-- program install; SL's LoadModules (ScreenSystemLayer overlay.lua) picks it up
-- automatically and attaches it to ScreenSystemLayer.
--
-- What it does:
--   Adds a "Manage Packs" entry to the Advanced Options category of the Left+Right
--   sort menu on ScreenSelectMusic. Selecting it opens a scrolling, multi-select
--   checkbox list of the pack folders in ~/.itgmania/SongLibrary. Pressing Start
--   toggles a pack; "Done" saves the selection into the pressing player's section of
--   ~/.itgmania/Save/PlayerLoadHook/mapping.json (keyed by GrooveStats username,
--   preserving "*" and every other user), then broadcasts "PackManagerRefresh" so the
--   companion PlayerLoadHook module rebuilds PlayerSongs and reloads this session.
--
-- How it hooks into SL's sort menu WITHOUT editing the theme (three SL seams):
--   1. sortmenu.wheel_options -- a public field on the live SortMenu ActorFrame; we
--      table.insert our entry into the CategoryAdvanced sub-table at runtime.
--   2. sortmenu.custom_functions[key] -- SL's explicit extension hook; the input
--      handler dispatches focus.new_overlay there when no built-in branch matches.
--   3. WheelItemMT renders labels via THEME:HasString(...) or tostring(...) -- a key
--      with no en.ini string is shown verbatim, so we need no language-file edits.
--
-- ITGmania's Lua is sandboxed (no os/io); files are read/written with the engine's
-- RageFile API. "/Save/..." maps to the real Save dir (~/.itgmania/Save/); the
-- SongLibrary folder is visible at "/SongLibrary/" via the user-dir union mount.

-- The real SongLibrary folder (~/.itgmania/SongLibrary) is NOT visible inside the Lua
-- sandbox's virtual filesystem, so we can't list it directly. Instead the external
-- worker (packmanager.py) writes the available pack folder names to packs.json (a JSON
-- array of strings) under /Save/, which the sandbox CAN read -- same bridge pattern the
-- rest of this system uses.
local PACKS_FILE   = "/Save/PlayerLoadHook/packs.json"
local MAPPING_FILE = "/Save/PlayerLoadHook/mapping.json"

-- The bottom-text key is also the label shown and the custom_functions dispatch key.
local MENU_KEY = "Manage Packs"

------------------------------------------------------------
-- File helpers (same RageFile pattern as PlayerLoadHook.lua)

local function WriteFile(path, contents)
	local f = RageFileUtil.CreateRageFile()
	if f:Open(path, 2) then  -- 2 == write (truncates)
		f:Write(contents)
		f:Close()
	end
	f:destroy()
end

local function ReadFile(path)
	local f = RageFileUtil.CreateRageFile()
	local contents = nil
	if f:Open(path, 1) then  -- 1 == read
		contents = f:Read()
		f:Close()
	end
	f:destroy()
	return contents
end

------------------------------------------------------------
-- Shared session state (only one Manage Packs session can be open at a time)

local packs = {}       -- sorted array of pack folder names from SongLibrary
local selected = {}    -- { [packName] = true } for currently-checked packs
local username = ""    -- GrooveStats username of the player who opened the menu
local isOpen = false   -- guards the input redirect / safety teardown

-- Read the available pack folder names from packs.json (written by the worker). Returns
-- a sorted array of strings; empty if the file is missing/unreadable/malformed.
local function ListPacks()
	local list = {}
	local raw = ReadFile(PACKS_FILE)
	if raw and raw ~= "" then
		local ok, decoded = pcall(JsonDecode, raw)
		if ok and type(decoded) == "table" then
			for name in ivalues(decoded) do
				if type(name) == "string" then list[#list+1] = name end
			end
		end
	end
	table.sort(list, function(a, b) return a:lower() < b:lower() end)
	return list
end

-- Show the entry only when someone can actually use it: at least one human player
-- logged into GrooveStats (their username is the mapping.json key we edit).
local function ManagePacksAvailable()
	for player in ivalues(GAMESTATE:GetHumanPlayers()) do
		local pn = ToEnumShortString(player)
		if SL[pn].GrooveStatsUsername ~= nil and SL[pn].GrooveStatsUsername ~= "" then
			return true
		end
	end
	return false
end

------------------------------------------------------------
-- Scroll wheel: a sick_wheel with a custom checkbox item metatable.

local pack_wheel = setmetatable({}, sick_wheel_mt)

local box_w, box_h   = 380, 348
local row_height     = 24
local num_items      = 13

local pack_item_mt = {
	__index = {
		create_actors = function(self, name)
			local af = Def.ActorFrame{
				Name = name,
				InitCommand = function(subself) self.container = subself end,

				-- row background (focus highlight)
				Def.Quad{
					InitCommand = function(subself)
						self.bg = subself
						subself:setsize(box_w - 16, row_height - 2):diffuse(0.15,0.15,0.15,1)
					end,
				},
				-- checkbox glyph
				Def.BitmapText{
					Font = "Common Normal",
					InitCommand = function(subself)
						self.checkbox = subself
						subself:horizalign(left):x(-(box_w/2) + 12):zoom(0.4)
					end,
				},
				-- pack name
				Def.BitmapText{
					Font = "Common Normal",
					InitCommand = function(subself)
						self.label = subself
						subself:horizalign(left):x(-(box_w/2) + 52):zoom(0.5)
							:maxwidth((box_w - 70) / 0.5)
					end,
				},
			}
			return af
		end,

		set = function(self, info)
			self.info = info
			if not info then
				if self.label then self.label:settext("") end
				if self.checkbox then self.checkbox:settext("") end
				return
			end
			if info.action then
				-- "Done" / "Cancel" row: no checkbox, distinct styling.
				self.checkbox:settext("")
				self.label:settext(info.label):x(-(box_w/2) + 12)
			else
				self.label:settext(info.name):x(-(box_w/2) + 52)
				self.checkbox:settext(selected[info.name] and "[X]" or "[  ]")
			end
		end,

		transform = function(self, item_index, num, has_focus)
			self.container:finishtweening()
			self.container:smooth(0.1):y(row_height * (item_index - math.ceil(num/2)))

			-- hide the top/bottom rows so the list fades cleanly at the edges
			if item_index <= 1 or item_index >= num then
				self.container:diffusealpha(0)
			else
				self.container:diffusealpha(1)
			end

			local info = self.info
			local is_action = info and info.action
			if has_focus then
				self.bg:finishtweening():accelerate(0.1):diffuse(0.35,0.35,0.35,1)
				self.label:diffuse(is_action and color("#FFF25C") or Color.White)
			else
				self.bg:finishtweening():decelerate(0.1):diffuse(0.2,0.2,0.2,1)
				self.label:diffuse(is_action and color("#B0A83C") or color("#999999"))
			end
			if self.checkbox then self.checkbox:diffuse(has_focus and Color.White or color("#999999")) end
		end,
	}
}

-- Build the info_set: every pack as a checkbox row, then a Done and Cancel row.
local function BuildInfoSet()
	local info = {}
	for name in ivalues(packs) do
		info[#info+1] = { name = name }
	end
	info[#info+1] = { action = "done",   label = "Done (Save)" }
	info[#info+1] = { action = "cancel", label = "Cancel" }
	return info
end

------------------------------------------------------------
-- The module ActorFrame: injects the menu entry AND hosts the overlay UI.

-- Forward-declared upvalues wired up once the frame's InitCommand runs.
local mpFrame = nil
local managepacks_input = nil

local function CloseManagePacks()
	if not isOpen then return end
	isOpen = false
	local screen = SCREENMAN:GetTopScreen()
	if screen then
		screen:RemoveInputCallback(managepacks_input)
	end
	for player in ivalues(PlayerNumber) do
		SCREENMAN:set_input_redirected(player, false)
	end
	if mpFrame then mpFrame:playcommand("HideOverlay") end
end

local function SaveMapping()
	-- Re-read fresh so we merge against the latest on disk (preserve "*" + other users).
	local mapping = {}
	local raw = ReadFile(MAPPING_FILE)
	if raw and raw ~= "" then
		local ok, decoded = pcall(JsonDecode, raw)
		if ok and type(decoded) == "table" then mapping = decoded end
	end

	local chosen = {}
	for name in ivalues(packs) do
		if selected[name] then chosen[#chosen+1] = name end
	end
	table.sort(chosen, function(a, b) return a:lower() < b:lower() end)

	mapping[username] = chosen
	WriteFile(MAPPING_FILE, JsonEncode(mapping, false))
	SM(("Saved %d packs for %s"):format(#chosen, username))
end

local function OpenManagePacks(event)
	local screen = SCREENMAN:GetTopScreen()
	local overlay = screen and screen:GetChild("Overlay")
	local sortmenu = overlay and overlay:GetChild("SortMenu")
	if not (screen and overlay and sortmenu and mpFrame) then return end

	-- Which player opened it? We edit that player's mapping.json section.
	local pn = ToEnumShortString(event.PlayerNumber)
	username = SL[pn].GrooveStatsUsername or ""
	if username == "" then
		SM("Manage Packs needs a GrooveStats login")
		return
	end

	-- Close the SortMenu synchronously first (removes its input callback, un-redirects
	-- input, hides it) so input redirection is clean before we take over.
	sortmenu:playcommand("DirectInputToEngine")

	-- Load pack list + current selection.
	packs = ListPacks()
	selected = {}
	local raw = ReadFile(MAPPING_FILE)
	if raw and raw ~= "" then
		local ok, mapping = pcall(JsonDecode, raw)
		if ok and type(mapping) == "table" and type(mapping[username]) == "table" then
			for name in ivalues(mapping[username]) do selected[name] = true end
		end
	end

	-- Center the focused row (create_actors defaults focus_pos to floor(num/2), but the
	-- transform centers ceil(num/2)); align them so the highlighted row sits mid-box.
	pack_wheel.focus_pos = math.ceil(num_items / 2)
	pack_wheel:set_info_set(BuildInfoSet(), 1)
	mpFrame:GetChild("MPTitle"):settext("Manage Packs - "..username)

	-- Redirect input to us and show the overlay.
	for player in ivalues(PlayerNumber) do
		SCREENMAN:set_input_redirected(player, true)
	end
	screen:AddInputCallback(managepacks_input)
	isOpen = true
	mpFrame:playcommand("ShowOverlay")
end

-- Input handler while the overlay is open. Mirrors SL's SortMenu model: it returns
-- false and relies on set_input_redirected; the callback is always removed on close
-- (an un-removed callback would permanently eat input).
managepacks_input = function(event)
	if not (event and event.PlayerNumber and event.button) then return false end
	if event.type == "InputEventType_Release" then return false end
	if not isOpen then return false end

	local btn = event.GameButton
	if btn == "MenuDown" or btn == "MenuRight" then
		pack_wheel:scroll_by_amount(1)
		mpFrame:GetChild("MPChange"):play()
	elseif btn == "MenuUp" or btn == "MenuLeft" then
		pack_wheel:scroll_by_amount(-1)
		mpFrame:GetChild("MPChange"):play()
	elseif btn == "Start" then
		local item = pack_wheel:get_actor_item_at_focus_pos()
		local info = item and item.info
		if not info then return false end
		if info.action == "done" then
			SaveMapping()
			CloseManagePacks()
			-- PlayerLoadHook shows its box, re-signals the worker, and reloads.
			MESSAGEMAN:Broadcast("PackManagerRefresh")
		elseif info.action == "cancel" then
			CloseManagePacks()
		else
			selected[info.name] = not selected[info.name]
			item:set(info)  -- refresh just this row's checkbox, keep scroll position
		end
	elseif btn == "Back" or btn == "Select" then
		CloseManagePacks()
	end
	return false
end

------------------------------------------------------------
-- Inject our entry into the SortMenu's Advanced category. Runs each time we arrive
-- on ScreenSelectMusic; guarded so it injects once per (freshly built) SortMenu.
local function InjectMenuEntry()
	local screen = SCREENMAN:GetTopScreen()
	local overlay = screen and screen:GetChild("Overlay")
	local sortmenu = overlay and overlay:GetChild("SortMenu")
	if not sortmenu or not sortmenu.wheel_options then return end
	if sortmenu._managePacksInjected then return end
	sortmenu._managePacksInjected = true

	for opt in ivalues(sortmenu.wheel_options) do
		if type(opt[1]) == "table" and opt[1][2] == "CategoryAdvanced" and type(opt[2]) == "table" then
			table.insert(opt[2], { {"Curate Your Library", MENU_KEY}, ManagePacksAvailable })
			break
		end
	end
	sortmenu.custom_functions[MENU_KEY] = function(event) OpenManagePacks(event) end
end

local t = {}

t["ScreenSelectMusic"] = Def.ActorFrame{
	InitCommand = function(self)
		mpFrame = self
		self:visible(false)
	end,

	ModuleCommand = function(self)
		InjectMenuEntry()
	end,

	-- Safety net: if the screen changes while the overlay is open, make sure input
	-- redirection is released so input can never be stranded.
	ScreenChangedMessageCommand = function(self)
		if isOpen then
			isOpen = false
			for player in ivalues(PlayerNumber) do
				SCREENMAN:set_input_redirected(player, false)
			end
			self:playcommand("HideOverlay")
		end
	end,

	ShowOverlayCommand = function(self) self:visible(true) end,
	HideOverlayCommand = function(self) self:visible(false) end,

	-- dim the screen behind the box
	Def.Quad{
		InitCommand = function(self) self:FullScreen():diffuse(Color.Black):diffusealpha(0.8) end,
	},
	-- white border + black box
	Def.Quad{
		InitCommand = function(self) self:Center():zoomto(box_w + 2, box_h + 2) end,
	},
	Def.Quad{
		InitCommand = function(self) self:Center():zoomto(box_w, box_h):diffuse(Color.Black) end,
	},
	-- header bar + title
	Def.Quad{
		InitCommand = function(self)
			self:Center():zoomto(box_w, 22):y(_screen.cy - box_h/2 + 11):diffuse(color("#101519"))
		end,
	},
	Def.BitmapText{
		Name = "MPTitle",
		Font = "Common Bold",
		Text = "Manage Packs",
		InitCommand = function(self)
			self:Center():y(_screen.cy - box_h/2 + 11):zoom(0.4):diffuse(Color.White)
		end,
	},
	-- the scroll wheel, centered in the box body
	pack_wheel:create_actors("Manage Packs Wheel", num_items, pack_item_mt, _screen.cx, _screen.cy + 6),
	-- controls hint
	Def.BitmapText{
		Font = "Common Normal",
		Text = "START: toggle   ·   Done: save   ·   BACK: cancel",
		InitCommand = function(self)
			self:Center():y(_screen.cy + box_h/2 - 12):zoom(0.35):diffuse(0.7,0.7,0.7,1)
		end,
	},
	-- scroll sound
	LoadActor(THEME:GetPathS("ScreenSelectMaster", "change"))..{ Name="MPChange", IsAction=true, SupportPan=false },
}

return t
