local addonName = ...

PanelRegistry = { owner = addonName, plugins = {} }

function PanelRegistry.Register(pluginName)
	PanelRegistry.plugins[#PanelRegistry.plugins + 1] = pluginName
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
	for _, pluginName in ipairs(PanelRegistry.plugins) do
		_G[pluginName].OnPanelReady()
	end
end)
