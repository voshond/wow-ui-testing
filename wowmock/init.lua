--[[
A mock of the WoW client API, enough to load an addon through its TOC and
test its logic offline (LuaJIT or Lua 5.1, the client's Lua semantics).

Widgets are plain tables that keep simple state and record calls. Methods
without an explicit implementation are accepted and recorded, so code can call
them, and tests can inspect obj.__calls. Every method call and documented
global function is held to the client API snapshot (wowmock/api.lua):
undocumented methods, rejected arguments, secrets where the client refuses
them and protected calls in combat all raise errors.

Secret(v) creates a fake secret value: a table without arithmetic or
comparison metamethods, so doing maths or comparisons on it raises an error,
just like a real secret does. issecretvalue() recognises it.

Hosts add their own pieces with Mock.Extend(name, { globals = { ... },
install = fn, installUI = fn }): globals are cleared on every Install, and the
steps run at the end of Install / InstallUI, before the API is enforced.
]]
local Mock = {}
local API = require("wowmock.api")
Mock.API = API

local SecretMT = { __tostring = function() return "<secret>" end }

function Mock.Secret(value)
	return setmetatable({ secretValue = value }, SecretMT)
end

-- Concatenating secrets is allowed in the client and gives a secret string.
SecretMT.__concat = function()
	return Mock.Secret("concat")
end

function Mock.IsSecret(value)
	return type(value) == "table" and getmetatable(value) == SecretMT
end

local function AnySecret(...)
	for i = 1, select("#", ...) do
		if Mock.IsSecret((select(i, ...))) then
			return true
		end
	end
	return false
end

-- Widgets ---------------------------------------------------------------------

local Methods = {}
local ObjectMT = {}
Mock.Methods = Methods

-- Regions that draw inside a frame and have no frame level of their own.
local REGION_TYPES = { Texture = true, Line = true, FontString = true, MaskTexture = true }

local registry -- all created objects, reset per Mock.Install()

local function NewObject(objectType, parent, name)
	local obj = setmetatable({
		__type = objectType,
		__calls = {},
		__state = {
			shown = true,
			points = {},
			width = 0,
			height = 0,
			level = parent and parent.__state and (parent.__state.level + 1) or 0,
			parent = parent,
			scripts = {},
			events = {},
			name = name,
		},
	}, ObjectMT)
	registry[#registry + 1] = obj
	if parent and parent.__state then
		parent.__state.kids = parent.__state.kids or {}
		parent.__state.kids[obj] = true
	end
	if name then
		_G[name] = obj
	end
	return obj
end
Mock.NewObject = NewObject

-- Blizzard's secure code (secure delegates, engine updates simulated by specs)
-- runs untainted: the client accepts secrets and protected calls from it.
local untainted = 0
function Mock.RunUntainted(fn, ...)
	untainted = untainted + 1
	local results = { pcall(fn, ...) }
	untainted = untainted - 1
	if not results[1] then error(results[2], 0) end
	return unpack(results, 2, table.maxn(results))
end

function Mock.RunTainted(fn, ...)
	local previous = untainted
	untainted = 0
	local results = { pcall(fn, ...) }
	untainted = previous
	if not results[1] then error(results[2], 0) end
	return unpack(results, 2, table.maxn(results))
end

-- Like CreateSecureDelegate: `fn` runs untainted for every caller.
function Mock.SecureDelegate(fn)
	return function(...) return Mock.RunUntainted(fn, ...) end
end

-- Forbidden layout aspect (UntrustedLayoutScriptExecution). Regions get it
-- from DisableUntrustedLayoutScriptsTemplate at creation, from a native aura
-- container once it has a group, and from any ancestor that has it. Addon
-- code may only anchor or parent a region to one of these when the region
-- carries the aspect as well; their layout scripts (OnSizeChanged) never run.
local LAYOUT_ASPECT_TEMPLATE = "DisableUntrustedLayoutScriptsTemplate"
function Mock.HasLayoutAspect(obj)
	while type(obj) == "table" do
		local s = rawget(obj, "__state")
		if not s then return false end
		if s.layoutAspect then return true end
		obj = s.parent
	end
	return false
end
local function CheckLayoutAspect(self, relative, action)
	if untainted == 0 and Mock.HasLayoutAspect(relative) and not Mock.HasLayoutAspect(self) then
		error(action .. ": a region without forbidden layout aspects cannot inherit them"
			.. " (create it with " .. LAYOUT_ASPECT_TEMPLATE .. ")", 4)
	end
end

-- Test-only conveniences on mock objects. Addon code must never call them.
Mock.HELPERS = { GetAnchor = true, RunScript = true }
-- Intrinsic types whose Lua mixins come without a named template.
local INTRINSIC_MIXINS = { AuraContainer = true, EventFrame = true, DropdownButton = true }

local function CheckMethod(self, key, ...)
	local objectType = rawget(self, "__type")
	-- Native aura buttons deny tainted access while aura data is secret
	-- (Enum.ScriptObjectAccessRestriction.DenyTaintedAccessWhenAurasAreSecret).
	if Mock.aurasSecret and untainted == 0 and self.__state.auraRestricted then
		error(string.format("calling '%s' on bad self (Attempt to access forbidden object from code tainted by an AddOn)",
			key), 3)
	end
	local def, modelled = API.Method(objectType, key)
	if def then
		if def.protected and untainted == 0 and self.__state.protected and InCombatLockdown() then
			error(string.format("%s:%s is protected and blocked in combat", objectType, key), 3)
		end
		API.CheckArgs(objectType, key, def, Mock.IsSecret, untainted > 0, ...)
	elseif modelled and not Mock.HELPERS[key] then
		local templated = self.__state.template or INTRINSIC_MIXINS[objectType]
		if not (templated and API.LuaMethod(key)) then
			error(string.format("%s:%s is not a documented method%s", objectType, key,
				API.LuaMethod(key) and " (it needs a template providing " .. API.LuaMethod(key) .. ")" or ""), 3)
		end
	end
end

-- One checked entry point per method name: the explicit implementation, or
-- for any other method, record the call.
local wrappers = {}
local function Wrapped(key)
	local wrapper = wrappers[key]
	if not wrapper then
		wrapper = function(self, ...)
			CheckMethod(self, key, ...)
			local impl = Methods[key]
			if impl then return impl(self, ...) end
			self.__calls[#self.__calls + 1] = { key, ... }
		end
		wrappers[key] = wrapper
	end
	return wrapper
end

-- Whether a modelled object has the method `key`, as the client answers a
-- read: documented for its type, or a Lua mixin method its template brings.
-- Unmodelled mock objects have every method.
local function HasMethod(obj, key)
	if Mock.HELPERS[key] then return true end
	local objectType = rawget(obj, "__type")
	local def, modelled = API.Method(objectType, key)
	if def or not modelled then return true end
	local templated = (rawget(obj, "__state") or {}).template or INTRINSIC_MIXINS[objectType]
	return templated and API.LuaMethod(key) ~= nil
end

ObjectMT.__index = function(obj, key)
	if type(key) ~= "string" then return nil end
	if not Methods[key] then
		-- Strict objects behave like real frames for unknown keys (nil), for code
		-- that probes optional fields like frame.Health.
		if rawget(obj, "__strict") then return nil end
		-- Widget methods are PascalCase; lowercase keys are addon fields
		-- (frame.anchor, a heal prediction calculator's values), nil until set.
		if key:find("^%l") then return nil end
	end
	-- Probes for methods other addons add (ElvUI's frame.StripTextures) or a
	-- template's (frame.SetBackdrop) read nil, as in the client.
	if not HasMethod(obj, key) then return nil end
	return Wrapped(key)
end

local function Record(self, name, ...)
	self.__calls[#self.__calls + 1] = { name, ... }
end

function Methods:GetObjectType() return self.__type end
function Methods:IsObjectType(t)
	local objectType = self.__type
	while objectType do
		if objectType == t then return true end
		objectType = API.PARENTS[objectType]
	end
	return false
end
function Methods:GetName() return self.__state.name end
function Methods:SetMouseClickEnabled(enabled)
	self.__state.mouseClickEnabled = enabled
	self.__calls[#self.__calls + 1] = { "SetMouseClickEnabled", enabled }
end
function Methods:SetMouseMotionEnabled(enabled)
	self.__state.mouseMotionEnabled = enabled
	self.__calls[#self.__calls + 1] = { "SetMouseMotionEnabled", enabled }
end
function Methods:SetRotation(radians) self.__state.rotation = radians end
function Methods:GetFrameRef(label) return self.__state.frameRefs and self.__state.frameRefs[label] end

function Methods:SetScript(name, fn)
	if name == "OnSizeChanged" then self.__state.backdropSizeScript = false end
	self.__state.scripts[name] = fn
end
function Methods:GetScript(name) return self.__state.scripts[name] end
-- Whether the widget type supports a handler: the mock lets every type take
-- any On* script, so any handler name answers true.
function Methods:HasScript(name) return type(name) == "string" and name:match("^On%u") ~= nil end
function Methods:HookScript(name, fn)
	local previous = self.__state.scripts[name]
	self.__state.scripts[name] = function(...)
		if previous then
			previous(...)
		end
		fn(...)
	end
end
function Methods:RunScript(name, ...)
	local wrapper = self.__state.secureWrappers and self.__state.secureWrappers[name]
	if wrapper then Mock.RunRestrictedSnippet(wrapper.header, wrapper.body, self, ...) end
	local fn = self.__state.scripts[name]
	if fn then
		return Mock.RunTainted(fn, self, ...)
	end
end

function Methods:Show()
	local changed = not self.__state.shown
	self.__state.shown = true
	if changed then self:RunScript("OnShow") end
end
function Methods:Hide()
	local changed = self.__state.shown
	self.__state.shown = false
	if changed then self:RunScript("OnHide") end
end
-- A secret argument gives the region a secret shown state (the Shown
-- secret aspect): IsShown and IsVisible then return secrets too.
function Methods:SetShown(shown)
	if Mock.IsSecret(shown) then self.__state.shown = shown
	elseif shown then self:Show()
	else self:Hide() end
end
function Methods:IsShown() return self.__state.shown end
local function RolesetFiltered(self)
	for _, name in ipairs(self.__state.rolesets or {}) do
		if name == "alwaysBlocked" then return true end
	end
	return false
end

function Methods:IsVisible()
	local shown = self:IsShown()
	if Mock.IsSecret(shown) then return Mock.Secret(shown.secretValue) end
	if RolesetFiltered(self) then return false end
	local parent = self:GetParent()
	return shown and (not parent or parent:IsVisible())
end

function Methods:SetRolesets(names)
	local rolesets = {}
	for name in (names or ""):gmatch("[^,]+") do rolesets[#rolesets + 1] = name end
	self.__state.rolesets = rolesets
end

function Methods:GetRolesetNames()
	local rolesets = self.__state.rolesets
	if not rolesets or #rolesets == 0 then return { "roleless" } end
	local copy = {}
	for index, name in ipairs(rolesets) do copy[index] = name end
	return copy
end

function Methods:IsRolesetFiltered()
	return RolesetFiltered(self)
end

function Methods:SetParent(parent)
	CheckLayoutAspect(self, parent, "SetParent")
	local previous = self.__state.parent
	if previous and previous.__state and previous.__state.kids then previous.__state.kids[self] = nil end
	if parent and parent.__state then
		parent.__state.kids = parent.__state.kids or {}
		parent.__state.kids[self] = true
	end
	self.__state.parent = parent
	-- Like the client, a reparented frame moves to its new parent's level + 1.
	local level = parent and rawget(parent, "__state") and parent.__state.level
	if level and not self.__state.fixedLevel and not REGION_TYPES[self.__type] then
		Methods.SetFrameLevel(self, level + 1)
	end
end
function Methods:GetParent() return self.__state.parent end

local function Resize(self, width, height)
	local s = self.__state
	local changed = s.width ~= width or s.height ~= height
	s.width, s.height = width, height
	if not changed or Mock.HasLayoutAspect(self) then return end
	if s.backdropSizeScript and s.backdrop then
		local setup = rawget(self, "SetupTextureCoordinates") or BackdropTemplateMixin.SetupTextureCoordinates
		setup(self)
	end
	if s.scripts.OnSizeChanged then
		s.scripts.OnSizeChanged(self, width, height)
	end
end
-- Test helper: dimensions the engine gives a frame (e.g. secret ones from
-- anchoring), bypassing the addon-facing SetSize checks.
function Mock.SetEngineSize(obj, width, height)
	Resize(obj, width, height)
end
local function CheckTextureDimensions(self, ...)
	if self.__type == "Texture" then
		assert(not AnySecret(...), "Texture dimensions require untainted execution for secret values")
	end
end
function Methods:SetSize(width, height)
	CheckTextureDimensions(self, width, height)
	Resize(self, width, height)
end
function Methods:SetWidth(width)
	CheckTextureDimensions(self, width)
	Resize(self, width, self.__state.height)
end
function Methods:SetHeight(height)
	CheckTextureDimensions(self, height)
	Resize(self, self.__state.width, height)
end
function Methods:GetSize() return self.__state.width, self.__state.height end
function Methods:GetWidth() return self.__state.width end
function Methods:GetHeight() return self.__state.height end
function Methods:SetScale(scale) self.__state.scale = scale end
function Methods:GetScale() return self.__state.scale or 1 end
function Methods:GetEffectiveScale() return self.__state.scale or 1 end

-- Like the client, anchors accept a region's global name for the relative region.
local function Relative(relativeTo)
	if type(relativeTo) ~= "string" then return relativeTo end
	local region = rawget(_G, relativeTo)
	if type(region) ~= "table" or not rawget(region, "__state") then
		error("SetPoint: unknown region '" .. relativeTo .. "'", 3)
	end
	return region
end

function Methods:SetPoint(point, relativeTo, relativePoint, x, y)
	if type(relativeTo) == "number" then
		relativeTo, relativePoint, x, y = nil, point, relativeTo, relativePoint
	end
	relativeTo = Relative(relativeTo)
	CheckLayoutAspect(self, relativeTo, "SetPoint")
	local points = self.__state.points
	for i, p in ipairs(points) do
		if p[1] == point then
			table.remove(points, i)
			break
		end
	end
	points[#points + 1] = { point, relativeTo, relativePoint or point, x or 0, y or 0 }
end
function Methods:SetAllPoints(relativeTo)
	relativeTo = Relative(relativeTo)
	CheckLayoutAspect(self, relativeTo, "SetAllPoints")
	self.__state.points = { { "ALL", relativeTo } }
end
function Methods:ClearAllPoints() self.__state.points = {} end
function Methods:GetNumPoints() return #self.__state.points end
function Methods:GetPoint(index)
	local p = self.__state.points[index or 1]
	if p then
		return p[1], p[2], p[3], p[4], p[5]
	end
end
-- Test helper: the anchor entry for a given point name.
function Methods:GetAnchor(point)
	for _, p in ipairs(self.__state.points) do
		if p[1] == point then
			return p
		end
	end
end

-- Like the client, a changed level re-levels the frame's children above it,
-- except frames with a fixed level (and what they hold).
local function RelevelChildren(frame)
	for child in pairs(frame.__state.kids or {}) do
		if not child.__state.fixedLevel and child.__state.parent == frame then
			child.__state.level = frame.__state.level + 1
			RelevelChildren(child)
		end
	end
end
function Methods:SetFrameLevel(level)
	local changed = self.__state.level ~= level
	self.__state.level = level
	if changed then RelevelChildren(self) end
end
function Methods:SetFixedFrameLevel(fixed) self.__state.fixedLevel = fixed == true end
function Methods:SetFrameStrata(strata) self.__state.strata = strata end
function Methods:SetFixedFrameStrata(fixed) self.__state.fixedStrata = fixed == true end
function Methods:RegisterForDrag(...) Record(self, "RegisterForDrag", ...) end
-- Button texture slots: an asset path fills the slot's own child texture,
-- a texture object takes the slot over. Get returns the slot's texture.
for _, slot in ipairs({ "Normal", "Pushed", "Highlight", "Disabled" }) do
	local key = slot:lower() .. "Texture"
	Methods["Set" .. slot .. "Texture"] = function(self, asset)
		if type(asset) == "table" then
			self.__state[key] = asset
			return
		end
		local texture = self.__state[key]
		if not texture then
			texture = Methods.CreateTexture(self, nil, slot == "Highlight" and "HIGHLIGHT" or "ARTWORK")
			texture:SetAllPoints(self)
			self.__state[key] = texture
		end
		texture:SetTexture(asset)
	end
	Methods["Get" .. slot .. "Texture"] = function(self) return self.__state[key] end
	Methods["Clear" .. slot .. "Texture"] = function(self) self.__state[key] = nil end
end
function Methods:SetFontString(fontString) self.__state.fontString = fontString end
function Methods:GetFontString() return self.__state.fontString end
function Methods:LockHighlight() self.__state.highlightLocked = true end
function Methods:UnlockHighlight() self.__state.highlightLocked = false end
-- Screen geometry from the anchors, through wowproof's layout, in the
-- region's own scale. The client measures from the bottom left of the screen
-- (UIParent's size, 1920x1080 while it has none); nil while unanchored.
Mock.SCREEN = { width = 1920, height = 1080 }
local function ScreenRect(region)
	local Layout = require("wowproof.layout")
	local adapter = require("wowproof.adapters.mock_state")({
		isSecret = Mock.IsSecret,
		reveal = function(value) return value.secretValue end,
		objects = function() return registry end,
		globals = _G,
	})
	local width, height = UIParent.__state.width, UIParent.__state.height
	if width == 0 or height == 0 then width, height = Mock.SCREEN.width, Mock.SCREEN.height end
	local layout = Layout.New(adapter, { width = width, height = height })
	local rect = layout:Rect(region)
	if not rect then return nil end
	local scale = layout:Scale(region)
	return rect.left / scale, (height - rect.top - rect.height) / scale, rect.width / scale, rect.height / scale
end

function Methods:GetRect() return ScreenRect(self) end
function Methods:GetLeft()
	local left = ScreenRect(self)
	return left
end
function Methods:GetRight()
	local left, _, width = ScreenRect(self)
	return left and left + width
end
function Methods:GetBottom()
	local _, bottom = ScreenRect(self)
	return bottom
end
function Methods:GetTop()
	local _, bottom, _, height = ScreenRect(self)
	return bottom and bottom + height
end
-- Specs may pin a centre (__state.center); otherwise it comes from the anchors.
function Methods:GetCenter()
	local center = self.__state.center
	if center then return center[1], center[2] end
	local left, bottom, width, height = ScreenRect(self)
	if left then return left + width / 2, bottom + height / 2 end
end
function Methods:IsProtected() return self.__state.protected == true end
function Methods:SetAttribute(name, value)
	self.__state.attributes = self.__state.attributes or {}
	local previous = self.__state.attributes[name]
	self.__state.attributes[name] = value
	if previous ~= value then self:RunScript("OnAttributeChanged", name, value) end
end
function Methods:GetAttribute(name) return self.__state.attributes and self.__state.attributes[name] end
function Methods:RegisterForClicks(...) Record(self, "RegisterForClicks", ...) end
function Methods:GetChildren()
	local children = {}
	for _, obj in ipairs(registry) do if obj.__state.parent == self then children[#children + 1] = obj end end
	return unpack(children)
end
function Methods:GetFrameLevel() return self.__state.level end

function Methods:SetAlpha(alpha)
	assert(Mock.IsSecret(alpha) or type(alpha) == "number", "alpha must be numeric")
	self.__state.alpha = alpha
	Record(self, "SetAlpha", alpha)
end
local function BelowSecretAlpha(self)
	local parent = self.__state.parent
	while parent do
		if parent.__state and Mock.IsSecret(parent.__state.alpha) then return true end
		parent = parent.__state and parent.__state.parent
	end
	return false
end
-- Observed in game (Forever, October 2026): a region's own secret alpha, and
-- any alpha below a secret alpha, reads back secret.
function Methods:GetAlpha()
	local alpha = self.__state.alpha
	if alpha == nil then alpha = 1 end
	if BelowSecretAlpha(self) and not Mock.IsSecret(alpha) then return Mock.Secret(alpha) end
	return alpha
end
-- Observed in game (Forever, October 2026), unlike its documented secret
-- aspect: while any alpha in the parent chain is secret, the client withholds
-- the effective alpha and returns nil.
function Methods:GetEffectiveAlpha()
	local own = self:GetAlpha()
	if own == nil or Mock.IsSecret(own) then return nil end
	local parent = not self.__state.ignoreParentAlpha and self:GetParent()
	if not parent then return own end
	local inherited = parent:GetEffectiveAlpha()
	if inherited == nil then return nil end
	return own * inherited
end
function Methods:SetIgnoreParentAlpha(ignore) self.__state.ignoreParentAlpha = ignore end
function Methods:SetModelAlpha(alpha)
	assert(Mock.IsSecret(alpha) or type(alpha) == "number",
		"bad argument #1 to 'SetModelAlpha' (Usage: self:SetModelAlpha(alpha))")
	self.__state.modelAlpha = alpha
	Record(self, "SetModelAlpha", alpha)
end
function Methods:SetAlphaFromBoolean(value, ifTrue, ifFalse)
	assert(Mock.IsSecret(value) or type(value) == "boolean", "value must be a boolean")
	Record(self, "SetAlphaFromBoolean", value, ifTrue, ifFalse)
	-- Model native selection, retaining the alpha's secrecy for the next
	-- native call. Tests alone may inspect secretValue as an engine oracle.
	local boolean = value
	if Mock.IsSecret(value) then boolean = value.secretValue end
	local alpha
	if boolean then alpha = ifTrue else alpha = ifFalse end
	if AnySecret(value, ifTrue, ifFalse) then
		if Mock.IsSecret(alpha) then alpha = alpha.secretValue end
		alpha = Mock.Secret(alpha)
	end
	self:SetAlpha(alpha)
end

function Methods:CreateTexture(name, layer)
	local t = NewObject("Texture", self, name)
	t.__state.layer = layer
	return t
end
function Methods:CreateLine(name, layer)
	local line = NewObject("Line", self, name)
	line.__state.layer = layer
	return line
end
function Methods:CreateFontString(name, layer, inherits)
	local fs = NewObject("FontString", self, name)
	fs.__state.layer = layer
	fs.__state.fontObject = inherits
	return fs
end
function Methods:CreateAnimationGroup() return NewObject("AnimationGroup", self) end
-- Animation groups keep their play state; tests set __state.progress to
-- model an animation's eased progress.
function Methods:Play() Record(self, "Play"); self.__state.playing = true end
function Methods:Stop() Record(self, "Stop"); self.__state.playing = false end
function Methods:IsPlaying() return self.__state.playing == true end
function Methods:GetSmoothProgress() return self.__state.progress or 0 end
function Methods:CreateAnimation(animationType) return NewObject(animationType or "Animation", self) end

-- StatusBar
function Methods:GetStatusBarTexture()
	if not self.__state.fill then
		self.__state.fill = NewObject("Texture", self)
	end
	return self.__state.fill
end
function Methods:SetStatusBarTexture(texture)
	Record(self, "SetStatusBarTexture", texture)
	self.__state.texture = texture
	return true
end
function Methods:SetMinMaxValues(min, max) self.__state.min, self.__state.max = min, max end
function Methods:GetMinMaxValues() return self.__state.min, self.__state.max end
function Methods:SetValue(value, interpolation)
	self.__state.value = value
	self.__state.interpolation = interpolation
end
function Methods:GetValue() return self.__state.value end
function Methods:SetStatusBarColor(r, g, b, a) self.__state.color = { r, g, b, a } end
function Methods:SetOrientation(orientation) self.__state.orientation = orientation end
function Methods:GetOrientation() return self.__state.orientation or "HORIZONTAL" end
function Methods:SetReverseFill(reverse) self.__state.reverseFill = reverse end
function Methods:SetTimerDuration(duration, interpolation, direction)
	self.__state.timer = { duration = duration, interpolation = interpolation, direction = direction }
end

function Methods:SetTimeFromStart(start, length)
	self.__state.start, self.__state.length = start, length
end

-- Texture
function Methods:SetTexture(texture) self.__state.texture = texture end
function Methods:SetTexCoord(...) self.__state.texCoords = { ... } end
function Methods:SetBlendMode(mode) self.__state.blendMode = mode end
function Methods:SetTextureSliceMargins(left, top, right, bottom)
	self.__state.sliceMargins = { left, top, right, bottom }
end
function Methods:GetTextureSliceMargins()
	local margins = self.__state.sliceMargins
	if margins then return unpack(margins) end
end
function Methods:SetTextureSliceMode(mode) self.__state.sliceMode = mode end
function Methods:GetTextureSliceMode() return self.__state.sliceMode end
function Methods:SetGradient(orientation, minColor, maxColor)
	self.__state.gradient = { orientation, { minColor:GetRGBA() }, { maxColor:GetRGBA() } }
end
function Methods:SetDesaturated(desaturated)
	Record(self, "SetDesaturated", desaturated)
	self.__state.desaturated = desaturated
end
function Methods:SetDesaturation(strength)
	assert(type(strength) == "number", "bad argument #1 to 'SetDesaturation' (Usage: self:SetDesaturation(strength))")
	Record(self, "SetDesaturation", strength)
	self.__state.desaturation = strength
end
function Methods:GetTexture() return self.__state.texture end
function Methods:SetVertexColor(r, g, b, a) self.__state.vertexColor = { r, g, b, a } end
function Methods:SetColorTexture(r, g, b, a) self.__state.colorTexture = { r, g, b, a } end
-- Like the client, the texture then reports the atlas's file and drops
-- earlier texture coordinates: the atlas brings its own sub-rectangle.
function Methods:SetAtlas(atlas, useAtlasSize)
	Record(self, "SetAtlas", atlas, useAtlasSize)
	self.__state.atlas = atlas
	self.__state.texture = "atlas:" .. tostring(atlas)
	self.__state.texCoords = nil
end

-- FontString
function Methods:GetFont()
	return unpack(self.__state.font or {})
end

function Methods:SetFont(path, size, flags)
	Record(self, "SetFont", path, size, flags)
	if type(path) ~= "string" or path == "" then
		return false
	end
	self.__state.font = { path, size, flags }
	return true
end
-- Like the client: a FontString needs a font before it can show text.
local function RequireFont(fs)
	local s = fs.__state
	if fs.__type == "FontString" and not (s.font or s.fontObject) then
		error("FontString:SetText(): Font not set", 3)
	end
end
function Methods:SetText(text)
	RequireFont(self)
	self.__state.text = text
end
function Methods:SetFontObject(font) self.__state.fontObject = font end
function Methods:SetFormattedText(fmt, ...)
	RequireFont(self)
	if AnySecret(...) then
		self.__state.text = Mock.Secret(fmt)
	else
		self.__state.text = string.format(fmt, ...)
	end
end
function Methods:GetText() return self.__state.text end
function Methods:SetTextColor(r, g, b, a) self.__state.textColor = { r, g, b, a } end
-- Text width estimate: visible characters (colour codes dropped, an inline
-- texture as two) times the font size times 0.62, a little wider than the
-- sans-serif wowproof renders. Secret text keeps the old fixed 50.
local function FontSize(region)
	local font = region.__state.font
	if font and font[2] then return font[2] end
	local object = region.__state.fontObject
	if type(object) == "string" then object = rawget(_G, object) end
	local objectFont = type(object) == "table" and rawget(object, "__state") and object.__state.font
	return objectFont and objectFont[2] or 12
end
function Methods:GetStringWidth()
	local text = self.__state.text
	if text == nil then return 0 end
	if type(text) == "number" then text = tostring(text) end
	if type(text) ~= "string" then return 50 end
	local plain = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "WW")
	return #plain * FontSize(self) * 0.62
end

-- Backdrop (BackdropTemplate)
local borderPieces = { "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
	"TopEdge", "BottomEdge", "LeftEdge", "RightEdge" }

local NINE_SLICE = {
	{ name = "TopLeftCorner", point = "TOPLEFT" },
	{ name = "TopRightCorner", point = "TOPRIGHT" },
	{ name = "BottomLeftCorner", point = "BOTTOMLEFT" },
	{ name = "BottomRightCorner", point = "BOTTOMRIGHT" },
	{ name = "TopEdge", point = "TOPLEFT", relativePoint = "TOPRIGHT", between = { "TopLeftCorner", "TopRightCorner" } },
	{ name = "BottomEdge", point = "BOTTOMLEFT", relativePoint = "BOTTOMRIGHT", between = { "BottomLeftCorner", "BottomRightCorner" } },
	{ name = "LeftEdge", point = "TOPLEFT", relativePoint = "BOTTOMLEFT", between = { "TopLeftCorner", "BottomLeftCorner" } },
	{ name = "RightEdge", point = "TOPRIGHT", relativePoint = "BOTTOMRIGHT", between = { "TopRightCorner", "BottomRightCorner" } },
	{ name = "Center" },
}
local BACKDROP_COORD_START = 0.0625
local BACKDROP_COORD_END = 1 - BACKDROP_COORD_START
local BACKDROP_UV_ORDER = { "ULx", "ULy", "LLx", "LLy", "URx", "URy", "LRx", "LRy" }
local BACKDROP_UVS = {
	TopLeftCorner = { ULx = 0.5078125, ULy = BACKDROP_COORD_START, LLx = 0.5078125, LLy = BACKDROP_COORD_END,
		URx = 0.6171875, URy = BACKDROP_COORD_START, LRx = 0.6171875, LRy = BACKDROP_COORD_END },
	TopRightCorner = { ULx = 0.6328125, ULy = BACKDROP_COORD_START, LLx = 0.6328125, LLy = BACKDROP_COORD_END,
		URx = 0.7421875, URy = BACKDROP_COORD_START, LRx = 0.7421875, LRy = BACKDROP_COORD_END },
	BottomLeftCorner = { ULx = 0.7578125, ULy = BACKDROP_COORD_START, LLx = 0.7578125, LLy = BACKDROP_COORD_END,
		URx = 0.8671875, URy = BACKDROP_COORD_START, LRx = 0.8671875, LRy = BACKDROP_COORD_END },
	BottomRightCorner = { ULx = 0.8828125, ULy = BACKDROP_COORD_START, LLx = 0.8828125, LLy = BACKDROP_COORD_END,
		URx = 0.9921875, URy = BACKDROP_COORD_START, LRx = 0.9921875, LRy = BACKDROP_COORD_END },
	TopEdge = { ULx = 0.2578125, ULy = "repeatX", LLx = 0.3671875, LLy = "repeatX",
		URx = 0.2578125, URy = BACKDROP_COORD_START, LRx = 0.3671875, LRy = BACKDROP_COORD_START },
	BottomEdge = { ULx = 0.3828125, ULy = "repeatX", LLx = 0.4921875, LLy = "repeatX",
		URx = 0.3828125, URy = BACKDROP_COORD_START, LRx = 0.4921875, LRy = BACKDROP_COORD_START },
	LeftEdge = { ULx = 0.0078125, ULy = BACKDROP_COORD_START, LLx = 0.0078125, LLy = "repeatY",
		URx = 0.1171875, URy = BACKDROP_COORD_START, LRx = 0.1171875, LRy = "repeatY" },
	RightEdge = { ULx = 0.1328125, ULy = BACKDROP_COORD_START, LLx = 0.1328125, LLy = "repeatY",
		URx = 0.2421875, URy = BACKDROP_COORD_START, LRx = 0.2421875, LRy = "repeatY" },
	Center = { ULx = 0, ULy = 0, LLx = 0, LLy = "repeatY", URx = "repeatX", URy = 0, LRx = "repeatX", LRy = "repeatY" },
}
local CORNER_SIZE = { TopLeftCorner = "both", TopRightCorner = "both", BottomLeftCorner = "both",
	BottomRightCorner = "both", TopEdge = "height", BottomEdge = "height", LeftEdge = "width", RightEdge = "width" }

function Methods:SetBackdrop(info)
	if not info or not (info.edgeFile or info.bgFile) then self:ClearBackdrop(); return end
	-- BackdropTemplateMixin:SetBackdrop ignores the info table it already holds.
	if self.__state.backdrop == info then return end
	self.__state.backdrop = info
	local edgeSize = self:GetEdgeSize()
	local x, y, x1, y1 = 0, 0, 0, 0
	if info.bgFile then
		local insets = info.insets or {}
		x, y = -edgeSize + (insets.left or 0), edgeSize - (insets.top or 0)
		x1, y1 = edgeSize - (insets.right or 0), -edgeSize + (insets.bottom or 0)
	end
	local pieces = self.__state.backdropPieces or {}
	self.__state.backdropPieces = pieces
	for _, setup in ipairs(NINE_SLICE) do
		local center = setup.name == "Center"
		local piece = rawget(self, setup.name) or self:CreateTexture(nil, center and "BACKGROUND" or "BORDER")
		self[setup.name], pieces[setup.name] = piece, piece
		piece:ClearAllPoints()
		if center then
			piece:SetPoint("TOPLEFT", pieces.TopLeftCorner, "BOTTOMRIGHT", x, y)
			piece:SetPoint("BOTTOMRIGHT", pieces.BottomRightCorner, "TOPLEFT", x1, y1)
			piece:SetTexture(info.bgFile)
			piece:SetSize(0, 0)
		else
			if setup.between then
				piece:SetPoint(setup.point, pieces[setup.between[1]], setup.relativePoint)
				piece:SetPoint(setup.relativePoint, pieces[setup.between[2]], setup.point)
			else
				piece:SetPoint(setup.point, self, setup.point)
			end
			piece:SetTexture(info.edgeFile)
			local size = CORNER_SIZE[setup.name]
			piece:SetSize((size == "both" or size == "width") and edgeSize or 0, (size == "both" or size == "height") and edgeSize or 0)
		end
	end
	self:SetBackdropColor(1, 1, 1, 1)
	self:SetBackdropBorderColor(1, 1, 1, 1)
	local setupTextureCoordinates = rawget(self, "SetupTextureCoordinates") or BackdropTemplateMixin.SetupTextureCoordinates
	setupTextureCoordinates(self)
end
function Methods:GetBackdrop() return self.__state.backdrop end
function Methods:GetEdgeSize()
	local size = self.__state.backdrop.edgeSize
	return size and size > 0 and size or 39
end
function Methods:ClearBackdrop()
	self.__state.backdrop = nil
	for _, setup in ipairs(NINE_SLICE) do
		local texture = rawget(self, setup.name)
		if texture then texture:SetTexture(nil) end
	end
end
function Methods:SetBackdropColor(r, g, b, a)
	self.__state.backdropColor = { r, g, b, a }
	local center = rawget(self, "Center")
	if center then center:SetVertexColor(r, g, b, a) end
end
function Methods:SetBackdropBorderColor(r, g, b, a)
	self.__state.backdropBorderColor = { r, g, b, a }
	for _, key in ipairs(borderPieces) do
		local texture = rawget(self, key)
		if texture then texture:SetVertexColor(r, g, b, a) end
	end
end

function Methods:SetDrawSwipe(drawSwipe) self.__state.drawSwipe = drawSwipe end
function Methods:SetDrawEdge(drawEdge) self.__state.drawEdge = drawEdge end
function Methods:SetDrawBling(drawBling) self.__state.drawBling = drawBling end
function Methods:SetReverse(reverse) self.__state.reverse = reverse end
function Methods:SetCooldown(start, duration) self.__state.cooldown = { start = start, duration = duration } end
function Methods:Pause() self.__state.paused = true end

-- Slider
-- ScrollFrame: the client lays the scroll child out at the frame's top left,
-- moved up by the vertical scroll and left by the horizontal one.
local function PlaceScrollChild(frame)
	local child = frame.__state.scrollChild
	if not child then return end
	child.__state.points = { { "TOPLEFT", frame, "TOPLEFT",
		-(frame.__state.horizontalScroll or 0), frame.__state.verticalScroll or 0 } }
end
function Methods:SetScrollChild(child)
	self.__state.scrollChild = child
	Methods.SetParent(child, self)
	PlaceScrollChild(self)
end
function Methods:GetScrollChild() return self.__state.scrollChild end
function Methods:SetVerticalScroll(offset)
	self.__state.verticalScroll = offset
	PlaceScrollChild(self)
end
function Methods:GetVerticalScroll() return self.__state.verticalScroll or 0 end
function Methods:SetHorizontalScroll(offset)
	self.__state.horizontalScroll = offset
	PlaceScrollChild(self)
end
function Methods:GetHorizontalScroll() return self.__state.horizontalScroll or 0 end

function Methods:GetThumbTexture()
	if not self.__state.thumb then
		self.__state.thumb = NewObject("Texture", self)
	end
	return self.__state.thumb
end

-- DropdownButton (Blizzard menu system): GenerateMenu runs the generator
function Methods:GetScrollPercentage() return self.__state.scrollPercentage or 0 end
function Methods:SetScrollPercentage(value) self.__state.scrollPercentage = math.max(0, math.min(1, value)) end
-- ScrollBox (CallbackRegistryMixin): offsets are set directly, without a view extent.
function Methods:GetDerivedScrollOffset() return self.__state.scrollOffset or 0 end
function Methods:ScrollToOffset(offset)
	self.__state.scrollOffset = offset
	for _, callback in ipairs((self.__state.callbacks or {}).OnScroll or {}) do callback() end
end
function Methods:SetDataProvider(provider)
	self.__state.dataProvider, self.__state.scrollOffset = provider, 0
end
function Methods:RegisterCallback(event, func)
	self.__state.callbacks = self.__state.callbacks or {}
	self.__state.callbacks[event] = self.__state.callbacks[event] or {}
	table.insert(self.__state.callbacks[event], func)
end

-- against a fake root description so menu code gets exercised.
function Methods:SetupMenu(generator)
	self.__state.menuGenerator = generator
	self:GenerateMenu()
end
function Methods:GenerateMenu()
	local generator = self.__state.menuGenerator
	if generator then
		local root = NewObject("MenuDescription")
		generator(self, root)
		self.__state.menu = root
	end
end
local function AddMenuElement(menu, kind, text, fields)
	local element = NewObject("MenuElement")
	element.__state.kind, element.__state.text = kind, text
	for key, value in pairs(fields) do element.__state[key] = value end
	menu.__state.elements = menu.__state.elements or {}
	table.insert(menu.__state.elements, element)
	return element
end
function Methods:CreateRadio(text, isSelected, setSelected, data)
	local element = AddMenuElement(self, "radio", text, { isSelected = isSelected, setSelected = setSelected, data = data })
	isSelected()
	return element
end
function Methods:CreateCheckbox(text, isSelected, setSelected, data)
	local element = AddMenuElement(self, "checkbox", text, { isSelected = isSelected, setSelected = setSelected, data = data })
	isSelected()
	return element
end
function Methods:CreateButton(text, callback, data)
	return AddMenuElement(self, "button", text, { callback = callback, data = data })
end
function Methods:CreateTitle(text)
	return AddMenuElement(self, "title", text, {})
end
function Methods:AddInitializer(initializer)
	self.__state.initializers = self.__state.initializers or {}
	table.insert(self.__state.initializers, initializer)
end

-- Events
function Methods:RegisterEvent(event) self.__state.events[event] = true; Mock.registeredEvents[event] = true end
function Methods:RegisterUnitEvent(event) self.__state.events[event] = true; Mock.registeredEvents[event] = true end
function Methods:UnregisterEvent(event) self.__state.events[event] = nil end
function Methods:UnregisterAllEvents() self.__state.events = {} end
function Methods:IsEventRegistered(event) return self.__state.events[event] == true end

function Mock.FireEvent(event, ...)
	-- IsLoggedIn turns true as PLAYER_LOGIN fires.
	if event == "PLAYER_LOGIN" then Mock.loggedIn = true end
	for _, obj in ipairs(registry) do
		if obj.__state.events[event] and obj.__state.scripts.OnEvent then
			obj.__state.scripts.OnEvent(obj, event, ...)
		end
	end
end

-- AuraContainer (Blizzard_CustomAuraContainer): groups create two buttons up
-- front through their initializeFrame, like the real frame batch does.
-- Blizzard_SharedXML ScrollingEditBoxTemplate (ScrollingEditBoxMixin): a
-- multi-line EditBox in a ScrollBox. Only the mixin methods we use.
function Mock.DecorateScrollingEditBox(frame)
	local scrollBox = NewObject("Frame", frame)
	scrollBox.__state.template = "WowScrollBox"
	local editBox = NewObject("EditBox", scrollBox)
	editBox.__state.multiLine, editBox.__state.fontObject, editBox.__state.text = true, "GameFontHighlight", ""
	frame.ScrollBox, scrollBox.EditBox = scrollBox, editBox
	function frame:GetScrollBox() return scrollBox end
	function frame:GetEditBox() return editBox end
	function frame:SetText(text) editBox:SetText(text) end
	function frame:GetText() return editBox:GetText() end
	function frame:GetInputText() return editBox:GetText() end
	function frame:ClearText() editBox:SetText("") end
	function frame:SetFocus() editBox:SetFocus() end
	function frame:ClearFocus() editBox:ClearFocus() end
end

function Mock.DecorateAuraContainer(container)
	local s = container.__state
	s.groups, s.groupOrder = {}, {}
	local function AddFrames(self, key, filter, options, count)
		local group = { filter = filter, options = options, frames = {}, enabled = true }
		s.groups[key] = group
		table.insert(s.groupOrder, key)
		for i = 1, count do
			local button = NewObject("Button", self)
			button.__state.template = "CustomAuraButtonTemplate"
			button.__state.auraRestricted = true
			button.__state.dispelTextures = {}
			button.__state.auraAssignedAnimations = {}
			function button:AddAuraAssignedAnimation(animation)
				assert(animation:IsObjectType("AnimationGroup"), "expected an AnimationGroup")
				local ancestor = animation:GetParent()
				while ancestor and ancestor ~= self do ancestor = ancestor:GetParent() end
				assert(ancestor == self, "animation must descend from its aura button")
				assert(not self.__state.auraAssignedAnimations[animation], "animation already registered")
				self.__state.auraAssignedAnimations[animation] = true
			end
			function button:RemoveAuraAssignedAnimation(animation)
				self.__state.auraAssignedAnimations[animation] = nil
			end
			function button:SetCancelAuraButtons(tokens)
				assert(tokens == nil or type(tokens) == "string", "cancelAuraButtons must be a string or nil")
				local clicks = {}
				for token in (tokens or ""):gmatch("[^,%s]+") do clicks[#clicks + 1] = token end
				assert(tokens == nil or #clicks > 0, "cancelAuraButtons must contain at least one click token")
				self.__state.cancelAuraButtons = tokens
				self:RegisterForClicks(unpack(clicks))
			end
			function button:MockUpdateDispelTextures(dispelName)
				if dispelName then self.__state.dispelName = dispelName end
				for texture, opts in pairs(self.__state.dispelTextures) do
					local name = self.__state.dispelName or "Magic"
					local color = opts.customDispelColorMap and opts.customDispelColorMap[name]
						or AuraUtil.GetAuraBorderColor(name)
					if opts.customDispelColorCurve then
						local ids = { None = 0, Magic = 1, Curse = 2, Disease = 3, Poison = 4,
							Stealth = 5, Invisibility = 6, All = 7, Enrage = 9, Bleed = 11 }
						color = opts.customDispelColorCurve:Evaluate(ids[name] or 12)
					end
					texture:SetVertexColor(color:GetRGBA())
					-- Auras without a dispel type light only opted-in textures.
					texture:SetShown(name ~= "None" or opts.showWithoutDispelType == true)
				end
			end
			function button:AddDispelTypeTexture(texture, opts)
				assert(not self.__state.dispelTextures[texture], "duplicate dispel texture")
				self.__state.dispelTextures[texture] = opts
				self:MockUpdateDispelTextures()
			end
			function button:RemoveDispelTypeTexture(texture)
				assert(self.__state.dispelTextures[texture], "unregistered dispel texture")
				self.__state.dispelTextures[texture] = nil
			end
			-- The engine fills bound texts right away (here, during AddAuraGroup).
			function button:SetApplicationCount(fs) fs:SetText("") end
			function button:SetDurationText(fs, options)
				self.__state.durationText = { fontString = fs, options = options }
				fs:SetText("")
			end
			group.frames[i] = button
			options.initializeFrame(button)
		end
		return group
	end
	-- Blizzard asserts AuraUtil.IsValidFilterString on every filter string.
	local function AssertFilter(filter)
		local known = API.Snapshot().lua.auraFilters
		for component in filter:gmatch("[^| ]+") do
			assert(known[component:gsub("^!", "")], "Unknown aura filter component: '" .. component .. "'")
		end
	end
	function container:AddAuraGroup(key, filter, options)
		AssertFilter(filter)
		-- Blizzard builds a batch up front (CustomAuraContainerConstants
		-- .FrameCreationBatchSize), whatever the group's maximum.
		AddFrames(self, key, filter, options, 10)
		-- Groups resize the container: Blizzard forbids untrusted layout
		-- scripts on it and on everything depending on its geometry.
		s.layoutAspect = true
	end
	function container:SetAuraGroupEnabled(key, enabled) s.groups[key].enabled = enabled end
	function container:SetAuraGroupFilterString(key, filter) AssertFilter(filter); s.groups[key].filter = filter end
	function container:SetAuraGroupMaxFrameCount(key, max) s.groups[key].max = max end
	function container:SetAuraGroupLayout(key, layout) s.groups[key].layout = layout end
	function container:SetAuraGroupCandidateFilters(key, filters) s.groups[key].candidateFilters = filters end
	function container:SetAuraGroupSortMethod(key, method, direction) s.groups[key].sort = { method, direction } end
	function container:AddAuraSlot(key, filter, options)
		assert(not InCombatLockdown(), "Native aura slots must be prepared outside combat")
		AssertFilter(filter)
		-- A native slot initializes exactly one button, unlike a flowing group.
		local group = AddFrames(self, key, filter, options, 1)
		s.slots = s.slots or {}
		s.slots[key] = group
		return group.frames[1]
	end
	function container:SetAuraSlotFilterString(key, filter) AssertFilter(filter); s.slots[key].filter = filter end
	function container:SetAuraSlotEnabled(key, enabled) s.slots[key].enabled = enabled end
	function container:SetAuraSlotCandidateFilters(key, filters) s.slots[key].candidateFilters = filters end
	function container:GetAuraGroupFrameCount(key) return #s.groups[key].frames end
	function container:GetAuraGroupFrame(key, index) return s.groups[key].frames[index] end
	function container:SetUnit(unit)
		assert(type(unit) == "string", "AuraContainer:SetUnit requires a string")
		s.unit = unit
		s.updates = (s.updates or 0) + 1
	end
	function container:GetUnit() return s.unit end
	function container:UpdateAllAuras() s.updates = (s.updates or 0) + 1 end
	function container:SetEnabled(enabled)
		s.enabled = enabled
		if not enabled then
			for _, group in pairs(s.groups) do
				for _, button in ipairs(group.frames) do
					for animation in pairs(button.__state.auraAssignedAnimations) do animation:Stop() end
				end
			end
		end
	end
	function container:IsEnabled() return s.enabled == true end
	function container:SetFlowLayoutAnchorPoint(point) s.flowAnchor = point end
	function container:SetFlowLayoutAxis(axis) s.flowAxis = axis end
	function container:SetFlowLayoutGrowthDirection(x, y) s.growth = { x, y } end
	function container:SetFlowLayoutMaximumLineSize(size) s.lineSize = size end
end

-- Other API ---------------------------------------------------------------------

-- ColorMixin: methods live on the metatable, so colour globals hold only data.
local ColorMixin = {}
function ColorMixin:GetRGB() return self.r, self.g, self.b end
function ColorMixin:GetRGBA() return self.r, self.g, self.b, self.a end
function ColorMixin:SetRGBA(nr, ng, nb, na) self.r, self.g, self.b, self.a = nr, ng, nb, na or 1 end
function ColorMixin:GenerateHexColor()
	local function Byte(value) return math.floor(value * 255 + 0.5) end
	return string.format("ff%02x%02x%02x", Byte(self.r), Byte(self.g), Byte(self.b))
end
function ColorMixin:GenerateHexColorMarkup() return "|c" .. self:GenerateHexColor() end
function ColorMixin:WrapTextInColorCode(text) return self:GenerateHexColorMarkup() .. text .. "|r" end
local ColorMT = { __index = ColorMixin }

local function NewColor(r, g, b, a)
	return setmetatable({ r = r, g = g, b = b, a = a or 1 }, ColorMT)
end

-- C_UIColor.GetColors: { baseTag, red, green, blue } in bytes, the values
-- behind the client's long-standing *_FONT_COLOR_CODE strings.
Mock.UI_COLORS = {
	{ "NORMAL_FONT_COLOR", 255, 210, 0 },
	{ "HIGHLIGHT_FONT_COLOR", 255, 255, 255 },
	{ "RED_FONT_COLOR", 255, 32, 32 },
	{ "GREEN_FONT_COLOR", 32, 255, 32 },
	{ "GRAY_FONT_COLOR", 128, 128, 128 },
	{ "DISABLED_FONT_COLOR", 128, 128, 128 },
	{ "YELLOW_FONT_COLOR", 255, 255, 0 },
	{ "LIGHTYELLOW_FONT_COLOR", 255, 255, 154 },
	{ "ORANGE_FONT_COLOR", 255, 127, 63 },
	{ "WHITE_FONT_COLOR", 255, 255, 255 },
	{ "TOOLTIP_DEFAULT_COLOR", 255, 255, 255 },
	{ "TOOLTIP_DEFAULT_BACKGROUND_COLOR", 23, 23, 48 },
}

-- Global aliases of the Lua libraries: Blizzard_SharedXMLBase/Compat.lua's
-- and the engine's own (API.ENGINE_LUA).
local LUA_ALIASES = {
	abs = math.abs, ceil = math.ceil, floor = math.floor, max = math.max, min = math.min, mod = math.fmod,
	sqrt = math.sqrt, random = math.random,
	format = string.format, gmatch = string.gmatch, gsub = string.gsub, strbyte = string.byte,
	strchar = string.char, strfind = string.find, strlen = string.len, strlower = string.lower,
	strmatch = string.match, strrep = string.rep, strrev = string.reverse, strsub = string.sub,
	strupper = string.upper,
	sort = table.sort, tinsert = table.insert, tremove = table.remove,
}

-- strsplit(delimiters, text[, pieces]): every character of `delimiters`
-- splits; at most `pieces` results, the last keeping the rest of the text.
local function StrSplit(delimiters, text, pieces)
	local separator = "[" .. delimiters:gsub("[%]%^%-%%]", "%%%0") .. "]"
	local parts, start = {}, 1
	while not pieces or #parts < pieces - 1 do
		local first, last = text:find(separator, start)
		if not first then break end
		parts[#parts + 1] = text:sub(start, first - 1)
		start = last + 1
	end
	parts[#parts + 1] = text:sub(start)
	return unpack(parts, 1, #parts)
end

local function ToStringAll(...)
	local strings = {}
	for i = 1, select("#", ...) do strings[i] = tostring((select(i, ...))) end
	return unpack(strings, 1, select("#", ...))
end

-- hooksecurefunc([owner,] name, hook): `hook` runs after the original with
-- the same arguments; callers still get the original's results.
local function HookSecureFunc(owner, name, hook)
	if type(owner) == "string" then owner, name, hook = _G, owner, name end
	local original = owner[name]
	assert(type(original) == "function", "hooksecurefunc: " .. tostring(name) .. " is not a function")
	local function Pack(...) return { n = select("#", ...), ... } end
	owner[name] = function(...)
		local results = Pack(original(...))
		hook(...)
		return unpack(results, 1, results.n)
	end
end

local function NewCurve(isColor)
	local curve = { points = {}, isColor = isColor, curveType = 0 }
	function curve:SetType(curveType) self.curveType = curveType end
	function curve:GetType() return self.curveType end
	function curve:AddPoint(x, y)
		self.points[#self.points + 1] = { x, y }
		table.sort(self.points, function(a, b) return a[1] < b[1] end)
	end
	function curve:Evaluate(x)
		if Mock.IsSecret(x) then
			if self.isColor then
				return NewColor(Mock.Secret("r"), Mock.Secret("g"), Mock.Secret("b"), Mock.Secret("a"))
			end
			return Mock.Secret("curve")
		end
		local points = self.points
		if x <= points[1][1] then
			return points[1][2]
		end
		for i = 2, #points do
			local p0, p1 = points[i - 1], points[i]
			if x <= p1[1] then
				if self.curveType == Enum.LuaCurveType.Step then
					return x == p1[1] and p1[2] or p0[2]
				end
				local t = (x - p0[1]) / (p1[1] - p0[1])
				local a, b = p0[2], p1[2]
				if type(a) == "table" then
					return NewColor(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
				end
				return a + (b - a) * t
			end
		end
		return points[#points][2]
	end
	return curve
end

-- The client's string.format accepts secrets (result is a secret string).
local format = string.format
string.format = function(fmt, ...)
	for i = 1, select("#", ...) do
		if Mock.IsSecret((select(i, ...))) then
			return Mock.Secret(fmt)
		end
	end
	return format(fmt, ...)
end

-- The client's presized table constructor (LuaTableExtensions).
local hasTableNew, newTable = pcall(require, "table.new")
if not hasTableNew then newTable = function() return {} end end
table.create = function(arraySizeHint, nodeSizeHint)
	return newTable(arraySizeHint, nodeSizeHint or 0)
end

--[[
C_EncodingUtil stand-in. Round trips are faithful; the byte formats are not:
"CBOR" is a private tagged encoding, "compression" a marker prefix, base64 is
real (RFC 4648). Like the client, decoders return nothing for input they
can't read, and DeserializeCBOR raises on malformed data.
]]
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, 64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

local function EncodeBase64(source)
	local out = {}
	for i = 1, #source, 3 do
		local a, b, c = source:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local chars = {}
		for j = 1, 4 do
			local index = math.floor(n / 64 ^ (4 - j)) % 64
			chars[j] = B64:sub(index + 1, index + 1)
		end
		if not b then chars[3] = "=" end
		if not c then chars[4] = "=" end
		out[#out + 1] = table.concat(chars)
	end
	return table.concat(out)
end

local function DecodeBase64(source)
	if #source % 4 ~= 0 or source:find("[^%w%+/=]") or source:find("=[^=]") then return nil end
	local out = {}
	for i = 1, #source, 4 do
		local n, pad = 0, 0
		for j = i, i + 3 do
			local char = source:sub(j, j)
			if char == "=" then pad = pad + 1 end
			n = n * 64 + (B64_INDEX[char] or 0)
		end
		local bytes = string.char(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
		out[#out + 1] = bytes:sub(1, 3 - pad)
	end
	return table.concat(out)
end

local function Serialize(value, out, ignoreErrors)
	local kind = type(value)
	if kind == "nil" then out[#out + 1] = "z"
	elseif kind == "boolean" then out[#out + 1] = value and "T" or "F"
	elseif kind == "number" then out[#out + 1] = "n" .. string.format("%.17g", value) .. ";"
	elseif kind == "string" then out[#out + 1] = "s" .. #value .. ":" .. value
	elseif kind == "table" then
		out[#out + 1] = "{"
		for k, v in pairs(value) do
			Serialize(k, out, ignoreErrors)
			Serialize(v, out, ignoreErrors)
		end
		out[#out + 1] = "}"
	elseif ignoreErrors then out[#out + 1] = "z"
	else error("SerializeCBOR: unsupported value type " .. kind, 3) end
end

local function Deserialize(source, pos)
	local tag = source:sub(pos, pos)
	if tag == "z" then return nil, pos + 1
	elseif tag == "T" then return true, pos + 1
	elseif tag == "F" then return false, pos + 1
	elseif tag == "n" then
		local text, after = source:match("^([^;]+);()", pos + 1)
		local number = text and tonumber(text)
		if not number then error("DeserializeCBOR: malformed number", 0) end
		return number, after
	elseif tag == "s" then
		local length, start = source:match("^(%d+):()", pos + 1)
		if not length or start + length - 1 > #source then error("DeserializeCBOR: malformed string", 0) end
		return source:sub(start, start + length - 1), start + length
	elseif tag == "{" then
		local result = {}
		pos = pos + 1
		while source:sub(pos, pos) ~= "}" do
			if pos > #source then error("DeserializeCBOR: unterminated map", 0) end
			local key, value
			key, pos = Deserialize(source, pos)
			value, pos = Deserialize(source, pos)
			if key == nil then error("DeserializeCBOR: nil map key", 0) end
			result[key] = value
		end
		return result, pos + 1
	end
	error("DeserializeCBOR: malformed data", 0)
end

local COMPRESSED = "\31mockdeflate\31"

function Mock.NewEncodingUtil()
	return {
		SerializeCBOR = function(value, options)
			local out = {}
			Serialize(value, out, options and options.ignoreSerializationErrors)
			return table.concat(out)
		end,
		DeserializeCBOR = function(source)
			local value, pos = Deserialize(source, 1)
			if pos <= #source then error("DeserializeCBOR: trailing data", 0) end
			return value
		end,
		CompressString = function(source) return COMPRESSED .. source end,
		DecompressString = function(source)
			if source:sub(1, #COMPRESSED) ~= COMPRESSED then return end
			return source:sub(#COMPRESSED + 1)
		end,
		EncodeBase64 = function(source) return EncodeBase64(source) end,
		DecodeBase64 = function(source)
			local decoded = DecodeBase64(source)
			if decoded then return decoded end
		end,
	}
end

local extensions = {}

-- Registers (or replaces, by name) a host's extra mock pieces.
function Mock.Extend(name, extension)
	assert(type(name) == "string" and type(extension) == "table", "Mock.Extend(name, extension)")
	extension.name = name
	for index, existing in ipairs(extensions) do
		if existing.name == name then
			extensions[index] = extension
			return
		end
	end
	extensions[#extensions + 1] = extension
end

function Mock.ClearExtensions()
	extensions = {}
end

local function RunExtensions(step)
	for _, extension in ipairs(extensions) do
		if extension[step] then extension[step](Mock) end
	end
end

-- Runs the pending C_Timer.After callbacks, in the order they were scheduled.
function Mock.RunTimers()
	local timers = Mock.timers
	Mock.timers = {}
	for _, timer in ipairs(timers) do timer.callback() end
end

Mock.templates = {}

-- Builds the inherited templates of a comma-separated `template` list that
-- Mock.templates knows into `frame`, in order; true when there was one.
function Mock.ApplyTemplates(frame, template)
	local applied = false
	for part in (template or ""):gmatch("[^,%s]+") do
		local build = Mock.templates[part]
		if build then
			build(frame)
			applied = true
		end
	end
	return applied
end

-- CreateFrame without running OnLoad: also returns whether a template from
-- Mock.templates was built in (CreateFrame then runs OnLoad, like the client).
function Mock.NewFrame(frameType, name, parent, template)
	local obj = NewObject(frameType or "Frame", parent, name)
	obj.__state.template = template
	if template and template:find("Secure", 1, true) then obj.__state.protected = true end
	if template and template:find(LAYOUT_ASPECT_TEMPLATE, 1, true) then obj.__state.layoutAspect = true end
	if template and template:find("BackdropTemplate", 1, true) then obj.__state.backdropSizeScript = true end
	if parent and parent == rawget(_G, "Minimap") then rawset(obj, "__strict", true) end
	if frameType == "AuraContainer" then
		assert(not InCombatLockdown(), "Native aura containers cannot be created in combat")
		Mock.DecorateAuraContainer(obj)
	elseif template == "ScrollingEditBoxTemplate" then
		Mock.DecorateScrollingEditBox(obj)
	end
	return obj, Mock.ApplyTemplates(obj, template)
end

-- The client's bit library: LuaJIT has one, plain Lua 5.1 gets this stand-in.
local function Bitwise(keep)
	return function(a, b)
		local result, place = 0, 1
		a, b = a % 2 ^ 32, b % 2 ^ 32
		for _ = 1, 32 do
			if keep(a % 2, b % 2) then result = result + place end
			a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
		end
		return result
	end
end
Mock.BIT = {
	band = Bitwise(function(x, y) return x == 1 and y == 1 end),
	bor = Bitwise(function(x, y) return x == 1 or y == 1 end),
	bxor = Bitwise(function(x, y) return x ~= y end),
	bnot = function(a) return 2 ^ 32 - 1 - a % 2 ^ 32 end,
	lshift = function(a, n) return (a * 2 ^ n) % 2 ^ 32 end,
	rshift = function(a, n) return math.floor((a % 2 ^ 32) / 2 ^ n) end,
}

-- GlobalStrings.lua entries addons and their libraries read.
Mock.GLOBAL_STRINGS = {
	ACCEPT = "Accept", ALL = "All", BACKGROUND = "Background", CANCEL = "Cancel", CLOSE = "Close", COLOR = "Color",
	COMMAND = "Command", CUSTOM = "Custom", FACTION = "Faction", HELP_LABEL = "Help", HIDE = "Hide", HIGH = "High",
	HUD_EDIT_MODE_MENU = "Edit Mode", IGNORE = "Ignore", LABEL_NOTE = "Note", LOW = "Low", MUTE = "Mute",
	MUTED = "Muted", NO = "No", NONE = "None", OKAY = "Okay", PVP = "PvP", RESET_POSITION = "Reset Position",
	SHORT = "Short", SHOW = "Show", UKNOWNBEING = "Unknown Being", USE = "Use", YES = "Yes",
}

-- C_CreatureInfo.GetClassInfo by classID, with the client's class colour as
-- RRGGBB (C_ClassColor's DB values behind RAID_CLASS_COLORS).
local CLASSES = {
	[1] = { "Warrior", "WARRIOR", "c69b6d" }, [2] = { "Paladin", "PALADIN", "f48cba" },
	[3] = { "Hunter", "HUNTER", "aad372" }, [4] = { "Rogue", "ROGUE", "fff468" },
	[5] = { "Priest", "PRIEST", "ffffff" }, [7] = { "Shaman", "SHAMAN", "0070dd" },
	[8] = { "Mage", "MAGE", "3fc7eb" }, [9] = { "Warlock", "WARLOCK", "8788ee" },
	[11] = { "Druid", "DRUID", "ff7c0a" },
}

local function HexColor(hex)
	local function Channel(index) return tonumber(hex:sub(index, index + 1), 16) / 255 end
	return NewColor(Channel(1), Channel(3), Channel(5))
end

-- Client globals nearly every addon (and Titan Panel) reads: the logged-in
-- player, money and zone, screen size, chat, popups, the classic dropdown
-- menu and the menu manager. Mock.player* fields drive the player answers.
local function InstallClientGlobals()
	local noop = function() end
	_G.bit = rawget(_G, "bit") or Mock.BIT
	for name, text in pairs(Mock.GLOBAL_STRINGS) do _G[name] = text end
	_G.date, _G.time = os.date, os.time
	_G.issecurevariable = function() return false end

	Mock.loggedIn = false
	_G.IsLoggedIn = function() return Mock.loggedIn end
	Mock.playerGuid = "Player-1-00000001"
	Mock.guids = { player = Mock.playerGuid }
	_G.UnitGUID = function(unit) return Mock.guids[unit] end
	_G.GetPlayerInfoByGUID = function(guid)
		if guid ~= Mock.playerGuid then return nil end
		local className, classFile = UnitClass("player")
		local race, raceFile = UnitRace("player")
		return className, classFile, race, raceFile, 2, (UnitName("player")), GetRealmName()
	end
	_G.UnitClassBase = function(unit)
		local _, classFile, classID = UnitClass(unit)
		return classFile, classID
	end
	_G.C_CreatureInfo = {
		GetClassInfo = function(classID)
			local class = CLASSES[classID]
			if class then return { className = class[1], classFile = class[2], classID = classID } end
		end,
	}
	-- Blizzard_SharedXML/ClassColors.lua and Blizzard_FrameXMLBase/Constants.lua.
	_G.RAID_CLASS_COLORS, _G.LOCALIZED_CLASS_NAMES_MALE, _G.LOCALIZED_CLASS_NAMES_FEMALE = {}, {}, {}
	for _, class in pairs(CLASSES) do
		local color = HexColor(class[3])
		color.colorStr = color:GenerateHexColor()
		RAID_CLASS_COLORS[class[2]] = color
		LOCALIZED_CLASS_NAMES_MALE[class[2]] = class[1]
		LOCALIZED_CLASS_NAMES_FEMALE[class[2]] = class[1]
	end
	Mock.level, Mock.money, Mock.zone, Mock.subZone = 60, 0, "Stormwind City", ""
	_G.UnitLevel = function() return Mock.level end
	-- Mock.xp / Mock.xpMax, Mock.resting and Mock.inPetBattle drive the
	-- experience and pet battle answers (Titan's XP and bar setup reads them).
	Mock.xp, Mock.xpMax, Mock.resting, Mock.inPetBattle = 1200, 5000, false, false
	_G.UnitXP = function() return Mock.xp end
	_G.UnitXPMax = function() return Mock.xpMax end
	_G.IsResting = function() return Mock.resting end
	_G.GetXPExhaustion = function() return nil end
	_G.C_PetBattles = { IsInBattle = function() return Mock.inPetBattle end }
	_G.GetMoney = function() return Mock.money end
	_G.GetZoneText = function() return Mock.zone end
	_G.GetSubZoneText = function() return Mock.subZone end
	_G.GetBindLocation = function() return Mock.zone end
	_G.GetAverageItemLevel = function() return 0, 0, 0 end
	_G.RequestTimePlayed = noop
	_G.GetScreenWidth = function() return UIParent.__state.width > 0 and UIParent.__state.width or Mock.SCREEN.width end
	_G.GetScreenHeight = function() return UIParent.__state.height > 0 and UIParent.__state.height or Mock.SCREEN.height end

	_G.StaticPopupDialogs = {}
	_G.ChatFrame1 = NewObject("ScrollingMessageFrame", UIParent, "ChatFrame1")
	_G.DEFAULT_CHAT_FRAME = ChatFrame1
	-- InsertLink fills the focused macro or chat edit box, and none has focus.
	-- Blizzard_DeprecatedChatInfo aliases it as ChatEdit_InsertLink, which
	-- AceGUI's edit boxes hooksecurefunc.
	_G.ChatFrameUtil = { DisplayTimePlayed = noop, InsertLink = function() return false end }
	_G.ChatEdit_InsertLink = ChatFrameUtil.InsertLink
	_G.GameTooltip = NewObject("GameTooltip", UIParent, "GameTooltip")
	-- Blizzard_UIDropDownMenu: the classic dropdown, never open.
	_G.UIDROPDOWNMENU_MAXLEVELS = 3
	_G.UIDROPDOWNMENU_SHOW_TIME = 2
	_G.DropDownList1 = NewObject("Button", UIParent, "DropDownList1")
	DropDownList1.__state.shown = false
	for _, name in ipairs({ "UIDropDownMenu_CreateFrames", "UIDropDownMenu_OnUpdate", "UIDropDownMenu_Initialize",
		"UIDropDownMenu_AddButton", "UIDropDownMenu_AddSeparator", "UIDropDownMenu_AddSpace",
		"ToggleDropDownMenu", "CloseDropDownMenus" }) do
		_G[name] = noop
	end
	-- Blizzard_Menu: no menu is ever open.
	local manager = { IsAnyMenuOpen = function() return false end, CloseMenus = noop }
	_G.Menu = { GetManager = function() return manager end }
end

function Mock.Install()
	-- Client chat belongs to the mock, not the test runner's stdout.
	Mock.messages = {}
	_G.print = function(...)
		Mock.messages[#Mock.messages + 1] = { ... }
	end
	_G.C_ClassColor = nil
	registry = {}
	Mock.objects = registry
	Mock.time = 100
	Mock.raidTargets = {}
	Mock.dead, Mock.ghosts = {}, {}
	Mock.attackable, Mock.difficulties = {}, {}
	Mock.incomingResurrections = {}
	Mock.pvpInfo = {}
	Mock.ranges = {}
	Mock.spellRanges = {}
	Mock.registeredEvents = {}
	-- C_Timer.After callbacks wait until a spec runs them (Mock.RunTimers).
	Mock.timers = {}
	_G.C_Timer = { After = function(seconds, callback)
		assert(type(seconds) == "number" and type(callback) == "function", "C_Timer.After(seconds, callback)")
		Mock.timers[#Mock.timers + 1] = { seconds = seconds, callback = callback }
	end }
	_G.UnitAttackSpeed = function() return Secret(2.6), Secret(1.8), Secret(2.8) end
	-- No cast in progress; InstallUI casts a sample spell.
	_G.UnitCastingInfo = function() return nil end
	_G.UnitChannelInfo = function() return nil end
	Mock.aurasSecret = false

	_G.LibStub = nil
	-- Frame templates by name (XML virtual frames, or a host's Lua builders):
	-- function(frame) building the template's content into `frame`.
	Mock.templates = {}
	for _, extension in ipairs(extensions) do
		for _, name in ipairs(extension.globals or {}) do _G[name] = nil end
	end

	_G.Secret = Mock.Secret
	_G.issecretvalue = Mock.IsSecret

	_G.CreateFrame = function(frameType, name, parent, template)
		local obj, templated = Mock.NewFrame(frameType, name, parent, template)
		if templated then Methods.RunScript(obj, "OnLoad") end
		return obj
	end
	_G.CreateFont = function(name)
		return NewObject("Font", nil, name)
	end
	-- Blizzard_Fonts_Shared/Shared/Fonts.xml: the default GameFont set (roman).
	for _, font in ipairs({
		{ "GameFontNormal", 12, 1, 0.82, 0 }, { "GameFontNormalSmall", 10, 1, 0.82, 0 },
		{ "GameFontNormalLarge", 16, 1, 0.82, 0 }, { "GameFontHighlight", 12, 1, 1, 1 },
		{ "GameFontHighlightSmall", 10, 1, 1, 1 }, { "GameFontHighlightLarge", 16, 1, 1, 1 },
		{ "GameFontDisable", 12, 0.5, 0.5, 0.5 }, { "GameFontDisableSmall", 10, 0.5, 0.5, 0.5 },
		{ "GameTooltipText", 12, 1, 1, 1 }, { "GameTooltipTextSmall", 10, 1, 1, 1 },
		{ "GameTooltipHeaderText", 14, 1, 1, 1 },
	}) do
		local object = CreateFont(font[1])
		object:SetFont([[Fonts\FRIZQT__.TTF]], font[2], "")
		object:SetTextColor(font[3], font[4], font[5])
	end
	-- Blizzard_SharedXMLBase/Color.lua: every DB colour becomes <baseTag> and
	-- <baseTag>_CODE.
	_G.C_UIColor = {
		GetColors = function()
			local colors = {}
			for i, entry in ipairs(Mock.UI_COLORS) do
				colors[i] = { baseTag = entry[1], color = { r = entry[2] / 255, g = entry[3] / 255, b = entry[4] / 255, a = 1 } }
			end
			return colors
		end,
	}
	for _, dbColor in ipairs(C_UIColor.GetColors()) do
		local color = NewColor(dbColor.color.r, dbColor.color.g, dbColor.color.b, dbColor.color.a)
		_G[dbColor.baseTag] = color
		_G[dbColor.baseTag .. "_CODE"] = color:GenerateHexColorMarkup()
	end
	_G.FONT_COLOR_CODE_CLOSE = "|r"
	_G.WorldFrame = NewObject("Frame", nil, "WorldFrame")
	_G.UIParent = NewObject("Frame", nil, "UIParent")
	_G.Minimap = NewObject("Frame", UIParent, "Minimap")
	Minimap:SetSize(140, 140)
	Mock.contextMenu = nil
	_G.MenuUtil = {
		CreateContextMenu = function(owner, generator)
			local menu = NewObject("MenuDescription")
			generator(owner, menu)
			Mock.contextMenu = { owner = owner, menu = menu }
			return menu
		end,
	}
	_G.UISpecialFrames = {}
	_G.SlashCmdList = {}
	_G.CreateColor = NewColor
	_G.GetTime = function() return Mock.time end
	_G.GetServerTime = function() return 1700000000 + math.floor(Mock.time) end
	_G.GetLocale = function() return "enUS" end
	_G.GetRealmName = function() return "TestRealm" end
	_G.GetCurrentRegion = function() return 3 end
	_G.GetCurrentRegionName = function() return "EU" end
	_G.UnitName = function() return "Tester", "TestRealm" end
	_G.UnitNameUnmodified = _G.UnitName
	_G.UnitClass = function() return "Warrior", "WARRIOR", 1 end
	_G.UnitRace = function() return "Human", "Human" end
	_G.UnitFactionGroup = function() return "Alliance", "Alliance" end
	_G.UnitEffectiveLevel = function() return 30 end
	_G.UnitQuestTrivialLevelRange = function() return 8 end
	-- Blizzard_FrameXMLBase/Constants.lua and Mainline/DifficultyUtil.lua.
	_G.QuestDifficultyColors = {
		impossible = { r = 1.00, g = 0.10, b = 0.10 },
		verydifficult = { r = 1.00, g = 0.50, b = 0.25 },
		difficult = { r = 1.00, g = 0.82, b = 0.00 },
		standard = { r = 0.25, g = 0.75, b = 0.25 },
		trivial = { r = 0.50, g = 0.50, b = 0.50 },
	}
	local DIFFICULTY_KEYS = { [0] = "trivial", "standard", "difficult", "verydifficult", "impossible" }
	_G.GetDifficultyColor = function(difficulty)
		return QuestDifficultyColors[DIFFICULTY_KEYS[difficulty] or "difficult"]
	end
	_G.GetCreatureDifficultyColor = function(level)
		local levelDiff = level - UnitEffectiveLevel("player")
		if levelDiff >= 5 then return QuestDifficultyColors.impossible end
		if levelDiff >= 3 then return QuestDifficultyColors.verydifficult end
		if levelDiff >= -4 then return QuestDifficultyColors.difficult end
		if -levelDiff <= UnitQuestTrivialLevelRange("player") then return QuestDifficultyColors.standard end
		return QuestDifficultyColors.trivial
	end
	_G.UnitInRange = function(unit)
		local range = Mock.ranges[unit] or { inRange = false, checked = false }
		return range.inRange, range.checked
	end
	_G.C_Spell = {
		IsSpellInRange = function(spell, unit)
			local ranges = Mock.spellRanges[spell]
			if ranges then return ranges[unit] end
		end,
		GetSpellInfo = function(spell)
			local id = tonumber(spell) or (spell == "Flash Heal" and 2061 or nil)
			if id then return { spellID = id, name = id == 2061 and "Flash Heal" or "Spell " .. id, iconID = 135000 + id } end
		end,
		GetOverrideSpell = function(id) return Mock.spellOverrides[id] or id end,
		-- Mock.cooldowns[spellID] = { duration = seconds, onGCD = bool } marks
		-- an active cooldown; timings are secret, isActive/isOnGCD never are.
		GetSpellCooldown = function(id)
			local cooldown = Mock.cooldowns[id]
			return { startTime = Secret(cooldown and Mock.time or 0), duration = Secret(cooldown and cooldown.duration or 0),
				isEnabled = true, isActive = cooldown ~= nil, isOnGCD = cooldown ~= nil and cooldown.onGCD, modRate = Secret(1) }
		end,
		GetSpellCooldownDuration = function(id)
			local duration = C_DurationUtil.CreateDuration()
			local cooldown = Mock.cooldowns[id]
			duration:SetTimeFromStart(Mock.time, cooldown and cooldown.duration or 0)
			return duration
		end,
		GetSpellQueueWindow = function() return Mock.spellQueueWindow end,
		-- Mock.spells[spellID] = { name = ..., description = ... }; nothing if unknown.
		GetSpellName = function(id)
			local spell = Mock.spells[id]
			if spell then return spell.name end
		end,
		GetSpellDescription = function(id)
			local spell = Mock.spells[id]
			if spell then return spell.description end
		end,
	}
	Mock.spells = {}
	-- Blizzard_UnitFrame (always loaded): a sprite sheet cell of the raid icon sheet.
	_G.SetRaidTargetIconTexture = function(texture, index)
		texture.__state.raidTargetIndex = index
		local cell = (Mock.IsSecret(index) and index.secretValue or index) - 1
		local column, row = cell % 4, math.floor(cell / 4)
		texture.__state.texCoords = { column / 4, (column + 1) / 4, row / 4, (row + 1) / 4 }
	end
	Mock.spellOverrides, Mock.unknownSpells, Mock.cooldowns, Mock.spellQueueWindow = {}, {}, {}, 400
	-- Mock.latency = { home, world } in milliseconds.
	Mock.latency = { 40, 80 }
	_G.GetNetStats = function() return 0, 0, Mock.latency[1], Mock.latency[2] end
	_G.C_SpellBook = { IsSpellKnown = function(id) return not Mock.unknownSpells[id] end }
	-- Mock.bigDefensives[spellID]: the client's buff classification; Forever ships none.
	Mock.bigDefensives = { [642] = true }
	_G.C_UnitAuras = { AuraIsBigDefensive = function(id) return Mock.bigDefensives[id] == true end }
	Mock.damageMeter, Mock.damageMeterSecret = {}, false
	_G.C_DamageMeter = {
		GetCombatSessionSourceFromType = function()
			local restricted = Mock.inCombat or Mock.damageMeterSecret
			local spells = {}
			for spellID, total in pairs(Mock.damageMeter) do
				spells[#spells + 1] = { spellID = spellID, totalAmount = restricted and Secret(total) or total }
			end
			return { combatSpells = spells, maxAmount = 0, totalAmount = 0 }
		end,
	}
	-- Mock.cursorInfo holds GetCursorInfo's returns, e.g. { "spell", slot, bank, spellID }.
	Mock.cursorInfo, Mock.spellBookOpened = nil, 0
	_G.GetCursorInfo = function() if Mock.cursorInfo then return unpack(Mock.cursorInfo) end end
	_G.ClearCursor = function() Mock.cursorInfo = nil end
	_G.PlayerSpellsUtil = { OpenToSpellBookTab = function()
		assert(not InCombatLockdown(), "The spellbook opener is disabled in combat")
		Mock.spellBookOpened = Mock.spellBookOpened + 1
	end }
	-- Mock.macros: { account = { { name, icon, body }, ... }, character = { ... } }.
	-- Character macros start after MAX_ACCOUNT_MACROS, as in the client.
	Mock.macros, Mock.macroFrameOpened = { account = {}, character = {} }, 0
	_G.Constants = { MacroConsts = { MAX_ACCOUNT_MACROS = 120, MAX_CHARACTER_MACROS = 30 } }
	_G.GetNumMacros = function() return #Mock.macros.account, #Mock.macros.character end
	_G.GetMacroInfo = function(index)
		local macro = index > 120 and Mock.macros.character[index - 120] or Mock.macros.account[index]
		if macro then return macro[1], macro[2], macro[3] end
	end
	_G.ShowMacroFrame = function()
		assert(not InCombatLockdown(), "The macro window opener is disabled in combat")
		Mock.macroFrameOpened = Mock.macroFrameOpened + 1
	end
	Mock.specIndex = 1
	_G.C_SpecializationInfo = { GetSpecialization = function() return Mock.specIndex end }
	_G.IsInRaid = function() return Mock.inRaid == true end
	_G.IsInGroup = function() return Mock.inParty == true or Mock.inRaid == true end
	_G.GetNumGroupMembers = function() return Mock.groupSize or 0 end
	-- Members fill subgroups in order unless Mock.raidSubgroups[index] moves them.
	_G.GetRaidRosterInfo = function(index)
		if not Mock.inRaid or index > Mock.groupSize then return nil end
		return "Raider" .. index, 0, Mock.raidSubgroups[index] or math.ceil(index / 5)
	end
	Mock.inRaid, Mock.inParty, Mock.groupSize, Mock.raidSubgroups = false, false, 0, {}
	_G.Clique, _G.ClickCastFrames = nil, nil
	_G.RegisterAttributeDriver = function(frame, name, condition)
		assert(not InCombatLockdown(), "Attribute drivers must be configured outside combat")
		frame.__state.drivers = frame.__state.drivers or {}
		frame.__state.drivers[name] = condition
		if name == "state-visibility" then frame:SetShown(condition ~= "hide") end
	end
	_G.UnregisterAttributeDriver = function(frame, name)
		assert(not InCombatLockdown(), "Attribute drivers must be removed outside combat")
		if frame.__state.drivers then frame.__state.drivers[name] = nil end
	end
	_G.RegisterStateDriver = _G.RegisterAttributeDriver
	_G.SecureHandlerSetFrameRef = function(frame, label, reference)
		assert(not InCombatLockdown(), "Secure frame references cannot change in combat")
		assert(not Mock.HasLayoutAspect(frame) and not Mock.HasLayoutAspect(reference), "Secure frame references cannot use forbidden frames")
		frame.__state.frameRefs = frame.__state.frameRefs or {}
		frame.__state.frameRefs[label] = reference
	end
	Mock.RunRestrictedSnippet = function(header, body, frame, ...)
		local handles, frames = {}, {}
		local function Handle(object)
			if not object then return nil end
			if handles[object] then return handles[object] end
			local handle = setmetatable({}, { __index = function(_, key)
				if key == "GetFrameRef" then return function(_, label) return Handle(Methods.GetFrameRef(object, label)) end end
				if key == "RunAttribute" then
					return function(_, name, ...)
						return Mock.RunRestrictedSnippet(object, object:GetAttribute(name), object, ...)
					end
				end
				return function(_, ...)
					local args = { ... }
					for index = 1, select("#", ...) do args[index] = frames[args[index]] or args[index] end
					return object[key](object, unpack(args, 1, select("#", ...)))
				end
			end })
			handles[object], frames[handle] = handle, object
			return handle
		end
		local chunk = assert(loadstring(body))
		setfenv(chunk, setmetatable({ self = Handle(frame), control = Handle(header) }, { __index = _G }))
		return Mock.RunUntainted(chunk, ...)
	end
	_G.SecureHandlerWrapScript = function(frame, script, header, body)
		assert(not InCombatLockdown(), "Secure wrappers cannot change in combat")
		assert(not Mock.HasLayoutAspect(frame) and not Mock.HasLayoutAspect(header), "Secure wrappers cannot use forbidden frames")
		assert(header:IsProtected(), "Secure wrapper headers must be protected")
		frame.__state.secureWrappers = frame.__state.secureWrappers or {}
		frame.__state.secureWrappers[script] = { header = header, body = body }
	end
	_G.SecureHandlerExecute = function(header, body)
		assert(not InCombatLockdown(), "Secure snippets cannot execute from addon code in combat")
		return Mock.RunRestrictedSnippet(header, body, header)
	end
	_G.RegisterUnitWatch = function(frame)
		frame.__state.unitWatched = true
	end
	_G.UnregisterUnitWatch = function(frame)
		frame.__state.unitWatched = false
	end
	_G.UnitWatchRegistered = function(frame) return frame.__state.unitWatched == true end
	-- Native SecureStateDriverManager resolves visibility first, then unit
	-- watches. A live watch can therefore override a constant hide driver.
	Mock.TickUnitVisibility = function(frame)
		local drivers = frame.__state.drivers or {}
		if drivers["state-visibility"] == "hide" then frame:Hide(); frame:SetAttribute("statehidden", true) end
		if UnitWatchRegistered(frame) then
			local exists = frame.__unit and (UnitExists(frame.__unit) or UnitIsVisible(frame.__unit))
			frame:SetShown(exists and true or false)
			frame:SetAttribute("statehidden", not exists and true or nil)
		end
	end
	_G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
	_G.strlenutf8 = function(s) return #s end
	_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	-- The client's table library has it too.
	table.wipe = _G.wipe
	for name, fn in pairs(LUA_ALIASES) do _G[name] = fn end
	_G.strsplit = StrSplit
	_G.strjoin = function(delimiter, ...) return table.concat({ ... }, delimiter) end
	_G.strconcat = function(...) return table.concat({ ... }) end
	_G.tostringall = ToStringAll
	_G.hooksecurefunc = HookSecureFunc
	_G.securecall = function(fn, ...)
		if type(fn) == "string" then fn = _G[fn] end
		return fn(...)
	end
	_G.securecallfunction = function(fn, ...) return fn(...) end
	_G.issecure = function() return untainted > 0 end
	-- Sounds played, in order: { soundKitID, channel }.
	Mock.sounds = {}
	_G.PlaySound = function(soundKitID, channel)
		Mock.sounds[#Mock.sounds + 1] = { soundKitID, channel }
		return true, #Mock.sounds
	end
	Mock.cursor = { x = 0, y = 0 }
	_G.GetCursorPosition = function() return Mock.cursor.x, Mock.cursor.y end
	_G.geterrorhandler = function() return error end
	_G.INTERRUPTED = "Interrupted"
	_G.UnitFrame_OnEnter = function() end
	_G.UnitFrame_OnLeave = function() end
	_G.InCombatLockdown = function() return Mock.inCombat == true end
	Mock.inCombat = false
	_G.FAILED = "Failed"

	_G.AnchorUtil = {
		FlowLayoutAxis = { Horizontal = 0, Vertical = 1 },
		FlowDirection = { Left = -1, Right = 1, Up = 1, Down = -1 },
		CreateFlowLayout = function()
			local flow = {}
			function flow:SetLayoutAxis(axis) self.axis = axis end
			function flow:SetAnchorPoint(anchor) self.anchor = anchor end
			function flow:SetGrowthDirection(x, y) self.x, self.y = x, y end
			function flow:SetMaximumLineSize(size) self.lineSize = size end
			-- Blizzard_SharedXMLBase AnchorUtil.ApplyFlowLayout without padding:
			-- groups share lines, cells keep their own sizes, and a line is as
			-- deep as its largest cell.
			function flow:Apply(container, groups)
				local vertical = self.axis == 1
				local primaryDirection, crossDirection = vertical and self.y or self.x, vertical and self.x or self.y
				local cursorPrimary, cursorCross, linePrimary, lineCross = 0, 0, 0, 0
				local layoutPrimary, layoutCross, placed = 0, 0, false
				local function NextLine(gap)
					cursorPrimary = 0
					cursorCross = cursorCross + (lineCross + gap) * crossDirection
					linePrimary, lineCross = 0, 0
				end
				for _, group in ipairs(groups) do
					local elements = type(group.elements) == "function" and group.elements() or group.elements
					local spacing, lineSpacing = group.elementSpacing or 0, group.lineSpacing or 0
					local groupSpacing, groupLineSpacing = group.groupSpacing or 0, group.groupLineSpacing or lineSpacing
					if placed and #elements > 0 then
						if group.forceNewLine then
							NextLine(groupLineSpacing)
						elseif groupSpacing > 0 then
							if linePrimary > 0 and linePrimary + groupSpacing > self.lineSize then
								NextLine(groupLineSpacing)
							else
								cursorPrimary = cursorPrimary + groupSpacing * primaryDirection
								linePrimary = linePrimary + groupSpacing
							end
						end
					end
					for _, element in ipairs(elements) do
						local width, height = element:GetSize()
						local primary, cross = vertical and height or width, vertical and width or height
						local nextPrimary = linePrimary > 0 and linePrimary + primary or primary
						if linePrimary > 0 and nextPrimary > self.lineSize then
							NextLine(lineSpacing)
							nextPrimary = primary
						end
						element:ClearAllPoints()
						element:SetPoint(self.anchor, container, self.anchor,
							vertical and cursorCross or cursorPrimary, vertical and cursorPrimary or cursorCross)
						cursorPrimary = cursorPrimary + (primary + spacing) * primaryDirection
						linePrimary = nextPrimary + spacing
						lineCross = math.max(lineCross, cross)
						layoutPrimary = math.max(layoutPrimary, linePrimary - spacing)
						layoutCross = math.max(layoutCross, math.abs(cursorCross) + cross)
						placed = true
					end
				end
				container:SetSize(math.max(vertical and layoutCross or layoutPrimary, 1),
					math.max(vertical and layoutPrimary or layoutCross, 1))
			end
			return flow
		end,
	}
	-- Blizzard_SharedXML/Backdrop.lua: UV setup is Lua arithmetic on the
	-- frame's dimensions, so secret sizes fail here as in the client.
	_G.BackdropTemplateMixin = {
		SetupTextureCoordinates = function(self)
			local edgeSize, scale = self:GetEdgeSize(), self:GetEffectiveScale()
			local width, height = self:GetWidth(), self:GetHeight()
			self.__state.backdropRepeat = {
				math.max(0, width / edgeSize * scale - 2),
				math.max(0, height / edgeSize * scale - 2),
			}
			local edgeX = math.max(0, width / edgeSize * scale - 2 - BACKDROP_COORD_START)
			local edgeY = math.max(0, height / edgeSize * scale - 2 - BACKDROP_COORD_START)
			local info = self.__state.backdrop
			for name, piece in pairs(self.__state.backdropPieces or {}) do
				local repeatX, repeatY = edgeX, edgeY
				if name == "Center" then
					repeatX, repeatY = 1, 1
					local divisor = info and info.tile and (info.tileSize ~= 0 and info.tileSize or edgeSize)
					if divisor and divisor ~= 0 then repeatX, repeatY = width / divisor * scale, height / divisor * scale end
				end
				local coords = {}
				for index, key in ipairs(BACKDROP_UV_ORDER) do
					local value = BACKDROP_UVS[name][key]
					if value == "repeatX" then value = repeatX elseif value == "repeatY" then value = repeatY end
					coords[index] = value
				end
				piece:SetTexCoord(unpack(coords))
			end
		end,
	}
	_G.AuraUtil = {
		GetAuraBorderColor = function(kind)
			local colors = { Magic = { 0.2, 0.6, 1 }, Curse = { 0.6, 0, 1 }, Disease = { 0.6, 0.4, 0 }, Poison = { 0, 0.6, 0 } }
			return NewColor(unpack(colors[kind] or { 0.8, 0, 0 }))
		end,
	}
	-- Blizzard_AuraContainerShared.lua publishes these global enum tables.
	_G.AuraContainerSortMethod = { Default = 0, UnitFrameDebuff = 2, ExpirationOnly = 5 }
	_G.AuraContainerSortDirection = { Normal = 0 }
	-- The client's values, from the API snapshot.
	_G.Enum = {}
	for _, name in ipairs({ "LFGRole", "CustomAuraButtonDispelTypeTextureStyle", "StatusBarInterpolation",
		"UnitDamageAbsorbClampMode", "UnitMaximumHealthMode", "UnitIncomingHealClampMode", "StatusBarTimerDirection",
		"SecondsFormatterAbbreviation", "SecondsFormatterInterval", "SecondsFormatterRounding",
		"SecondsFormatterIntervalWhitespace", "AddOnProfilerMetric", "PowerType", "CompressionMethod",
		"CompressionLevel", "LuaCurveType", "PlayerSwingType", "RelativeContentDifficulty", "UITextureSliceMode",
		"DamageMeterSessionType", "DamageMeterType" }) do
		local values = assert(API.Snapshot().enums[name], "Enum." .. name .. " is not a client enum")
		_G.Enum[name] = {}
		for field, value in pairs(values) do _G.Enum[name][field] = value end
	end
	Mock.loadedAddons, Mock.addonMemory, Mock.profilerMetrics = {}, {}, {}
	Mock.profilerEnabled, Mock.memoryUpdates = false, 0
	_G.UpdateAddOnMemoryUsage = function() Mock.memoryUpdates = Mock.memoryUpdates + 1 end
	_G.GetAddOnMemoryUsage = function(name) return Mock.addonMemory[name] or 0 end
	_G.C_AddOnProfiler = {
		IsEnabled = function() return Mock.profilerEnabled end,
		GetAddOnMetric = function(name, metric)
			local values = Mock.profilerMetrics[name]
			return values and values[metric] or 0
		end,
		GetOverallMetric = function(metric)
			local values = Mock.profilerMetrics.overall
			return values and values[metric] or 0
		end,
		-- Offline stand-in figures: CPU clock and Lua heap growth (GC paused).
		MeasureCall = function(func, ...)
			local events, start, heap = {}, os.clock(), collectgarbage("count")
			local function Snapshot(results)
				results.elapsedMilliseconds = (os.clock() - start) * 1000
				results.elapsedTicks = 0
				results.allocatedBytes = math.max(0, collectgarbage("count") - heap) * 1024
				results.deallocatedBytes = 0
				return results
			end
			local outer = Mock.measuredEvents
			Mock.measuredEvents = { record = function(name) events[#events + 1] = Snapshot({ name = name }) end }
			collectgarbage("stop")
			local returns = { pcall(func, ...) }
			collectgarbage("restart")
			Mock.measuredEvents = outer
			if not returns[1] then error(returns[2], 0) end
			return Snapshot({ events = events }), unpack(returns, 2)
		end,
		AddMeasuredCallEvent = function(name)
			assert(type(name) == "string", "AddMeasuredCallEvent requires a name")
			if Mock.measuredEvents then Mock.measuredEvents.record(name) end
		end,
	}
	_G.C_AddOns = {
		GetNumAddOns = function()
			local count = 0
			for _ in pairs(Mock.loadedAddons) do count = count + 1 end
			return count
		end,
		GetAddOnInfo = function(index)
			local names = {}
			for name in pairs(Mock.loadedAddons) do names[#names + 1] = name end
			table.sort(names)
			local name = type(index) == "number" and names[index] or index
			if not name or Mock.loadedAddons[name] == nil then return nil end
			return name, name, "", true, "", "INSECURE"
		end,
		GetAddOnMetadata = function() return "test" end,
		LoadAddOn = function() return true end,
		IsAddOnLoaded = function(name)
			local loaded = Mock.loadedAddons[name] == true
			return loaded, loaded
		end,
	}
	_G.GetBuildInfo = function()
		local version, build = API.Snapshot().version:match("^(.+)%.(%d+)$")
		local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
		return version, build, "Oct 16 2026", major * 10000 + minor * 100 + patch
	end
	_G.C_UIFileAsset = { IsKnownFile = function() return true end }
	-- Atlas metadata (AtlasInfo); tests may override entries by atlas name.
	-- Unknown atlases return nil, like the client. Class icons default square.
	Mock.atlasInfo = {}
	_G.C_Texture = {
		GetAtlasInfo = function(atlas)
			local info = Mock.atlasInfo[atlas]
			if info == nil and atlas:lower():find("^classicon%-") then
				info = { width = 64, height = 64 }
			end
			if not info then return nil end
			-- Optional info.uv matches the four texture coordinate fields below.
			local rect = info.uv or { 0, 1, 0, 1 }
			return { elementName = atlas, width = info.width, height = info.height,
				rawSize = { x = info.width, y = info.height },
				leftTexCoord = rect[1], rightTexCoord = rect[2],
				topTexCoord = rect[3], bottomTexCoord = rect[4],
				tilesHorizontally = false, tilesVertically = false }
		end,
	}
	local defaultAuraCurve = NewCurve(false)
	_G.AuraContainerInbound = {
		GetDefaultAuraDurationFormatter = function()
			return { GetMaxIntervalCurve = function() return defaultAuraCurve end }
		end,
	}
	_G.C_DurationUtil = {
		CreateDuration = function() return NewObject("Duration") end,
		CreateDurationTextBinding = function() return NewObject("DurationTextBinding") end,
	}
	_G.C_CurveUtil = {
		CreateCurve = function() return NewCurve(false) end,
		CreateColorCurve = function() return NewCurve(true) end,
		-- Real API: picks a colour from a (possibly secret) boolean without
		-- exposing it. The mock returns secret channels for secret input.
		EvaluateColorFromBoolean = function(value, ifTrue, ifFalse)
			if Mock.IsSecret(value) then
				return NewColor(Mock.Secret(1), Mock.Secret(1), Mock.Secret(1), Mock.Secret(1))
			end
			return value and ifTrue or ifFalse
		end,
	}
	_G.C_StringUtil = {
		WrapString = function(infix, prefix, suffix)
			if AnySecret(infix, prefix, suffix) then return Mock.Secret("wrapped") end
			return infix ~= "" and ((prefix or "") .. infix .. (suffix or "")) or ""
		end,
		CreateSecondsFormatter = function()
			local formatter = NewObject("SecondsFormatter")
			function formatter:Format(seconds)
				if Mock.IsSecret(seconds) then return Mock.Secret("duration") end
				local divisor, suffix = 1, "s"
				if seconds > 129600 then divisor, suffix = 86400, "d"
				elseif seconds > 5400 then divisor, suffix = 3600, "h"
				elseif seconds > 90 then divisor, suffix = 60, "m" end
				return tostring(math.ceil(seconds / divisor)) .. suffix
			end
			return formatter
		end,
		TruncateWhenZero = function(value)
			if Mock.IsSecret(value) then
				return Mock.Secret("truncated")
			end
			-- An integer, rounded down; empty when that is zero.
			local integer = math.floor(value)
			return integer == 0 and "" or tostring(integer)
		end,
	}
	_G.C_ColorUtil = {
		-- ARGB hex with alpha forced to ff.
		GenerateTextColorCode = function(color)
			if AnySecret(color.r, color.g, color.b) then return Mock.Secret("colorcode") end
			local function Byte(value) return math.floor(value * 255 + 0.5) end
			return string.format("ff%02x%02x%02x", Byte(color.r), Byte(color.g), Byte(color.b))
		end,
	}
	_G.C_EncodingUtil = Mock.NewEncodingUtil()
	_G.AbbreviateNumbers = function(value)
		if Mock.IsSecret(value) then
			return Mock.Secret("abbreviated")
		end
		return tostring(value)
	end
	-- Digit grouping with the default "," separator.
	_G.BreakUpLargeNumbers = function(value)
		if Mock.IsSecret(value) then
			return Mock.Secret("brokenUp")
		end
		local text = tostring(math.floor(value))
		local grouped
		repeat
			text, grouped = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		until grouped == 0
		return text
	end
	_G.C_CVar = { SetCVar = function() return true end }
	InstallClientGlobals()
	require("wowmock.templates")()
	RunExtensions("install")
	Mock.EnforceAPI()
end

-- Wraps the mock's documented global functions with the client's argument
-- checks. Runs after each install; specs that replace a global afterwards
-- can call it again.
local enforced = setmetatable({}, { __mode = "k" })
function Mock.EnforceAPI()
	for name, def in pairs(API.Snapshot().functions) do
		local namespace, key = name:match("^([%w_]+)%.([%w_]+)$")
		local owner = namespace and rawget(_G, namespace) or _G
		key = key or name
		local impl = type(owner) == "table" and rawget(owner, key)
		if type(impl) == "function" and not enforced[impl] then
			local wrapper = function(...)
				API.CheckArgs(nil, name, def, Mock.IsSecret, untainted > 0, ...)
				return impl(...)
			end
			enforced[wrapper] = true
			owner[key] = wrapper
		end
	end
end

--[[
Extra client UI (tooltips, scroll boxes, class colours), plus a unit API that
returns secret values (as with forced combat restrictions).
]]
function Mock.InstallUI()
	local Secret = Mock.Secret
	local function CatchAll(name) return NewObject(name) end

	_G.ColorPickerFrame = CatchAll("ColorPickerFrame")
	_G.ScrollUtil = {
		InitScrollBoxListWithScrollBar = function() end,
		InitScrollBoxWithScrollBar = function() end,
		RegisterScrollBoxWithScrollBar = function() end,
	}
	_G.ScrollBoxConstants = { UpdateImmediately = true }
	_G.BaseScrollBoxEvents = { OnAllowScrollChanged = "OnAllowScrollChanged", OnSizeChanged = "OnSizeChanged",
		OnScroll = "OnScroll", OnLayout = "OnLayout" }
	_G.CreateScrollBoxListLinearView = function() return CatchAll("ScrollBoxListLinearView") end
	_G.CreateScrollBoxLinearView = function() return CatchAll("ScrollBoxLinearView") end
	_G.CreateDataProvider = function(items) return { items = items } end
	_G.C_ClassColor = {
		GetClassColor = function(token)
			assert(type(token) == "string" or Mock.IsSecret(token), "C_ClassColor.GetClassColor requires a class token")
			-- Native engine oracle: addon Lua must never unwrap a secret token.
			local key = Mock.IsSecret(token) and token.secretValue or token
			return RAID_CLASS_COLORS[key]
		end,
	}

	_G.SetPortraitTexture = function(texture) texture.__state.texture = "portrait" end
	_G.GetRaidTargetIndex = function(unit) return Mock.raidTargets and Mock.raidTargets[unit] end
	_G.UnitFrameUtil = {
		GetUnitPvPIndicatorDisplayInfo = Mock.SecureDelegate(function(unit, checkMercenary)
			assert(checkMercenary == true, "live PvP flags should account for mercenary mode")
			return Mock.pvpInfo[unit] or { pvpIconAtlas = "" }
		end),
	}
	_G.UnitExists = function() return true end
	-- Mock.guids[unit]; Mock.Secret(...) as in identity-restricted content.
	Mock.guids = {}
	_G.UnitGUID = function(unit) return Mock.guids[unit] end
	Mock.assignedRole = Secret(Enum.LFGRole.Tank)
	_G.UnitGroupRolesAssignedEnum = function() return Mock.assignedRole end
	_G.UnitIsPlayer = function() return true end
	_G.UnitIsConnected = function() return true end
	_G.UnitIsDead = function(unit) return Mock.dead[unit] or false end
	_G.UnitIsGhost = function(unit) return Mock.ghosts[unit] or false end
	_G.UnitIsDeadOrGhost = function(unit) return Mock.dead[unit] or Mock.ghosts[unit] or false end
	_G.UnitHasIncomingResurrection = function(unit) return Mock.incomingResurrections[unit] or false end
	_G.UnitIsTapDenied = function() return false end
	_G.UnitReaction = function() return 2 end
	_G.UnitClassification = function() return "elite" end
	_G.UnitCreatureType = function() return Secret("Beast") end
	_G.UnitName = function() return Secret("name"), Secret("realm") end
	_G.UnitNameUnmodified = _G.UnitName
	_G.UnitClass = function() return Secret("Warrior"), Secret("WARRIOR"), Secret(1) end
	_G.UnitRace = function() return Secret("Human"), Secret("Human") end
	_G.UnitLevel = function() return 30 end
	_G.UnitCanAttack = function(_, unit) return Mock.attackable[unit] or false end
	-- Not on any threat list unless a spec says otherwise.
	_G.UnitThreatSituation = function() return nil end
	_G.UnitDetailedThreatSituation = function() end
	_G.C_PlayerInfo = {
		GetContentDifficultyCreatureForPlayer = function(unit)
			return Mock.difficulties[unit] or Enum.RelativeContentDifficulty.Fair
		end,
	}
	_G.UnitHealth = function() return Secret(500) end
	_G.UnitHealthMax = function() return Secret(1000) end
	_G.UnitHealthMissing = function() return Secret(500) end
	_G.UnitGetIncomingHeals = function() return Secret(50) end
	_G.UnitGetTotalAbsorbs = function() return Secret(100) end
	_G.UnitGetTotalHealAbsorbs = function() return Secret(0) end
	-- Minimal engine-side calculation for live previews: secret, non-nil
	-- results filled by UnitGetDetailedHealPrediction.
	_G.CreateUnitHealPredictionCalculator = function()
		return {
			SetMaximumHealthMode = function(self, mode) self.maximumMode = mode end,
			SetDamageAbsorbClampMode = function(self, mode) self.damageAbsorbMode = mode end,
			GetMaximumHealth = function(self)
				return Secret(self.max + (self.maximumMode == Enum.UnitMaximumHealthMode.WithAbsorbs and self.absorb or 0))
			end,
			GetCurrentHealth = function(self) return Secret(self.current) end,
			SetIncomingHealClampMode = function(self, mode) self.incomingClampMode = mode end,
			SetIncomingHealOverflowPercent = function(self, percent) self.incomingOverflow = percent end,
			GetIncomingHealOverflowPercent = function(self) return self.incomingOverflow or 1.05 end,
			-- Missing health clamps to the room left up to maximum health times the
			-- overflow ratio, maximum health to maximum health. Without a configured
			-- mode the amount is unclamped and the flag false, as before.
			GetIncomingHeals = function(self)
				local room
				if self.incomingClampMode == Enum.UnitIncomingHealClampMode.MissingHealth then
					room = math.max(0, self.max * self:GetIncomingHealOverflowPercent() - self.current)
				elseif self.incomingClampMode == Enum.UnitIncomingHealClampMode.MaximumHealth then
					room = self.max
				end
				local amount = room and math.min(self.heal, room) or self.heal
				local clamped = room ~= nil and self.heal > room
				return Secret(amount), Secret(0), Secret(amount), Secret(clamped)
			end,
			GetDamageAbsorbs = function(self) return Secret(self.absorb), false end,
			GetHealAbsorbs = function(self) return Secret(self.healAbsorb), false end,
		}
	end
	_G.UnitGetDetailedHealPrediction = function(unit, _, calculator)
		calculator.max = UnitHealthMax(unit).secretValue
		calculator.current = UnitHealth(unit).secretValue
		calculator.heal = (UnitGetIncomingHeals(unit) or Secret(0)).secretValue
		calculator.absorb = UnitGetTotalAbsorbs(unit).secretValue
		calculator.healAbsorb = UnitGetTotalHealAbsorbs(unit).secretValue
	end
	local function Percent(_, _, _, curve)
		if curve and curve.isColor then
			return NewColor(Secret(1), Secret(1), Secret(1), Secret(1))
		end
		return Secret(50)
	end
	_G.UnitHealthPercent = function(unit, usePredicted, curve) return Percent(unit, nil, nil, curve) end
	_G.UnitPowerPercent = Percent
	_G.UnitPowerType = function() return 0, "MANA" end
	_G.UnitPower = function() return Secret(300) end
	_G.UnitPowerMax = function() return Secret(600) end
	-- Combo points the player has on the target (Mock.comboPoints), secret
	-- like other power values.
	Mock.comboPoints = 0
	_G.GetComboPoints = function() return Secret(Mock.comboPoints) end
	_G.UnitPowerMissing = function() return Secret(300) end
	_G.UnitCastingInfo = function()
		return Secret("Fireball"), Secret("Fireball"), Secret(135812), Secret(0), Secret(3000), Secret(false), Secret(1),
			Secret(true)
	end
	_G.UnitChannelInfo = function()
		return Secret("Drain Life"), Secret("Drain Life"), Secret(136169), Secret(0), Secret(5000), Secret(false),
			Secret(true)
	end
	_G.UnitCastingDuration = function() return C_DurationUtil.CreateDuration() end
	_G.UnitChannelDuration = function() return C_DurationUtil.CreateDuration() end
	RunExtensions("installUI")
	Mock.EnforceAPI()
end

return Mock
