---@diagnostic disable: lowercase-global

---@class GallardoRainTexture
local M = {}

---@type table
local htmlTexture = require("htmlTexture")
---@type table
local environment = getfenv(0)

---@type fun(...)
local log = environment.log
---@type fun(...)
local dump = environment.dump
---@type fun(...)
local nop = environment.nop

---Initializes the rain texture for the Gallardo.
---@param jbeamData table The jbeam data containing rain texture info
function M.init(jbeamData)
	---@type string?
	local gaugesScreenName = jbeamData.materialName
	---@type string?
	local htmlPath = jbeamData.htmlPath
	---@type integer
	local width = jbeamData.textureWidth or 1920
	---@type integer
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
