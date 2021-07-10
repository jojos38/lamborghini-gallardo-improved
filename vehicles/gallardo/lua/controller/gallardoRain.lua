-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local htmlTexture = require("htmlTexture")
local updateFPS = 60

local function updateGFX(dt)

end

local function init(jbeamData)
	gaugesScreenName = jbeamData.materialName
	htmlPath = jbeamData.htmlPath
	local width = jbeamData.textureWidth or 1920
	local height = jbeamData.textureHeight or 1920
	dump(jbeamData)
	if not gaugesScreenName then
		log("E", "fs65transhtml", "Got no material name for the texture, can't display anything...")
		M.updateGFX = nop
	else
		if htmlPath then
			htmlTexture.create(gaugesScreenName, htmlPath, width, height, updateFPS, "automatic")
			-- htmlTexture.call(gaugesScreenName, "setGearFromLua", {value="N"})
		else
			log("E", "fs65transhtml", "Got no html path for the texture, can't display anything...")
			M.updateGFX = nop
		end
	end
end


M.init = init
M.updateGFX = updateGFX

return M
