-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local gear_A = 0
local gearIndex = 0

local function onInit()
  electrics.values['disp_1'] = 0
  electrics.values['disp_2'] = 0
  electrics.values['disp_3'] = 0
  electrics.values['disp_4'] = 0
  electrics.values['disp_5'] = 0
  electrics.values['disp_6'] = 0
end

local function reset()
  onInit()
end

local function updateGFX(dt)
	if not electrics then return end
	gearIndex = electrics.values.gearIndex or 0
	electrics.values['disp_1'] = gearIndex == 1
	electrics.values['disp_2'] = gearIndex == 2
	electrics.values['disp_3'] = gearIndex == 3
	electrics.values['disp_4'] = gearIndex == 4
	electrics.values['disp_5'] = gearIndex == 5
	electrics.values['disp_6'] = gearIndex == 6
end

-- public interface
M.onInit    = onInit
M.reset   = reset
M.updateGFX = updateGFX

return M