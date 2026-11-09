local addonName, ns = ...

ns.events = {}
ns.frame = CreateFrame("Frame")
ns.frame:RegisterEvent("ADDON_LOADED")
ns.frame:RegisterEvent("PLAYER_LOGIN")
ns.frame:SetScript("OnEvent", function(_, event, ...)
	ns.events[#ns.events + 1] = { event, ... }
	if event == "ADDON_LOADED" and ... == addonName then
		SampleAddonDB = SampleAddonDB or { loaded = 0 }
		SampleAddonDB.loaded = SampleAddonDB.loaded + 1
		C_Timer.After(1, function() ns.timerRan = true end)
	end
end)
