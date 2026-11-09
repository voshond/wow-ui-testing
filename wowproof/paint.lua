local Scene = require("wowproof.scene")

local Paint = {}

local DEFAULT_BAR_COLOR = { 0.2, 0.7, 0.3, 1 }
local DEFAULT_TEXT_COLOR = { 1, 1, 1, 1 }
local PLACEHOLDER_COLOR = { 0.42, 0.45, 0.5, 0.25 }

local function Number(value)
	if math.abs(value) < 0.005 then return "0" end
	local text = string.format("%.2f", value):gsub("%.?0+$", "")
	return text
end
Paint.Number = Number

local function Escape(text)
	return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end
Paint.Escape = Escape

local function Clamp(value)
	if value < 0 then return 0 end
	if value > 1 then return 1 end
	return value
end

local function Rgb(color)
	return string.format("rgb(%d,%d,%d)",
		math.floor(Clamp(color[1] or 0) * 255 + 0.5),
		math.floor(Clamp(color[2] or 0) * 255 + 0.5),
		math.floor(Clamp(color[3] or 0) * 255 + 0.5))
end

local function Multiply(color, tint)
	if not tint then return color end
	return {
		(color[1] or 1) * (tint[1] or 1),
		(color[2] or 1) * (tint[2] or 1),
		(color[3] or 1) * (tint[3] or 1),
		(color[4] or 1) * (tint[4] or 1),
	}
end

local function RectAttributes(rect)
	return string.format('x="%s" y="%s" width="%s" height="%s"',
		Number(rect.left), Number(rect.top), Number(math.max(rect.width, 0)), Number(math.max(rect.height, 0)))
end

local function Fill(color, alpha)
	return string.format('fill="%s" fill-opacity="%s"', Rgb(color), Number(Clamp((color[4] or 1) * alpha)))
end

local function Union(a, b)
	if not a then return { left = b.left, top = b.top, width = b.width, height = b.height } end
	local left, top = math.min(a.left, b.left), math.min(a.top, b.top)
	local right = math.max(a.left + a.width, b.left + b.width)
	local bottom = math.max(a.top + a.height, b.top + b.height)
	return { left = left, top = top, width = right - left, height = bottom - top }
end

local function Intersect(a, b)
	local left, top = math.max(a.left, b.left), math.max(a.top, b.top)
	local right = math.min(a.left + a.width, b.left + b.width)
	local bottom = math.min(a.top + a.height, b.top + b.height)
	if right <= left or bottom <= top then return nil end
	return { left = left, top = top, width = right - left, height = bottom - top }
end

local function Contains(outer, inner)
	return inner.left >= outer.left and inner.top >= outer.top
		and inner.left + inner.width <= outer.left + outer.width
		and inner.top + inner.height <= outer.top + outer.height
end

local Context = {}
Context.__index = Context

function Context:Define(markup)
	self.nextId = self.nextId + 1
	local id = "d" .. self.nextId
	self.defs[#self.defs + 1] = markup:gsub("{id}", id)
	return id
end

function Context:Emit(markup)
	self.body[#self.body + 1] = markup
end

function Context:Visible(region)
	local node = region
	while node do
		if not self.adapter.Shown(node) then return false end
		if node == self.root then return true end
		node = self.adapter.Parent(node)
	end
	return true
end

function Context:EffectiveAlpha(region)
	local alpha, node = 1, region
	while node do
		alpha = alpha * (self.adapter.Alpha(node) or 1)
		if node == self.root or self.adapter.IgnoresParentAlpha(node) then break end
		node = self.adapter.Parent(node)
	end
	return alpha
end

function Context:Clip(region)
	local cached = self.clips[region]
	if cached ~= nil then return cached or nil end
	local parent = region ~= self.root and self.adapter.Parent(region)
	local clip
	if parent then
		clip = self:Clip(parent)
		local parentRect = self.adapter.ClipsChildren and self.adapter.ClipsChildren(parent) and self.layout:Rect(parent)
		if parentRect then
			if clip then
				clip = Intersect(clip, parentRect) or { left = parentRect.left, top = parentRect.top, width = 0, height = 0 }
			else
				clip = parentRect
			end
		end
	end
	self.clips[region] = clip or false
	return clip
end

function Context:ClipPath(clip)
	local key = string.format("%s,%s,%s,%s", Number(clip.left), Number(clip.top), Number(clip.width), Number(clip.height))
	if not self.clipIds[key] then
		self.clipIds[key] = self:Define(string.format('<clipPath id="{id}"><rect %s/></clipPath>', RectAttributes(clip)))
	end
	return self.clipIds[key]
end

function Context:Strata(region)
	local node = region
	while node do
		local strata = self.adapter.Strata(node)
		if strata then return Scene.STRATA_INDEX[strata] or Scene.STRATA_INDEX.MEDIUM end
		node = self.adapter.Parent(node)
	end
	return Scene.STRATA_INDEX.MEDIUM
end

function Context:SortKey(region)
	local adapter = self.adapter
	local isRegion = Scene.IsRegion(adapter, region)
	local frame = isRegion and adapter.Parent(region) or region
	local layer, sublevel = adapter.Layer(region)
	if not isRegion then layer = "ARTWORK" end
	return {
		self:Strata(frame),
		frame and adapter.Level(frame) or 0,
		Scene.LAYER_INDEX[layer or "ARTWORK"] or Scene.LAYER_INDEX.ARTWORK,
		sublevel or 0,
		adapter.Order(region),
	}
end

local function CompareKeys(a, b)
	for index = 1, #a.key do
		if a.key[index] ~= b.key[index] then return a.key[index] < b.key[index] end
	end
	return false
end

function Context:Collect(region, out)
	out[#out + 1] = region
	for _, child in ipairs(self.adapter.Children(region)) do self:Collect(child, out) end
	return out
end

local GRADIENT = '<linearGradient id="{id}" x1="%s" y1="%s" x2="%s" y2="%s">'
	.. '<stop offset="0" stop-color="%s" stop-opacity="%s"/><stop offset="1" stop-color="%s" stop-opacity="%s"/>'
	.. '</linearGradient>'

function Context:ImageDef(key, load)
	local cached = self.images[key]
	if cached ~= nil then return cached or nil end
	local href, width, height, rect = load()
	if not href then
		self.images[key] = false
		return nil
	end
	local id = self:Define(string.format('<image id="{id}" width="%s" height="%s" preserveAspectRatio="none" href="%s"/>',
		Number(width or 1), Number(height or 1), href))
	local image = { id = id, width = width, height = height, rect = rect }
	self.images[key] = image
	return image
end

local function AtlasCoords(coords, rect)
	if not coords or #coords < 4 then return nil end
	local width, height = rect.right - rect.left, rect.bottom - rect.top
	local function U(value) return (value - rect.left) / width end
	local function V(value) return (value - rect.top) / height end
	if #coords >= 8 then
		local mapped = {}
		for index = 1, 8, 2 do mapped[index], mapped[index + 1] = U(coords[index]), V(coords[index + 1]) end
		return mapped
	end
	return { U(coords[1]), U(coords[2]), V(coords[3]), V(coords[4]) }
end
Paint.AtlasCoords = AtlasCoords

function Context:TextureImage(texture)
	if texture.atlas then
		local atlas = texture.atlas
		local image = self:ImageDef("atlas:" .. atlas, function() return self.atlas(atlas) end)
		if image then return image, AtlasCoords(texture.texCoords, image.rect) end
	end
	local file = texture.file
	if not file then return nil end
	return self:ImageDef(file, function() return self.image(file) end), texture.texCoords
end

function Context:DrawImagePiece(image, target, source)
	if target.width <= 0 or target.height <= 0 or source.width <= 0 or source.height <= 0 then return end
	self:Emit(string.format('<svg %s viewBox="%s %s %s %s" preserveAspectRatio="none" overflow="hidden"><use href="#%s"/></svg>',
		RectAttributes(target), Number(source.left), Number(source.top), Number(source.width), Number(source.height), image.id))
end

local function SourceRect(coords, width, height)
	if not coords or #coords < 4 then return { left = 0, top = 0, width = width, height = height } end
	local xs, ys = { coords[1], coords[2] }, { coords[3], coords[4] }
	if #coords >= 8 then
		xs = { coords[1], coords[3], coords[5], coords[7] }
		ys = { coords[2], coords[4], coords[6], coords[8] }
	end
	local left, right = math.min(unpack(xs)), math.max(unpack(xs))
	local top, bottom = math.min(unpack(ys)), math.max(unpack(ys))
	return { left = left * width, top = top * height, width = (right - left) * width, height = (bottom - top) * height }
end
Paint.SourceRect = SourceRect

local function Corners(coords)
	if #coords >= 8 then
		return { coords[1], coords[2] }, { coords[3], coords[4] }, { coords[5], coords[6] }
	end
	local left, right, top, bottom = coords[1], coords[2], coords[3], coords[4]
	return { left, top }, { left, bottom }, { right, top }
end

local function NeedsAffine(coords)
	if not coords or #coords < 4 then return false end
	for _, value in ipairs(coords) do
		if value < 0 or value > 1 then return true end
	end
	local upperLeft, lowerLeft, upperRight = Corners(coords)
	return upperLeft[2] ~= upperRight[2] or upperLeft[1] ~= lowerLeft[1]
		or upperRight[1] < upperLeft[1] or lowerLeft[2] < upperLeft[2]
end
Paint.NeedsAffine = NeedsAffine

local MAX_TILE = 8192

local function AffineTransform(rect, coords, width, height)
	local upperLeft, lowerLeft, upperRight = Corners(coords)
	local ax, ay = upperRight[1] - upperLeft[1], upperRight[2] - upperLeft[2]
	local bx, by = lowerLeft[1] - upperLeft[1], lowerLeft[2] - upperLeft[2]
	local det = ax * by - bx * ay
	if math.abs(det) < 1e-9 then return nil end
	local w, h = rect.width, rect.height
	local tileWidth = math.sqrt((w * by / det) ^ 2 + (h * ay / det) ^ 2)
	local tileHeight = math.sqrt((w * bx / det) ^ 2 + (h * ax / det) ^ 2)
	if tileWidth < 0.01 or tileHeight < 0.01 or tileWidth > MAX_TILE or tileHeight > MAX_TILE then return nil end
	return {
		w * by / det / width,
		h * -ay / det / width,
		w * -bx / det / height,
		h * ax / det / height,
		rect.left - w * (by * upperLeft[1] - bx * upperLeft[2]) / det,
		rect.top - h * (ax * upperLeft[2] - ay * upperLeft[1]) / det,
	}
end
Paint.AffineTransform = AffineTransform

local function SliceSpans(start, length, sourceLength, low, high)
	local scale = math.min(1, length / math.max(low + high, 1))
	local lowTarget, highTarget = low * scale, high * scale
	return {
		{ start, lowTarget, 0, low },
		{ start + lowTarget, length - lowTarget - highTarget, low, sourceLength - low - high },
		{ start + length - highTarget, highTarget, sourceLength - high, high },
	}
end

function Context:DrawImageAffine(image, rect, coords)
	if rect.width <= 0 or rect.height <= 0 then return end
	local matrix = AffineTransform(rect, coords, image.width, image.height)
	if not matrix then return end
	local values = {}
	for index, value in ipairs(matrix) do values[index] = string.format("%.6g", value) end
	local id = self:Define(string.format(
		'<pattern id="{id}" patternUnits="userSpaceOnUse" width="%s" height="%s" patternTransform="matrix(%s)"><use href="#%s"/></pattern>',
		Number(image.width), Number(image.height), table.concat(values, " "), image.id))
	self:Emit(string.format('<rect %s fill="url(#%s)"/>', RectAttributes(rect), id))
end

function Context:DrawNineSlice(image, slice, rect)
	local columns = SliceSpans(rect.left, rect.width, image.width, slice[1] or 0, slice[3] or 0)
	local rows = SliceSpans(rect.top, rect.height, image.height, slice[2] or 0, slice[4] or 0)
	for _, row in ipairs(rows) do
		for _, column in ipairs(columns) do
			self:DrawImagePiece(image,
				{ left = column[1], top = row[1], width = column[2], height = row[2] },
				{ left = column[3], top = row[3], width = column[4], height = row[4] })
		end
	end
end

function Context:DrawTexture(region, rect, alpha)
	local texture = self.adapter.Texture(region)
	if not texture then return end
	local blend = texture.blend == "ADD" and ' style="mix-blend-mode:screen"' or ""
	if texture.gradient then
		local from, to = texture.gradient.from, texture.gradient.to
		local vertical = texture.gradient.orientation == "VERTICAL"
		local id = self:Define(string.format(GRADIENT,
			"0", vertical and "1" or "0", vertical and "0" or "1", "0",
			Rgb(from), Number(Clamp((from[4] or 1) * alpha)), Rgb(to), Number(Clamp((to[4] or 1) * alpha))))
		self:Emit(string.format('<rect %s fill="url(#%s)"%s/>', RectAttributes(rect), id, blend))
		return
	end
	local solid = texture.color or (Scene.IsSolidFile(texture.file) and { 1, 1, 1, 1 })
	if solid then
		self:Emit(string.format('<rect %s %s%s/>', RectAttributes(rect), Fill(Multiply(solid, texture.vertexColor), alpha), blend))
		return
	end
	local image, coords = self:TextureImage(texture)
	if image then
		local filter = ""
		local tint = texture.vertexColor
		if tint then
			local id = self:Define(string.format(
				'<filter id="{id}" color-interpolation-filters="sRGB"><feColorMatrix type="matrix" values="%s 0 0 0 0 0 %s 0 0 0 0 0 %s 0 0 0 0 0 %s 0"/></filter>',
				Number(tint[1] or 1), Number(tint[2] or 1), Number(tint[3] or 1), Number(tint[4] or 1)))
			filter = string.format(' filter="url(#%s)"', id)
		end
		self:Emit(string.format('<g opacity="%s"%s%s>', Number(Clamp(alpha)), filter, blend))
		if texture.slice and image.width then
			self:DrawNineSlice(image, texture.slice, rect)
		elseif NeedsAffine(coords) and image.width then
			self:DrawImageAffine(image, rect, coords)
		else
			self:DrawImagePiece(image, rect, SourceRect(coords, image.width or 1, image.height or 1))
		end
		self:Emit("</g>")
		return
	end
	if texture.vertexColor and texture.file then
		self:Emit(string.format('<rect %s %s%s/>', RectAttributes(rect), Fill(texture.vertexColor, alpha), blend))
		return
	end
	if texture.file or texture.atlas then self:DrawPlaceholder(rect, alpha, texture.file or texture.atlas) end
end

function Context:DrawPlaceholder(rect, alpha, title)
	self:Emit(string.format('<rect %s %s stroke="%s" stroke-opacity="0.5" stroke-dasharray="2 2"><title>%s</title></rect>',
		RectAttributes(rect), Fill(PLACEHOLDER_COLOR, alpha), Rgb(PLACEHOLDER_COLOR), Escape(title)))
end

local function CoverRect(source, target)
	if source.width <= 0 or source.height <= 0 or target.width <= 0 or target.height <= 0 then return source end
	local aspect = target.width / target.height
	if source.width / source.height > aspect then
		local width = source.height * aspect
		return { left = source.left + (source.width - width) / 2, top = source.top, width = width, height = source.height }
	end
	local height = source.width / aspect
	return { left = source.left, top = source.top + (source.height - height) / 2, width = source.width, height = height }
end
Paint.CoverRect = CoverRect

local function ModelSubject(info)
	return info.unit or info.file or (info.displayId and "display " .. info.displayId)
		or (info.creatureId and "creature " .. info.creatureId)
end
Paint.ModelSubject = ModelSubject

function Context:DrawModel(region, rect, alpha)
	local info = self.adapter.Model and self.adapter.Model(region)
	if not info then
		self:DrawPlaceholder(rect, alpha, "model: " .. self.adapter.Type(region))
		return
	end
	local subject = ModelSubject(info)
	alpha = alpha * Clamp(info.modelAlpha or 1)
	if not subject or alpha <= 0 then return end
	local art = self.model(info)
	if type(art) == "string" then art = { file = art } end
	local image
	if art and art.path then
		image = self:ImageDef("path:" .. art.path, function() return self.file(art.path) end)
	elseif art and art.file then
		image = self:ImageDef(art.file, function() return self.image(art.file) end)
	end
	if not image or not image.width then
		self:DrawPlaceholder(rect, alpha, "model: " .. subject)
		return
	end
	local filter = ""
	local desaturation = Clamp(info.desaturation or 0)
	if desaturation > 0 then
		local id = self:Define(string.format(
			'<filter id="{id}" color-interpolation-filters="sRGB"><feColorMatrix type="saturate" values="%s"/></filter>',
			Number(1 - desaturation)))
		filter = string.format(' filter="url(#%s)"', id)
	end
	self:Emit(string.format('<g opacity="%s"%s>', Number(alpha), filter))
	self:DrawImagePiece(image, rect, CoverRect(SourceRect(art.texCoords, image.width, image.height), rect))
	self:Emit("</g>")
end

function Context:DrawBar(region, alpha)
	local bar = self.adapter.Bar(region)
	local fill = bar and self.layout:FillRect(region)
	if not fill or fill.width <= 0 or fill.height <= 0 then return end
	local color = bar.color or DEFAULT_BAR_COLOR
	self:Emit(string.format('<rect %s %s/>', RectAttributes(fill), Fill(color, alpha)))
end

local ANCHORS = { LEFT = "start", CENTER = "middle", RIGHT = "end" }

local function Segments(text, baseColor)
	local segments, color, position = {}, baseColor, 1
	text = text:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|n", "\n")
	while position <= #text do
		local start, finish, code = text:find("|c(%x%x%x%x%x%x%x%x)", position)
		local reset = text:find("|r", position, true)
		local nextStop = math.min(start or #text + 1, reset or #text + 1)
		if nextStop > position then segments[#segments + 1] = { text:sub(position, nextStop - 1), color } end
		if start and start == nextStop then
			color = {
				tonumber(code:sub(3, 4), 16) / 255,
				tonumber(code:sub(5, 6), 16) / 255,
				tonumber(code:sub(7, 8), 16) / 255,
				tonumber(code:sub(1, 2), 16) / 255,
			}
			position = finish + 1
		elseif reset and reset == nextStop then
			color = baseColor
			position = reset + 2
		else
			position = nextStop
		end
	end
	return segments
end
Paint.Segments = Segments

function Context:DrawText(region, rect, alpha)
	local text = self.adapter.Text(region)
	if not text or text.text == nil or tostring(text.text) == "" then return end
	local size = text.size or 12
	local justify = text.justifyH or "CENTER"
	local x = rect.left
	if justify == "CENTER" then x = rect.left + rect.width / 2 elseif justify == "RIGHT" then x = rect.left + rect.width end
	local y = rect.top + rect.height / 2
	if text.justifyV == "TOP" then y = rect.top + size / 2 elseif text.justifyV == "BOTTOM" then y = rect.top + rect.height - size / 2 end
	local flags = text.flags or ""
	local stroke = ""
	if flags:find("OUTLINE", 1, true) then
		stroke = string.format(' stroke="#000" stroke-width="%s" stroke-linejoin="round" paint-order="stroke"',
			Number(flags:find("THICK", 1, true) and size * 0.2 or size * 0.12))
	end
	local family, weight = self.font(text.font)
	local spans = {}
	for _, segment in ipairs(Segments(tostring(text.text), text.color or DEFAULT_TEXT_COLOR)) do
		spans[#spans + 1] = string.format('<tspan %s>%s</tspan>', Fill(segment[2], alpha), Escape(segment[1]))
	end
	self:Emit(string.format(
		'<text x="%s" y="%s" font-family="%s" font-weight="%d" font-size="%s" text-anchor="%s" dominant-baseline="central"%s>%s</text>',
		Number(x), Number(y), Escape(family or "sans-serif"), weight or 400, Number(size),
		ANCHORS[justify] or "middle", stroke, table.concat(spans)))
end

function Context:DrawOutline(region, rect)
	self:Emit(string.format('<rect %s fill="none" stroke="#ff00ff" stroke-opacity="0.6" stroke-width="0.5"><title>%s</title></rect>',
		RectAttributes(rect), Escape(self.adapter.Name(region) or self.adapter.Type(region))))
end

function Paint.Render(options)
	local adapter, layout, root = options.adapter, options.layout, options.root
	local context = setmetatable({
		adapter = adapter,
		layout = layout,
		root = root,
		image = options.image or function() return nil end,
		atlas = options.atlas or function() return nil end,
		font = options.font or function() return nil end,
		model = options.model or function() return nil end,
		file = options.file or function() return nil end,
		defs = {},
		body = {},
		images = {},
		clips = {},
		clipIds = {},
		nextId = 0,
	}, Context)
	local rootRect = layout:Rect(root)
	if not rootRect then error("wowproof: the region has no resolvable position", 2) end
	if not adapter.Shown(root) then error("wowproof: the region is hidden", 2) end

	local entries, bounds = {}, nil
	for _, region in ipairs(context:Collect(root, {})) do
		local rect = layout:Rect(region)
		local clip = rect and context:Clip(region)
		local shown = rect and (clip and Intersect(rect, clip) or (not clip and rect))
		if shown and shown.width > 0 and shown.height > 0 and context:Visible(region) then
			local alpha = context:EffectiveAlpha(region)
			if alpha > 0 then
				entries[#entries + 1] = { region = region, rect = rect, clip = clip, alpha = alpha, key = context:SortKey(region) }
				if Scene.IsRegion(adapter, region) or not adapter.FillOf then bounds = Union(bounds, shown) end
			end
		end
	end
	table.sort(entries, CompareKeys)

	for _, entry in ipairs(entries) do
		local clipped = entry.clip and not Contains(entry.clip, entry.rect)
		if clipped then context:Emit(string.format('<g clip-path="url(#%s)">', context:ClipPath(entry.clip))) end
		local kind = adapter.Type(entry.region)
		if kind == "Texture" then
			context:DrawTexture(entry.region, entry.rect, entry.alpha)
		elseif kind == "FontString" then
			context:DrawText(entry.region, entry.rect, entry.alpha)
		elseif Scene.IsModel(adapter, entry.region) then
			context:DrawModel(entry.region, entry.rect, entry.alpha)
		elseif not adapter.FillOf and not Scene.IsRegion(adapter, entry.region) then
			context:DrawBar(entry.region, entry.alpha)
		end
		if clipped then context:Emit("</g>") end
	end
	if options.debug then
		for _, entry in ipairs(entries) do context:DrawOutline(entry.region, entry.rect) end
	end

	local pad = options.pad or 8
	local view = Intersect(Union(bounds or rootRect, rootRect), layout.screen) or rootRect
	view = { left = view.left - pad, top = view.top - pad, width = view.width + pad * 2, height = view.height + pad * 2 }
	local width, height = math.ceil(view.width), math.ceil(view.height)
	local out = {
		string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="%s %s %s %s">',
			width, height, Number(view.left), Number(view.top), Number(width), Number(height)),
	}
	if #context.defs > 0 then out[#out + 1] = "<defs>" .. table.concat(context.defs) .. "</defs>" end
	out[#out + 1] = string.format('<rect x="%s" y="%s" width="%d" height="%d" fill="%s"/>',
		Number(view.left), Number(view.top), width, height, options.background or "#14171c")
	for _, markup in ipairs(context.body) do out[#out + 1] = markup end
	out[#out + 1] = "</svg>\n"
	return table.concat(out, "\n"), { width = width, height = height, regions = #entries }
end

return Paint
