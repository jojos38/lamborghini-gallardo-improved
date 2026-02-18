local gearIndex = 0

local function onExtensionLoad()
	for i = 1, 6 do
		electrics.values['disp_' .. i] = 0
	end
end

return {
	onExtensionLoad = onExtensionLoad,
	reset = onExtensionLoad,
	updateGFX = function(dt)
		if electrics then
			gearIndex = electrics.values.gearIndex or 0
			for i = 1, 6 do
				electrics.values['disp_' .. i] = gearIndex == i
			end
		end
	end,
}
