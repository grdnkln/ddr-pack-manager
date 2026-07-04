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
-- On session end / profile unload -- detected at ScreenGameOver (end of a game,
-- before the attract loop can start) or at the title (backing out of song select)
-- -- the per-player JSON files are emptied, trigger.txt is updated, an "Unloading song
-- packs" box shows for 5s (placeholder for the future worker), and then a FULL song
-- reload (ScreenReloadSongs) runs so packs an external worker removed from the
-- PlayerSongs additional folder actually vanish. Firing at Game Over (which stays up
-- ~23s) means the unload is prompt and can't be bypassed by the attract loop; the
-- reload then skips the rest of Game Over. (Only when a profile was actually loaded
-- that cycle, which also prevents a reload->title->reload loop.)
--
-- Companion setup (external to this file):
--   Preferences.ini AdditionalSongFoldersReadOnly=<...>/PlayerSongs -- an
--   always-mounted extra song root. A worker symlinks the players' packs into it
--   on load and clears it on unload; the reloads here make ITGMania pick up the
--   add (differential, on song select) and the removal (full, at gameover).
--
-- Output: /Save/PlayerLoadHook/{P1,P2}.json (full profile dump) + trigger.txt
-- (contains "players_loaded"/<time> on load, "players_unloaded"/<time> on unload).
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
-- Set true once a profile has been loaded this cycle (packs may be in PlayerSongs);
-- consumed at the title to run exactly one full cleanup reload, which also breaks
-- the reload->title->reload loop.
local reloadPending = false

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

-- Called when the session ends and profiles are unloaded (end of game / return
-- to title). Empties the per-player JSON files and updates the trigger.
local function ClearPlayerFiles()
	-- Opening in write mode truncates, so this leaves each file empty.
	WriteFile("/Save/PlayerLoadHook/P1.json", "")
	WriteFile("/Save/PlayerLoadHook/P2.json", "")

	WriteFile("/Save/PlayerLoadHook/trigger.txt",
		"players_unloaded\n"..tostring(GetTimeSinceStart()).."\n")

	Trace("[PlayerLoadHook] cleared player JSON (profiles unloaded)")
end

-- Trigger a FULL song reload (engine ScreenReloadSongs: OnlyLoadAdditions=false),
-- which re-scans every song root -- including the PlayerSongs additional folder --
-- so packs whose symlinks were removed actually disappear. Its NextScreen is the
-- title, which is exactly where we already are.
local function TriggerFullReload()
	SCREENMAN:SetNewScreen("ScreenReloadSongs")
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

-- Append the shared popup-box visuals (dim backdrop, box, colored bar, label, and
-- a pulsing dot) to an ActorFrame table, then return it. Used by both the load and
-- unload gates so they look identical apart from the label text.
local function AddBoxVisuals(af, labelText)
	af[#af+1] = Def.Quad{
		-- The parent frame is Center()'d, so FullScreen() (anchored at absolute
		-- screen top-left) would be shifted into one quadrant. A center-aligned
		-- quad of full screen size sits correctly on the centered origin instead.
		InitCommand=function(self) self:zoomto(_screen.w, _screen.h):diffuse(Color.Black):diffusealpha(0.82) end,
	}
	af[#af+1] = Def.Quad{
		InitCommand=function(self) self:zoomto(420, 130):diffuse(color("#101519")) end,
	}
	af[#af+1] = Def.Quad{
		InitCommand=function(self) self:zoomto(420, 4):y(-63):diffuse(GetCurrentColor()) end,
	}
	af[#af+1] = LoadFont("Common Normal")..{
		Text=labelText,
		InitCommand=function(self) self:y(-12):zoom(0.9):diffuse(Color.White):shadowlength(1) end,
	}
	af[#af+1] = LoadFont("Common Normal")..{
		Text="●",
		InitCommand=function(self) self:y(24):zoom(0.5):diffuse(GetCurrentColor()):diffusealpha(0.3) end,
		OnCommand=function(self)
			self:linear(0.5):diffusealpha(1):linear(0.5):diffusealpha(0.3):queuecommand("On")
		end,
	}
	return af
end

-- The "Setting up song packs" gate, hosted on each song-select screen. One is
-- created per host screen; they all share the upvalues above.
local function MakeGate()
	local af = Def.ActorFrame{
		InitCommand=function(self)
			self:Center():draworder(2000):visible(false):diffusealpha(0)
		end,

		ModuleCommand=function(self)
			if hasRun then return end
			hasRun = true
			-- A profile is now loaded; a full cleanup reload will be owed when we
			-- next return to the title (covers both gameover and backing out).
			reloadPending = true

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
	}
	return AddBoxVisuals(af, "Setting up song packs")
end

local t = {}

-- Register the gate on each screen that can immediately follow ScreenProfileLoad.
t["ScreenSelectMusic"]       = MakeGate()
t["ScreenSelectMusicCasual"] = MakeGate()
t["ScreenSelectCourse"]      = MakeGate()

-- Session end / profile unload. Fired on the first end-of-session screen we hit:
--   * ScreenGameOver -- the reliable end-of-game screen, reached BEFORE the attract
--     loop. Reloading here (rather than at the title) is what makes the unload
--     prompt: attract never gets a chance to bypass us. Game Over is effectively
--     skipped in favor of a guaranteed, timely unload -- an accepted tradeoff.
--   * ScreenTitleMenu / ScreenTitleJoin -- the backout-from-song-select path (no
--     Game Over), and where the once-per-cycle load guard is reset.
--
-- We clear the JSON, show the "Unloading song packs" box, wait 5s (placeholder for
-- the future worker clearing symlinks), then full-reload -- only when a profile was
-- actually loaded this cycle (reloadPending). Game Over stays up ~23s (TimerSeconds),
-- so the 5s box completes well before it would time out into attract. reloadPending
-- also:
--   * skips a spurious clear/reload at boot (title with no prior profile), and
--   * breaks the loop -- ScreenReloadSongs returns to the title, and on that second
--     arrival reloadPending is already false, so we don't reload again.
local function MakeUnloadHook(screenName)
	local af = Def.ActorFrame{
		InitCommand=function(self)
			self:Center():draworder(2000):visible(false):diffusealpha(0)
		end,

		ModuleCommand=function(self)
			hasRun = false
			if not reloadPending then return end
			reloadPending = false

			ClearPlayerFiles()
			self:visible(true):linear(0.15):diffusealpha(1)
			self:sleep(HOLD_SECONDS):queuecommand("Finish")
		end,

		FinishCommand=function(self)
			self:linear(0.2):diffusealpha(0):queuecommand("Hide")
		end,

		HideCommand=function(self)
			self:visible(false)
			-- Reload if we're still on the trigger screen, or have drifted to an
			-- idle screen (attract/title, no players joined). Skip if a new session
			-- has started (players joined) in the meantime.
			local screen = SCREENMAN:GetTopScreen()
			if screen and (screen:GetName() == screenName or GAMESTATE:GetNumSidesJoined() == 0) then
				TriggerFullReload()
			end
		end,
	}
	return AddBoxVisuals(af, "Unloading song packs")
end
t["ScreenGameOver"] = MakeUnloadHook("ScreenGameOver")
t["ScreenTitleMenu"] = MakeUnloadHook("ScreenTitleMenu")
t["ScreenTitleJoin"] = MakeUnloadHook("ScreenTitleJoin")

return t
