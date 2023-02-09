--- @diagnostic disable: lowercase-global

local M = {}
local htmlTexture = require("htmlTexture")
local environment = getfenv(0)

--- @type function
local log = environment.log
--- @type function
local dump = environment.dump
--- @type function
local nop = environment.nop

--- Initializes the rain texture for the Gallardo.
--- @param jbeamData table The jbeam data for the rain texture.
function M.init(jbeamData)
	gaugesScreenName = jbeamData.materialName
	htmlPath = jbeamData.htmlPath
	local width = jbeamData.textureWidth or 1920
	local height = jbeamData.textureHeight or 1920
	dump(jbeamData)
	if not gaugesScreenName then
		M.updateGFX = nop
		pcall(log, "E", "fs65transhtml", "No material name specified")
	elseif htmlPath then
		htmlTexture.create(gaugesScreenName, htmlPath, width, height, 60, "automatic")
	else
		M.updateGFX = nop
		pcall(log, "E", "fs65transhtml", "No html path specified")
	end
end

return M
