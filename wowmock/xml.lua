--[[
An addon's XML on the mock, the way the client loads it. Xml.Parse turns a
file into an element tree; Xml.Load walks a <Ui> in document order:

  <Script file>, <Include file>  handed to the loader (`load`)
  <Script> with a body           run as Lua
  virtual frames                 templates CreateFrame can inherit (Mock.templates)
  other frames                   created with their size, anchors, layers, special
                                 textures, child frames, key values and scripts;
                                 children's OnLoad runs before their parent's
  <Font>                         a font object

Elements the mock has no model for (backdrops, insets, ...) are skipped.
]]
local Mock = require("wowmock")
local Methods = Mock.Methods

local Xml = {}

-- Parsing ---------------------------------------------------------------------

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function Unescape(text)
	return (text:gsub("&(%a+);", function(name) return ENTITIES[name] end))
end

local function Attributes(text)
	local attributes = {}
	for key, _, value in text:gmatch("([%w_:]+)%s*=%s*([\"'])(.-)%2") do attributes[key] = Unescape(value) end
	return attributes
end

local function EscapeCData(body)
	return (body:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

-- { tag, attributes, children, text } per element; the document is the root.
function Xml.Parse(text, path)
	text = text:gsub("<!%[CDATA%[(.-)%]%]>", EscapeCData):gsub("<!%-%-.-%-%->", ""):gsub("<%?.-%?>", "")
	local root = { tag = "#document", attributes = {}, children = {} }
	local stack, position = { root }, 1
	while true do
		local first, last, closing, tag, attributes, selfClosing = text:find("<(/?)([%w_:]+)(.-)(/?)>", position)
		if not first then break end
		local top = stack[#stack]
		local between = text:sub(position, first - 1)
		if between:find("%S") then top.text = (top.text or "") .. Unescape(between) end
		if closing == "/" then
			if top.tag ~= tag then
				error(string.format("%s: </%s> closes <%s>", path or "xml", tag, top.tag), 0)
			end
			stack[#stack] = nil
		else
			local element = { tag = tag, attributes = Attributes(attributes), children = {} }
			top.children[#top.children + 1] = element
			if selfClosing ~= "/" then stack[#stack + 1] = element end
		end
		position = last + 1
	end
	if #stack > 1 then error(string.format("%s: <%s> is never closed", path or "xml", stack[#stack].tag), 0) end
	return root
end

local function Child(element, tag)
	for _, child in ipairs(element.children) do
		if child.tag == tag then return child end
	end
end

local function True(value) return value == "true" end

-- Frames ------------------------------------------------------------------------

Xml.FRAME_TYPES = {}
for tag in ([[Frame Button CheckButton Slider StatusBar EditBox ScrollFrame GameTooltip Cooldown Model PlayerModel
	ModelScene ColorSelect MessageFrame ScrollingMessageFrame SimpleHTML MovieFrame EventFrame DropdownButton
	ItemButton]]):gmatch("%S+") do
	Xml.FRAME_TYPES[tag] = true
end

-- Special regions a frame element declares, and the setter that takes them.
local SLOTS = {
	NormalTexture = "SetNormalTexture", PushedTexture = "SetPushedTexture",
	HighlightTexture = "SetHighlightTexture", DisabledTexture = "SetDisabledTexture",
	CheckedTexture = "SetCheckedTexture", DisabledCheckedTexture = "SetDisabledCheckedTexture",
	ThumbTexture = "SetThumbTexture", BarTexture = "SetStatusBarTexture", ButtonText = "SetFontString",
}
local SLOT_LAYERS = { HighlightTexture = "HIGHLIGHT", ButtonText = "OVERLAY" }

-- Script handler parameters after self.
local HANDLER_ARGS = {
	OnEvent = "event, ...", OnClick = "button, down", OnUpdate = "elapsed", OnEnter = "motion", OnLeave = "motion",
	OnMouseDown = "button", OnMouseUp = "button", OnMouseWheel = "delta", OnDragStart = "button",
	OnDragStop = "button", OnValueChanged = "value, userInput", OnSizeChanged = "width, height",
	OnKeyDown = "key", OnKeyUp = "key", OnTextChanged = "userInput", OnAttributeChanged = "name, value",
}

-- "$parentText" with the nearest named ancestor; nil without one.
local function ResolveName(name, parent)
	if not name or not name:find("%$[pP]arent") then return name end
	local ancestor = parent
	while ancestor and not ancestor.__state.name do ancestor = ancestor.__state.parent end
	if not ancestor then return nil end
	return (name:gsub("%$[pP]arent", ancestor.__state.name))
end

-- relativeTo="$parentIcon" / "UIParent", relativeKey="$parent.Icon" / "$parent.$parent".
local function RelativeRegion(anchor, region)
	local parent = region.__state.parent
	local key = anchor.attributes.relativeKey
	if key then
		local target = region
		for part in key:gmatch("[^.]+") do
			if part:match("^%$[pP]arent$") then target = target.__state.parent else target = target[part] end
			if not target then error("relativeKey " .. key .. " names no region", 0) end
		end
		return target
	end
	local name = anchor.attributes.relativeTo
	if not name then return nil end
	if name:match("^%$[pP]arent$") then return parent end
	return rawget(_G, ResolveName(name, parent))
end

local function Dimension(element)
	local source = Child(element, "AbsDimension") or element
	return tonumber(source.attributes.x), tonumber(source.attributes.y)
end

local function ApplyLayout(region, element)
	local attributes = element.attributes
	if attributes.hidden then region.__state.shown = not True(attributes.hidden) end
	if attributes.alpha then region:SetAlpha(tonumber(attributes.alpha)) end
	local parent = region.__state.parent
	if attributes.parentKey and parent then rawset(parent, attributes.parentKey, region) end
	if attributes.parentArray and parent then
		local list = rawget(parent, attributes.parentArray) or {}
		list[#list + 1] = region
		rawset(parent, attributes.parentArray, list)
	end
	local size = Child(element, "Size")
	if size then
		local width, height = Dimension(size)
		if width then region:SetWidth(width) end
		if height then region:SetHeight(height) end
	end
	if True(attributes.setAllPoints) then region:SetAllPoints() end
	local anchors = Child(element, "Anchors")
	for _, anchor in ipairs(anchors and anchors.children or {}) do
		local offset = Child(anchor, "Offset")
		local x, y = Dimension(offset or anchor)
		local point = anchor.attributes.point
		region:SetPoint(point, RelativeRegion(anchor, region), anchor.attributes.relativePoint or point, x or 0, y or 0)
	end
end

local function Color(element)
	local color = Child(element, "Color")
	if not color then return nil end
	local a = color.attributes
	return tonumber(a.r) or 0, tonumber(a.g) or 0, tonumber(a.b) or 0, tonumber(a.a) or 1
end

-- A Texture or FontString element on `frame`.
local function CreateRegion(frame, element, kind, layer)
	local attributes = element.attributes
	local name = ResolveName(attributes.name, frame)
	local region
	if kind == "FontString" then
		region = frame:CreateFontString(name, layer, attributes.inherits)
		if attributes.text then
			local text = rawget(_G, attributes.text)
			region:SetText(type(text) == "string" and text or attributes.text)
		end
		if attributes.justifyH then region:SetJustifyH(attributes.justifyH) end
		if attributes.justifyV then region:SetJustifyV(attributes.justifyV) end
		if Child(element, "Color") then region:SetTextColor(Color(element)) end
	elseif kind == "Line" then
		region = frame:CreateLine(name, layer)
	else
		region = frame:CreateTexture(name, layer)
		if attributes.file then region:SetTexture(attributes.file) end
		if attributes.atlas then region:SetAtlas(attributes.atlas, True(attributes.useAtlasSize)) end
		if attributes.alphaMode then region:SetBlendMode(attributes.alphaMode) end
		if Child(element, "Color") then region:SetColorTexture(Color(element)) end
		local coords = Child(element, "TexCoords")
		if coords then
			local a = coords.attributes
			region:SetTexCoord(tonumber(a.left) or 0, tonumber(a.right) or 1, tonumber(a.top) or 0, tonumber(a.bottom) or 1)
		end
	end
	ApplyLayout(region, element)
	return region
end

local function KeyValue(element)
	local a = element.attributes
	if a.type == "number" then return tonumber(a.value) end
	if a.type == "boolean" then return True(a.value) end
	if a.type == "global" then return rawget(_G, a.value) end
	return a.value
end

local function CompileScript(element, path)
	local a = element.attributes
	if a["function"] then
		local fn = rawget(_G, a["function"])
		if type(fn) ~= "function" then error(path .. ": " .. element.tag .. " names no function " .. a["function"], 0) end
		return fn
	end
	if a.method then
		local method = a.method
		return function(self, ...) return self[method](self, ...) end
	end
	local body = element.text or ""
	if not body:find("%S") then return nil end
	local args = HANDLER_ARGS[element.tag] or "..."
	local source = "return function(self, " .. args .. ")\n" .. body .. "\nend"
	return assert(loadstring(source, "@" .. path .. " " .. element.tag))()
end

local function ApplyScripts(frame, element, path)
	local scripts = Child(element, "Scripts")
	for _, script in ipairs(scripts and scripts.children or {}) do
		local fn = CompileScript(script, path)
		local previous = frame.__state.scripts[script.tag]
		local inherit = script.attributes.inherit
		if fn and previous and inherit == "prepend" then
			frame.__state.scripts[script.tag] = function(...) fn(...); return previous(...) end
		elseif fn and previous and inherit == "append" then
			frame.__state.scripts[script.tag] = function(...) previous(...); return fn(...) end
		elseif fn then
			frame.__state.scripts[script.tag] = fn
		end
	end
end

local CreateFrameElement

-- A frame element's content built into `frame` (a template's, or its own).
local function BuildFrame(frame, element, path)
	local attributes = element.attributes
	if attributes.frameStrata then frame:SetFrameStrata(attributes.frameStrata) end
	if attributes.frameLevel then frame:SetFrameLevel(tonumber(attributes.frameLevel)) end
	ApplyLayout(frame, element)
	local layers = Child(element, "Layers")
	for _, layer in ipairs(layers and layers.children or {}) do
		for _, region in ipairs(layer.children) do
			if region.tag == "Texture" or region.tag == "FontString" or region.tag == "Line" then
				CreateRegion(frame, region, region.tag, layer.attributes.level or "ARTWORK")
			end
		end
	end
	for _, child in ipairs(element.children) do
		local setter = SLOTS[child.tag]
		if setter then
			local kind = child.tag == "ButtonText" and "FontString" or "Texture"
			frame[setter](frame, CreateRegion(frame, child, kind, SLOT_LAYERS[child.tag] or "ARTWORK"))
		end
	end
	local keyValues = Child(element, "KeyValues")
	for _, keyValue in ipairs(keyValues and keyValues.children or {}) do
		rawset(frame, keyValue.attributes.key, KeyValue(keyValue))
	end
	local frames = Child(element, "Frames")
	for _, child in ipairs(frames and frames.children or {}) do
		if Xml.FRAME_TYPES[child.tag] then CreateFrameElement(child, frame, path) end
	end
	ApplyScripts(frame, element, path)
end

function CreateFrameElement(element, parent, path)
	local attributes = element.attributes
	if attributes.parent then parent = rawget(_G, attributes.parent) end
	local frame = Mock.NewFrame(element.tag, ResolveName(attributes.name, parent), parent, attributes.inherits)
	BuildFrame(frame, element, path)
	Methods.RunScript(frame, "OnLoad")
	return frame
end

local function RegisterTemplate(element, path)
	local inherits = element.attributes.inherits
	Mock.templates[element.attributes.name] = function(frame)
		Mock.ApplyTemplates(frame, inherits)
		BuildFrame(frame, element, path)
	end
end

local function CreateFontElement(element)
	local a = element.attributes
	local font = CreateFont(a.name)
	local inherited = a.inherits and rawget(_G, a.inherits)
	if inherited then font:SetFont(inherited:GetFont()) end
	if a.font then font:SetFont(a.font, tonumber(a.height) or 12, a.outline or "") end
	if Child(element, "Color") then font:SetTextColor(Color(element)) end
end

-- Loading -----------------------------------------------------------------------

-- Runs a parsed <Ui> document. `load(path)` loads a <Script>/<Include> file.
function Xml.Load(document, path, load)
	local dir = path:match("^(.*)/[^/]+$") or "."
	local ui = Child(document, "Ui") or document
	for _, element in ipairs(ui.children) do
		local attributes = element.attributes
		if (element.tag == "Script" or element.tag == "Include") and attributes.file then
			load(dir .. "/" .. attributes.file:gsub("\\", "/"))
		elseif element.tag == "Script" and element.text then
			assert(loadstring(element.text, "@" .. path))()
		elseif element.tag == "Font" and attributes.name and not True(attributes.virtual) then
			CreateFontElement(element)
		elseif Xml.FRAME_TYPES[element.tag] then
			if True(attributes.virtual) then
				RegisterTemplate(element, path)
			else
				CreateFrameElement(element, nil, path)
			end
		end
	end
end

return Xml
