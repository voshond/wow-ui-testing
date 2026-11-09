local _, ns = ...

XmlAddonEntries = {}
ns.entries = XmlAddonEntries

function XmlAddonLog(message)
	XmlAddonEntries[#XmlAddonEntries + 1] = message
end

function XmlAddon_OnEvent(self, event)
	self.lastEvent = event
end
