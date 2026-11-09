local Args = {}

function Args.Parse(list)
	local options = { paths = {}, names = {}, tags = {} }
	local i = 1
	local function Value(option)
		i = i + 1
		return list[i] or error(option .. " needs a value", 0)
	end
	while list[i] do
		local value = list[i]
		if value == "--times" then
			options.times = true
		elseif value == "-h" or value == "--help" then
			options.help = true
		elseif value == "-t" or value == "--test" then
			options.names[#options.names + 1] = Value(value)
		elseif value == "--tag" then
			options.tags[#options.tags + 1] = (Value(value):gsub("^#", ""))
		elseif value == "-j" or value == "--jobs" then
			if list[i + 1] and list[i + 1]:match("^%d+$") then
				options.jobs = tonumber(Value(value))
			else
				options.jobs = 0
			end
		elseif value == "--config" then
			options.config = Value(value)
		elseif value == "--child" then
			options.child = Value(value)
		elseif value:sub(1, 1) == "-" then
			error("unknown option " .. value, 0)
		else
			options.paths[#options.paths + 1] = value
		end
		i = i + 1
	end
	return options
end

Args.USAGE = [[
Usage: luajit wowtest/cli.lua [options] [path filters...]

  units                 spec paths containing "units" (folder or file)
  units/                exactly the units/ folder of a spec dir
  shields_spec.lua      exactly that spec file
  -t, --test TEXT       only tests whose full name contains TEXT
  --tag NAME            only tests tagged #NAME (in a describe or it name)
  -j, --jobs [N]        spec files in parallel, one process per CPU (or N)
  --times               also report how long each spec file took
  --config FILE         host config (default: wut.config.lua, then tests/wut.config.lua)

Path filters are combined with "or"; -t and --tag narrow further. A run that
selects no tests fails.]]

return Args
