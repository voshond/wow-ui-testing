local FakeScene = {}

function FakeScene.New()
	local scene = { nodes = {} }

	function scene.Node(kind, parent, fields)
		local node = fields or {}
		node.kind, node.parent, node.children = kind, parent, {}
		node.points = node.points or {}
		node.order = #scene.nodes + 1
		scene.nodes[#scene.nodes + 1] = node
		if parent then parent.children[#parent.children + 1] = node end
		return node
	end

	scene.adapter = {
		Parent = function(node) return node.parent end,
		Children = function(node) return node.children end,
		Order = function(node) return node.order end,
		Type = function(node) return node.kind end,
		Name = function(node) return node.name end,
		Points = function(node) return node.points end,
		Size = function(node) return node.width or 0, node.height or 0 end,
		Scale = function(node) return node.scale or 1 end,
		Shown = function(node) return node.shown ~= false end,
		Alpha = function(node) return node.alpha or 1 end,
		IgnoresParentAlpha = function(node) return node.ignoreParentAlpha == true end,
		Strata = function(node) return node.strata end,
		Level = function(node) return node.level or 0 end,
		Layer = function(node) return node.layer, node.sublevel end,
		Texture = function(node) return node.texture end,
		Bar = function(node) return node.bar end,
		Text = function(node) return node.text end,
	}

	scene.screen = scene.Node("Frame", nil, { name = "Screen" })
	return scene
end

return FakeScene
