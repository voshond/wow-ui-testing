local Scene = require("wowproof.scene")
local Layout = require("wowproof.layout")
local Paint = require("wowproof.paint")
local Raster = require("wowproof.raster")
local Sheet = require("wowproof.sheet")

local Proof = {}
Proof.__index = Proof
Proof.Scene, Proof.Layout, Proof.Paint, Proof.Raster, Proof.Sheet = Scene, Layout, Paint, Raster, Sheet

function Proof.New(options)
	options = options or {}
	local assets = options.assets or {}
	local outDir = options.outDir or ".proof"
	return setmetatable({
		adapter = Scene.Validate(options.adapter),
		assets = assets,
		outDir = outDir,
		cacheDir = outDir .. "/.cache",
		screen = options.screen,
		scale = options.scale or 2,
		png = options.png ~= false,
		title = options.title or "UI proof",
		settle = options.settle,
		entries = {},
		images = {},
	}, Proof)
end

function Proof:Image(file)
	local cached = self.images[file]
	if cached == nil then
		local resolve = self.assets.textures
		local localFile = resolve and resolve(file)
		local png = localFile and Raster.ToPng(localFile, self.cacheDir)
		local uri = png and Raster.DataUri(png)
		cached = false
		if uri then
			local width, height = Raster.PngSize(png)
			cached = { uri = uri, width = width, height = height }
		end
		self.images[file] = cached
	end
	if not cached then return nil end
	return cached.uri, cached.width, cached.height
end

function Proof:Font(file)
	local fonts = self.assets.fonts
	if not fonts then return nil end
	if fonts.family then
		local family, weight = fonts.family(file)
		if family then return family, weight end
	end
	return fonts.default, fonts.defaultWeight
end

local function FileName(name)
	return (name:gsub("[^%w%-_]+", "-"))
end

function Proof:Render(region, options)
	options = options or {}
	local layout = Layout.New(self.adapter, self.screen)
	if self.settle then self.settle(layout, region) end
	return Paint.Render({
		adapter = self.adapter,
		layout = layout,
		root = region,
		pad = options.pad,
		debug = options.debug,
		background = options.background,
		image = function(file) return self:Image(file) end,
		font = function(file) return self:Font(file) end,
	})
end

function Proof:Snapshot(region, name, options)
	options = options or {}
	local svg, info = self:Render(region, options)
	Raster.MakeDir(self.outDir)
	local base = self.outDir .. "/" .. FileName(name)
	local entry = { name = name, svg = base .. ".svg", width = info.width, height = info.height, regions = info.regions }
	Raster.Write(entry.svg, svg)
	if self.png then
		local fonts = self.assets.fonts and self.assets.fonts.dirs
		self.fontConfig = self.fontConfig or Raster.FontConfig(fonts, self.cacheDir)
		if Raster.Has("rsvg-convert") then
			entry.png = Raster.SvgToPng(entry.svg, base .. ".png", options.scale or self.scale, self.fontConfig)
			if not entry.png then
				os.remove(base .. ".png")
				error("wowproof: rsvg-convert could not render " .. entry.svg, 2)
			end
		end
	end
	self.entries[#self.entries + 1] = entry
	return entry
end

function Proof:Fail(name, message)
	local entry = { name = name, error = tostring(message) }
	self.entries[#self.entries + 1] = entry
	return entry
end

function Proof:Sheet()
	Raster.MakeDir(self.outDir)
	local file = self.outDir .. "/index.html"
	Raster.Write(file, Sheet.Render(self.title, self.entries))
	return file
end

return Proof
