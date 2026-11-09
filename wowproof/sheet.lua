local Paint = require("wowproof.paint")

local Sheet = {}

local PAGE = [[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>%s</title>
<style>
body { margin: 0; padding: 24px; background: #0b0d10; color: #d6dae0; font: 14px/1.4 system-ui, sans-serif; }
h1 { font-size: 18px; margin: 0 0 4px; }
p.summary { margin: 0 0 20px; color: #8b93a0; }
main { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; }
figure { margin: 0; padding: 12px; background: #14171c; border: 1px solid #262b33; border-radius: 8px; }
figure.failed { border-color: #b4383d; }
figure img { display: block; max-width: 100%%; image-rendering: auto; }
figcaption { margin-top: 8px; font-weight: 600; }
figcaption a { color: #8b93a0; font-weight: 400; margin-left: 8px; }
pre { white-space: pre-wrap; color: #f08b8f; font-size: 12px; margin: 8px 0 0; }
</style>
</head>
<body>
<h1>%s</h1>
<p class="summary">%s</p>
<main>
%s
</main>
</body>
</html>
]]

local function BaseName(path)
	return path and path:match("([^/]+)$")
end

function Sheet.Render(title, entries)
	local figures, failed = {}, 0
	for _, entry in ipairs(entries) do
		if entry.error then
			failed = failed + 1
			figures[#figures + 1] = string.format('<figure class="failed"><figcaption>%s</figcaption><pre>%s</pre></figure>',
				Paint.Escape(entry.name), Paint.Escape(entry.error))
		else
			local image = BaseName(entry.png) or BaseName(entry.svg)
			figures[#figures + 1] = string.format(
				'<figure><img src="%s" alt="%s"><figcaption>%s<a href="%s">svg</a></figcaption></figure>',
				Paint.Escape(image), Paint.Escape(entry.name), Paint.Escape(entry.name), Paint.Escape(BaseName(entry.svg)))
		end
	end
	local summary = string.format("%d snapshots, %d failed", #entries - failed, failed)
	return string.format(PAGE, Paint.Escape(title), Paint.Escape(title), summary, table.concat(figures, "\n"))
end

return Sheet
