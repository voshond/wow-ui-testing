local Filter = {}

function Filter.SpecSelected(file, paths)
	if #paths == 0 then return true end
	for _, filter in ipairs(paths) do
		if filter:sub(-1) == "/" then
			if file:sub(1, #filter) == filter then return true end
		elseif filter:match("%.lua$") then
			if file == filter or file:match("([^/]+)$") == filter then return true end
		elseif file:find(filter, 1, true) then
			return true
		end
	end
	return false
end

function Filter.TestSelected(fullName, names, tags)
	for _, text in ipairs(names) do
		if not fullName:find(text, 1, true) then return false end
	end
	if #tags == 0 then return true end
	for tag in fullName:gmatch("#([%w_%-]+)") do
		for _, wanted in ipairs(tags) do
			if tag == wanted then return true end
		end
	end
	return false
end

return Filter
