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
