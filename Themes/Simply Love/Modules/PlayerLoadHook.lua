-- PlayerLoadHook.lua
-- A drop-in Simply Love "module" (no SL files modified). It lives in the user
-- directory (~/.itgmania/Themes/Simply Love/Modules/) which ITGmania unions on
-- top of the program install; SL's LoadModules (ScreenSystemLayer overlay.lua)
-- picks it up automatically and attaches it to ScreenSystemLayer.
--
-- Behavior (once per game cycle, on reaching song select == the screen right
-- after profiles load):
--   1. Show a "Setting up song packs" box.
--   2. Write each player's full profile as pretty JSON to disk.
--   3. Pause 5 seconds.
--   4. Fade the box out and trigger a differential "Load New Songs" reload
--      (ScreenReloadSongsSSM), which returns to song select.
--   The box is a purely visual overlay -- input is NOT blocked, so the player can
--   still use the song wheel and sort menu behind it.
--
-- Output: /Save/PlayerLoadHook/{P1,P2}.json (full profile dump) + trigger.txt.
--
-- Why here and not on ScreenProfileLoad: SL's ScreenProfileLoad auto-advances
-- after ~1s (its overlay calls Continue()), and the module wrapper hides a
-- module's actors the moment you leave its keyed screen -- so a screen we don't
-- own can't be held open for 5s. The song-select screen is ScreenProfileLoad's
-- immediate NextScreen, so gating its entry is functionally "loading box, then
-- the next screen." By this point every player's profile AND GrooveStats
-- identity (saved key or fresh QR login) are fully resolved.
--
-- ITGmania's Lua is sandboxed (no os/io, no os.execute), so we can't launch a
-- process directly; we write signal files with the engine's RageFile API and an
-- external watcher reacts to them.

local HOLD_SECONDS = 5
local hasRun = false  -- shared across all screen entries below (file-closure upvalue)

-- Write a string to a path in the engine's virtual FS.
-- "/Save/..." maps to the real Save dir (on Linux: ~/.itgmania/Save/).
local function WriteFile(path, contents)
	local f = RageFileUtil.CreateRageFile()
	if f:Open(path, 2) then  -- 2 == write
		f:Write(contents)
		f:Close()
	end
	f:destroy()
end

-- No-argument Profile getters that return a scalar (string/number/bool/enum).
-- We call each reflectively so we dump "everything we know" without hand-listing
-- values, and stay resilient if a getter is missing on a given engine build.
local PROFILE_SCALAR_GETTERS = {
	"GetDisplayName", "GetGUID", "GetType", "GetPriority",
	"GetLastUsedHighScoreName", "GetIgnoreStepCountCalories",
	"GetIsMale", "GetAge", "GetBirthYear", "GetWeightPounds", "GetVoomax",
	"GetGoalType", "GetGoalCalories", "GetGoalSeconds",
	"GetCaloriesBurnedToday", "GetTotalCaloriesBurned", "GetDisplayTotalCaloriesBurned",
	"GetNumToasties", "GetNumTotalSongsPlayed", "GetTotalNumSongsPlayed",
	"GetTotalDancePoints", "GetTotalTapsAndHolds", "GetTotalJumps", "GetTotalHolds",
	"GetTotalMines", "GetTotalHands", "GetTotalRolls", "GetTotalLifts",
	"GetTotalGameplaySeconds", "GetTotalSessions", "GetTotalSessionSeconds",
}

-- Serialize as much of a Profile object as we can into a plain Lua table.
local function ProfileToTable(profile)
	local out = {}
	if not profile then return out end

	for _, method in ipairs(PROFILE_SCALAR_GETTERS) do
		local fn = profile[method]
		if type(fn) == "function" then
			local ok, val = pcall(fn, profile)
			if ok and (type(val) == "string" or type(val) == "number" or type(val) == "boolean") then
				out[method:gsub("^Get", "")] = val
			end
		end
	end

	-- The theme-writable user table (arbitrary nested data other themes/mods store).
	local ok, userTable = pcall(profile.GetUserTable, profile)
	if ok and type(userTable) == "table" then out.UserTable = userTable end

	-- A couple of object-returning getters: pull a human-readable name if present.
	local ok2, song = pcall(profile.GetLastPlayedSong, profile)
	if ok2 and song then
		local ok3, title = pcall(song.GetDisplayFullTitle, song)
		if ok3 then out.LastPlayedSong = title end
	end
	local ok4, char = pcall(profile.GetCharacter, profile)
	if ok4 and char then
		local ok5, name = pcall(char.GetDisplayName, char)
		if ok5 then out.Character = name end
	end

	return out
end

local function WritePlayerFiles()
	for player in ivalues(GAMESTATE:GetHumanPlayers()) do
		local pn = ToEnumShortString(player)  -- "P1" / "P2"

		local data = {
			player = pn,
			loaded_at = GetTimeSinceStart(),
			display_name = GAMESTATE:GetPlayerDisplayName(player),
			is_persistent_profile = PROFILEMAN:IsPersistentProfile(player),
			groovestats = {
				username = SL[pn].GrooveStatsUsername or "",
				linked = (SL[pn].ApiKey ~= nil and SL[pn].ApiKey ~= ""),
				is_pad_player = SL[pn].IsPadPlayer,
			},
			profile = ProfileToTable(PROFILEMAN:GetProfile(player)),
		}

		-- JsonEncode(data, minify=false) -> pretty-printed JSON.
		local ok, json = pcall(JsonEncode, data, false)
		WriteFile("/Save/PlayerLoadHook/"..pn..".json", ok and json or "{}")
	end

	-- Single combined signal file that changes on every run, for the watcher.
	WriteFile("/Save/PlayerLoadHook/trigger.txt",
		"players_loaded\n"..tostring(GetTimeSinceStart()).."\n")

	Trace("[PlayerLoadHook] wrote player profile JSON to /Save/PlayerLoadHook/")
end

local RELOAD_HOSTS = {
	ScreenSelectMusic=true, ScreenSelectMusicCasual=true, ScreenSelectCourse=true,
}

-- Kick off a differential "Load New Songs" reload, exactly like the advanced/sort
-- menu's option: switch to ScreenReloadSongsSSM (OnlyLoadAdditions=true), whose
-- NextScreen returns to song select.
local function TriggerSongReload(screen)
	-- Cancel any in-flight GetScores request first, or replacing the screen can
	-- raise a "Stale ActorFrame" error (mirrors SL's SortMenu LoadNewSongs path).
	-- This actor only exists on ScreenSelectMusic, so guard every hop.
	local overlay = screen:GetChild("Overlay")
	local pane = overlay and overlay:GetChild("PaneDisplayMaster")
	local requester = pane and pane:GetChild("GetScoresRequester")
	if requester then requester:playcommand("Cancel") end

	SCREENMAN:SetNewScreen("ScreenReloadSongsSSM")
end

-- Build a fresh loading-box gate actor. One is created per host screen; they all
-- share the upvalues above (so the hasRun guard is global across screens).
local function MakeGate()
	return Def.ActorFrame{
		InitCommand=function(self)
			self:Center():draworder(2000):visible(false):diffusealpha(0)
		end,

		ModuleCommand=function(self)
			if hasRun then return end
			hasRun = true

			-- 1) Popup appears. (Purely visual -- input is NOT blocked, so the
			--    player can still use the song wheel / sort menu behind the box.)
			self:visible(true):linear(0.15):diffusealpha(1)

			-- 2) Write the profile JSON right away.
			WritePlayerFiles()

			-- 3) Pause 5 seconds, then reload.
			self:sleep(HOLD_SECONDS):queuecommand("Finish")
		end,

		FinishCommand=function(self)
			-- Fade the box out, then reload songs (step 4).
			self:linear(0.2):diffusealpha(0):queuecommand("Hide")
		end,

		HideCommand=function(self)
			self:visible(false)

			-- Only reload if the player is still on a song-select screen. Input
			-- isn't blocked, so they may have moved on to options/gameplay during
			-- the 5s -- in that case a screen swap would be very disruptive, so skip.
			local screen = SCREENMAN:GetTopScreen()
			local name = screen and screen:GetName() or ""
			if RELOAD_HOSTS[name] then
				TriggerSongReload(screen)
			end
		end,

		-- Dim the whole screen.
		Def.Quad{
			InitCommand=function(self)
				self:FullScreen():diffuse(Color.Black):diffusealpha(0.82)
			end,
		},

		-- The box.
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(420, 130):diffuse(color("#101519"))
			end,
		},
		Def.Quad{
			InitCommand=function(self)
				self:zoomto(420, 4):y(-63):diffuse(GetCurrentColor())
			end,
		},

		LoadFont("Common Normal")..{
			Text="Setting up song packs",
			InitCommand=function(self)
				self:y(-12):zoom(0.9):diffuse(Color.White):shadowlength(1)
			end,
		},
		-- Simple pulsing dot so it reads as "working".
		LoadFont("Common Normal")..{
			Text="●",
			InitCommand=function(self)
				self:y(24):zoom(0.5):diffuse(GetCurrentColor()):diffusealpha(0.3)
			end,
			OnCommand=function(self)
				self:linear(0.5):diffusealpha(1):linear(0.5):diffusealpha(0.3):queuecommand("On")
			end,
		},
	}
end

local t = {}

-- Register the gate on each screen that can immediately follow ScreenProfileLoad.
t["ScreenSelectMusic"]       = MakeGate()
t["ScreenSelectMusicCasual"] = MakeGate()
t["ScreenSelectCourse"]      = MakeGate()

-- Reset the once-per-cycle guard whenever a new game cycle begins at the title.
t["ScreenTitleMenu"] = Def.Actor{ ModuleCommand=function(self) hasRun = false end }
t["ScreenTitleJoin"] = Def.Actor{ ModuleCommand=function(self) hasRun = false end }

return t
