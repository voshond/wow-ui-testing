return function(atlases)
	local byName = {}
	for name, info in pairs(atlases or {}) do byName[name:lower()] = info end
	return function(name)
		if type(name) ~= "string" then return nil end
		return byName[name:lower()]
	end
end
