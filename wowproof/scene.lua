local Scene = {}

Scene.REQUIRED = {
	"Parent", "Children", "Order", "Type", "Name",
	"Points", "Size", "Scale", "Shown", "Alpha", "IgnoresParentAlpha",
	"Strata", "Level", "Layer",
	"Texture", "Bar", "Text",
}

Scene.OPTIONAL = { "FillOf", "ClipsChildren", "Model" }

Scene.SOLID_FILES = {
	["interface\\buttons\\white8x8"] = true,
	["interface\\chatframe\\chatframebackground"] = true,
	["interface\\tooltips\\ui-tooltip-background"] = true,
}

function Scene.IsSolidFile(file)
	return type(file) == "string" and Scene.SOLID_FILES[file:lower()] == true
end

Scene.REGION_TYPES ={ Texture = true, FontString = true, Line = true, MaskTexture = true }

Scene.MODEL_TYPES = { Model = true, PlayerModel = true, DressUpModel = true, CinematicModel = true, TabardModel = true }

function Scene.IsModel(adapter, region)
	return Scene.MODEL_TYPES[adapter.Type(region)] == true
end

Scene.STRATA = {
	"WORLD", "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP",
}

Scene.LAYERS = { "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY", "HIGHLIGHT" }

local function Index(list)
	local index = {}
	for position, value in ipairs(list) do index[value] = position end
	return index
end
Scene.STRATA_INDEX = Index(Scene.STRATA)
Scene.LAYER_INDEX = Index(Scene.LAYERS)

function Scene.Validate(adapter)
	if type(adapter) ~= "table" then error("wowproof: the adapter must be a table of functions", 2) end
	local missing = {}
	for _, name in ipairs(Scene.REQUIRED) do
		if type(adapter[name]) ~= "function" then missing[#missing + 1] = name end
	end
	if #missing > 0 then
		error("wowproof: the adapter is missing " .. table.concat(missing, ", "), 2)
	end
	return adapter
end

function Scene.IsRegion(adapter, region)
	return Scene.REGION_TYPES[adapter.Type(region)] == true
end

return Scene
