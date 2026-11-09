local addonName = ...

SamplePlugin = { panelOwner = PanelRegistry.owner }

function SamplePlugin.OnPanelReady()
	SamplePlugin.ready = true
end

PanelRegistry.Register(addonName)
