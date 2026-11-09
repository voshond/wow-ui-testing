local addonName, ns = ...

ns.name = addonName
ns.loads = (ns.loads or 0) + 1

ns.CreateBar = function(parent)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetSize(120, 16)
	bar:SetPoint("CENTER")
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:SetStatusBarColor(0, 1, 0, 1)
	bar:SetMinMaxValues(0, 100)
	bar:SetValue(25)
	bar:GetStatusBarTexture()
	return bar
end

ns.CreateClassIcon = function(parent, classFile)
	local icon = parent:CreateTexture(nil, "ARTWORK")
	icon:SetSize(24, 24)
	icon:SetAtlas("classicon-" .. classFile:lower())
	return icon
end

ns.CreateRaidIcon = function(parent)
	local icon = parent:CreateTexture(nil, "OVERLAY")
	icon:SetAtlas("UI-HUD-UnitFrame-Player-PortraitOn-CornerEmbellishment")
	return icon
end
