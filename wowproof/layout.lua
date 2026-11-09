local Layout = {}
Layout.__index = Layout

local FRACTIONS = {
	TOPLEFT = { 0, 0 },
	TOP = { 0.5, 0 },
	TOPRIGHT = { 1, 0 },
	LEFT = { 0, 0.5 },
	CENTER = { 0.5, 0.5 },
	RIGHT = { 1, 0.5 },
	BOTTOMLEFT = { 0, 1 },
	BOTTOM = { 0.5, 1 },
	BOTTOMRIGHT = { 1, 1 },
}
Layout.FRACTIONS = FRACTIONS

local UNRESOLVED = false

function Layout.New(adapter, screen)
	screen = screen or { width = 1920, height = 1080 }
	return setmetatable({
		adapter = adapter,
		screen = { left = 0, top = 0, width = screen.width, height = screen.height },
		rects = {},
		scales = {},
		resolving = {},
	}, Layout)
end

function Layout:Scale(region)
	local cached = self.scales[region]
	if cached then return cached end
	local scale = self.adapter.Scale(region) or 1
	local parent = self.adapter.Parent(region)
	if parent then scale = scale * self:Scale(parent) end
	self.scales[region] = scale
	return scale
end

function Layout:Place(region, rect)
	self.rects[region] = rect
end

function Layout:Rect(region)
	if region == nil then return self.screen end
	local cached = self.rects[region]
	if cached ~= nil then return cached or nil end
	if self.resolving[region] then return nil end
	self.resolving[region] = true
	local rect = self:Resolve(region)
	self.resolving[region] = nil
	self.rects[region] = rect or UNRESOLVED
	return rect
end

-- Like the client, per axis an edge anchor (TOP, LEFT, ...) wins over the
-- centre component of another anchor: LEFT + RIGHT + TOP with a height puts
-- the region below TOP, not around the vertical centre LEFT names.
local function Axis(anchors, size)
	local edges = {}
	for _, anchor in ipairs(anchors) do
		if anchor[1] ~= 0.5 then edges[#edges + 1] = anchor end
	end
	if #edges > 0 then anchors = edges end
	local low, high
	for _, anchor in ipairs(anchors) do
		if not low or anchor[1] < low[1] then low = anchor end
		if not high or anchor[1] > high[1] then high = anchor end
	end
	if not low then return nil end
	if low[1] ~= high[1] then
		local span = (high[2] - low[2]) / (high[1] - low[1])
		return low[2] - low[1] * span, span
	end
	return low[2] - low[1] * size, size
end

function Layout:IntrinsicSize(region, width, height)
	if self.adapter.Type(region) ~= "FontString" then return width, height end
	local text = self.adapter.Text(region)
	local size = text and text.size or 12
	if width == 0 then width = #tostring(text and text.text or "") * size * 0.55 end
	if height == 0 then height = size end
	return width, height
end

local function Clamp(value)
	if value < 0 then return 0 end
	if value > 1 then return 1 end
	return value
end

function Layout:FillRect(bar)
	local rect = self:Rect(bar)
	local info = rect and self.adapter.Bar(bar)
	if not info then return nil end
	local low, high, value = info.min or 0, info.max or 1, info.value or 0
	local fraction = high > low and Clamp((value - low) / (high - low)) or 0
	local fill = { left = rect.left, top = rect.top, width = rect.width, height = rect.height }
	if info.orientation == "VERTICAL" then
		fill.height = rect.height * fraction
		if not info.reverse then fill.top = rect.top + rect.height - fill.height end
	else
		fill.width = rect.width * fraction
		if info.reverse then fill.left = rect.left + rect.width - fill.width end
	end
	return fill
end

function Layout:Resolve(region)
	local adapter = self.adapter
	local bar = adapter.FillOf and adapter.FillOf(region)
	if bar then return self:FillRect(bar) end
	local points = adapter.Points(region)
	local parent = adapter.Parent(region)
	if #points == 0 then
		if parent then return nil end
		return self.screen
	end
	local scale = self:Scale(region)
	local width, height = adapter.Size(region)
	width, height = self:IntrinsicSize(region, width or 0, height or 0)
	width, height = width * scale, height * scale
	local xs, ys = {}, {}
	for _, point in ipairs(points) do
		local relative = point.relativeTo or parent
		local target = self:Rect(relative)
		if not target then return nil end
		if point.all then
			xs[#xs + 1] = { 0, target.left }
			xs[#xs + 1] = { 1, target.left + target.width }
			ys[#ys + 1] = { 0, target.top }
			ys[#ys + 1] = { 1, target.top + target.height }
		else
			local own = FRACTIONS[point.point]
			local other = FRACTIONS[point.relativePoint or point.point]
			if not own or not other then
				error("unknown anchor point " .. tostring(point.point) .. "/" .. tostring(point.relativePoint), 2)
			end
			xs[#xs + 1] = { own[1], target.left + other[1] * target.width + (point.x or 0) * scale }
			ys[#ys + 1] = { own[2], target.top + other[2] * target.height - (point.y or 0) * scale }
		end
	end
	local left, resolvedWidth = Axis(xs, width)
	local top, resolvedHeight = Axis(ys, height)
	return { left = left, top = top, width = resolvedWidth, height = resolvedHeight }
end

return Layout
