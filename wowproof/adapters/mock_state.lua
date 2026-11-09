return function(options)
	options = options or {}
	local isSecret = options.isSecret or function() return false end
	local reveal = options.reveal or function(value) return value end
	local objects = options.objects or function() return {} end
	local globals = options.globals or {}

	local function Plain(value)
		if isSecret(value) then return reveal(value) end
		return value
	end

	local function State(region)
		return rawget(region, "__state")
	end

	local function LastCall(region, name)
		local calls = rawget(region, "__calls") or {}
		for index = #calls, 1, -1 do
			if calls[index][1] == name then return calls[index] end
		end
	end

	local function Color(color)
		if not color then return nil end
		return { Plain(color[1]), Plain(color[2]), Plain(color[3]), Plain(color[4]) }
	end

	local function TexCoords(coords)
		if type(coords) ~= "table" or #coords < 4 then return nil end
		local plain = {}
		for index, value in ipairs(coords) do plain[index] = Plain(value) end
		return plain
	end

	local order = setmetatable({}, { __mode = "k" })
	local function Order(region)
		if not order[region] then
			for index, object in ipairs(objects()) do order[object] = index end
		end
		return order[region] or 0
	end

	local adapter = {}

	function adapter.Parent(region)
		local parent = State(region).parent
		if type(parent) == "table" and rawget(parent, "__state") then return parent end
		return nil
	end

	function adapter.Children(region)
		local state = State(region)
		local children = {}
		for child in pairs(state.kids or {}) do
			if State(child).parent == region then children[#children + 1] = child end
		end
		table.sort(children, function(a, b) return Order(a) < Order(b) end)
		return children
	end

	adapter.Order = Order

	function adapter.ClipsChildren(region)
		local call = LastCall(region, "SetClipsChildren")
		return State(region).clipsChildren == true or (call ~= nil and call[2] == true)
	end

	function adapter.FillOf(region)
		local parent = adapter.Parent(region)
		if parent and State(parent).fill == region then return parent end
		return nil
	end

	function adapter.Type(region)
		return rawget(region, "__type")
	end

	function adapter.Name(region)
		return State(region).name
	end

	function adapter.Points(region)
		local points = {}
		for _, point in ipairs(State(region).points or {}) do
			if point[1] == "ALL" then
				points[#points + 1] = { all = true, relativeTo = point[2] }
			else
				points[#points + 1] = {
					point = point[1],
					relativeTo = point[2],
					relativePoint = point[3],
					x = Plain(point[4]),
					y = Plain(point[5]),
				}
			end
		end
		return points
	end

	function adapter.Size(region)
		local state = State(region)
		return Plain(state.width) or 0, Plain(state.height) or 0
	end

	function adapter.Scale(region)
		return Plain(State(region).scale) or 1
	end

	function adapter.Shown(region)
		return Plain(State(region).shown) ~= false
	end

	function adapter.Alpha(region)
		local alpha = Plain(State(region).alpha)
		if alpha == nil then return 1 end
		return alpha
	end

	function adapter.IgnoresParentAlpha(region)
		return State(region).ignoreParentAlpha == true
	end

	function adapter.Strata(region)
		return State(region).strata
	end

	function adapter.Level(region)
		return Plain(State(region).level) or 0
	end

	function adapter.Layer(region)
		local call = LastCall(region, "SetDrawLayer")
		if call then return call[2], call[3] end
		return State(region).layer, State(region).sublevel
	end

	function adapter.Texture(region)
		local state = State(region)
		local gradient
		if state.gradient then
			gradient = { orientation = state.gradient[1], from = Color(state.gradient[2]), to = Color(state.gradient[3]) }
		end
		local bar = adapter.FillOf(region)
		local barState = bar and State(bar) or {}
		local file = state.texture or barState.texture
		if file ~= nil and type(file) ~= "string" then file = tostring(file) end
		local atlas
		if file and file:sub(1, 6) == "atlas:" then atlas, file = state.atlas or file:sub(7), nil end
		return {
			color = Color(state.colorTexture),
			vertexColor = Color(barState.color) or Color(state.vertexColor),
			file = file,
			atlas = atlas,
			gradient = gradient,
			blend = state.blendMode,
			slice = state.sliceMargins,
			texCoords = TexCoords(state.texCoords),
		}
	end

	function adapter.Bar(region)
		if adapter.Type(region) ~= "StatusBar" then return nil end
		local state = State(region)
		local fill = state.fill and State(state.fill) or {}
		return {
			min = Plain(state.min),
			max = Plain(state.max),
			value = Plain(state.value),
			orientation = state.orientation,
			reverse = state.reverseFill == true,
			color = Color(state.color) or Color(fill.vertexColor) or Color(fill.colorTexture),
			file = state.texture,
		}
	end

	local function FontObject(value)
		if type(value) == "string" then value = globals[value] end
		if type(value) == "table" and rawget(value, "__state") then return value end
		return nil
	end

	function adapter.Text(region)
		if adapter.Type(region) ~= "FontString" then return nil end
		local state = State(region)
		local font = state.font
		local fontObject = FontObject(state.fontObject)
		local inherited = fontObject and State(fontObject)
		font = font or (inherited and inherited.font) or {}
		local justifyH = state.justifyH or (LastCall(region, "SetJustifyH") or {})[2]
		local justifyV = state.justifyV or (LastCall(region, "SetJustifyV") or {})[2]
		return {
			text = Plain(state.text),
			font = font[1],
			size = Plain(font[2]) or 12,
			flags = font[3],
			color = Color(state.textColor) or (inherited and Color(inherited.textColor)),
			justifyH = justifyH,
			justifyV = justifyV,
		}
	end

	return adapter
end
