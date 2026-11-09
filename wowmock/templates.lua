--[[
Blizzard templates whose content Lua addons rely on, as Mock.templates
builders (Mock.Install registers them).

TooltipBackdropTemplate (Blizzard_SharedXML/SharedTooltipTemplates.xml): a
NineSlice child laid out by NineSliceLayouts' TooltipDefaultLayout, with
TooltipBackdropTemplateMixin's colour setters and its OnLoad colouring the
centre TOOLTIP_DEFAULT_BACKGROUND_COLOR.
]]
local Mock = require("wowmock")

local TOOLTIP_LAYOUT = {
	{ key = "TopLeftCorner", atlas = "Tooltip-NineSlice-CornerTopLeft", point = "TOPLEFT" },
	{ key = "TopRightCorner", atlas = "Tooltip-NineSlice-CornerTopRight", point = "TOPRIGHT" },
	{ key = "BottomLeftCorner", atlas = "Tooltip-NineSlice-CornerBottomLeft", point = "BOTTOMLEFT" },
	{ key = "BottomRightCorner", atlas = "Tooltip-NineSlice-CornerBottomRight", point = "BOTTOMRIGHT" },
	{ key = "TopEdge", atlas = "_Tooltip-NineSlice-EdgeTop", point = "TOPLEFT", relativePoint = "TOPRIGHT",
		between = { "TopLeftCorner", "TopRightCorner" } },
	{ key = "BottomEdge", atlas = "_Tooltip-NineSlice-EdgeBottom", point = "BOTTOMLEFT", relativePoint = "BOTTOMRIGHT",
		between = { "BottomLeftCorner", "BottomRightCorner" } },
	{ key = "LeftEdge", atlas = "!Tooltip-NineSlice-EdgeLeft", point = "TOPLEFT", relativePoint = "BOTTOMLEFT",
		between = { "TopLeftCorner", "BottomLeftCorner" } },
	{ key = "RightEdge", atlas = "!Tooltip-NineSlice-EdgeRight", point = "TOPRIGHT", relativePoint = "BOTTOMRIGHT",
		between = { "TopRightCorner", "BottomRightCorner" } },
	{ key = "Center", atlas = "Tooltip-NineSlice-Center", layer = "BACKGROUND" },
}
local BORDER_PIECES = { "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
	"TopEdge", "BottomEdge", "LeftEdge", "RightEdge" }

local function Piece(nineSlice, piece)
	local texture = nineSlice:CreateTexture(nil, piece.layer or "BORDER")
	rawset(nineSlice, piece.key, texture)
	texture:SetAtlas(piece.atlas, true)
	local info = C_Texture.GetAtlasInfo(piece.atlas)
	if info then texture:SetSize(info.width, info.height) end
	if piece.key == "Center" then
		texture:SetPoint("TOPLEFT", nineSlice.TopLeftCorner, "BOTTOMRIGHT", -4, 4)
		texture:SetPoint("BOTTOMRIGHT", nineSlice.BottomRightCorner, "TOPLEFT", 4, -4)
	elseif piece.between then
		texture:SetPoint(piece.point, nineSlice[piece.between[1]], piece.relativePoint)
		texture:SetPoint(piece.relativePoint, nineSlice[piece.between[2]], piece.point)
	else
		texture:SetPoint(piece.point, nineSlice, piece.point)
	end
end

-- NineSlicePanelMixin's colour API on a laid-out NineSlice.
local function NineSlicePanel(nineSlice)
	local center, border = { 1, 1, 1, 1 }, { 1, 1, 1, 1 }
	rawset(nineSlice, "SetCenterColor", function(self, r, g, b, a)
		center = { r, g, b, a or 1 }
		self.Center:SetVertexColor(r, g, b, a or 1)
	end)
	rawset(nineSlice, "GetCenterColor", function() return unpack(center) end)
	rawset(nineSlice, "SetBorderColor", function(self, r, g, b, a)
		border = { r, g, b, a or 1 }
		for _, key in ipairs(BORDER_PIECES) do self[key]:SetVertexColor(r, g, b, a or 1) end
	end)
	rawset(nineSlice, "GetBorderColor", function() return unpack(border) end)
end

-- Blizzard_SharedXML/SharedTooltipTemplates.lua; addons guard on the global
-- before inheriting the template.
local TooltipBackdropTemplateMixin = {}

function TooltipBackdropTemplateMixin:TooltipBackdropOnLoad()
	local color = rawget(self, "backdropColor") or TOOLTIP_DEFAULT_BACKGROUND_COLOR
	local r, g, b = color:GetRGB()
	self:SetBackdropColor(r, g, b, rawget(self, "backdropColorAlpha") or 1)
end

function TooltipBackdropTemplateMixin:SetBackdropColor(...) self.NineSlice:SetCenterColor(...) end
function TooltipBackdropTemplateMixin:GetBackdropColor() return self.NineSlice:GetCenterColor() end
function TooltipBackdropTemplateMixin:SetBackdropBorderColor(...) self.NineSlice:SetBorderColor(...) end
function TooltipBackdropTemplateMixin:GetBackdropBorderColor() return self.NineSlice:GetBorderColor() end

local function TooltipBackdrop(frame)
	rawset(frame, "layoutType", "TooltipDefaultLayout")
	local nineSlice = CreateFrame("Frame", nil, frame)
	nineSlice:SetAllPoints(frame)
	rawset(frame, "NineSlice", nineSlice)
	for _, piece in ipairs(TOOLTIP_LAYOUT) do Piece(nineSlice, piece) end
	NineSlicePanel(nineSlice)
	for key, method in pairs(TooltipBackdropTemplateMixin) do rawset(frame, key, method) end
	frame:SetScript("OnLoad", frame.TooltipBackdropOnLoad)
end

return function()
	_G.TooltipBackdropTemplateMixin = TooltipBackdropTemplateMixin
	Mock.templates.TooltipBackdropTemplate = TooltipBackdrop
end
