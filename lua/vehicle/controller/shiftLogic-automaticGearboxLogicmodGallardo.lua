--- @diagnostic disable: undefined-global

local M = {}

-- Shortcuts
local min, max, abs = math.min, math.max, math.abs
local clamp = function(v, x, y) return min(max(v, x), y) end
local fsign = function(v) return v >= 0 and 1 or -1 end

local constants = { rpmToAV = 0.104719755, avToRPM = 9.549296596425384 }

-- Internal references
local gearbox, engine, torqueConverter = nil, nil, nil
local sharedFunctions, gearboxAvailableLogic, gearboxLogic = nil, nil, nil
local newDesiredGearIndex = 0

-- State
M.currentGearIndex = 0
M.throttle, M.brake, M.clutchRatio = 0, 0, 1
M.isArcadeSwitched, M.isSportModeActive = false, false

M.smoothedAvgAVInput, M.rpm, M.idleRPM, M.maxRPM = 0, 0, 0, 0
M.engineThrottle, M.engineLoad, M.engineTorque, M.flywheelTorque, M.gearboxTorque = 0, 0, 0, 0, 0
M.ignition, M.isEngineRunning = true, 0
M.oilTemp, M.waterTemp, M.checkEngine = 0, 0, false
M.energyStorages = {}

-- Automatic Handling
local automaticHandling = {
	availableModes = { "P", "B", "K", "R", "N", "D", "H", "C", "S", "1", "2", "W", "M" },
	hShifterModeLookup = { [-1] = "R", [0] = "N", "P", "D", "S", "2", "1", "M1" },
	forwardModes = { ["D"]=true, ["S"]=true, ["H"]=true, ["C"]=true, ["1"]=true, ["2"]=true, ["W"]=true, ["M"]=true },
	modes = {}, modeIndexLookup = {}, existingModeLookup = {},
	modeIndex = 0, mode = nil,
	maxGearIndex = 0, minGearIndex = 0,
	autoDownShiftInM = true, autoDownShiftMinGear = 1,
	amtIdleThrottle = 0.01, amtRevMatchThrottle = 0.5, amtRevMatchMinThrottle = 0.5, amtRevMatchMaxThrottle = 1,
	throttleCoefWhileShifting = 1,
	defaultForwardMode = "D"
}

-- Torque Converter Handling
local torqueConverterHandling = {
	lockupAV = 0, lockupRange = 0, lockupThrottleRange = 0,
	lockupMinGear = 0, lockupFullyMinGear = 0,
	lockupIdleCoef = 0, lockupAMTCreep = 0,
	lockupAMTBrakeThreshold = 0.01, lockupAMTRevMargin = 0,
	hasLockup = false, hasTorqueConverter = false
}

-- Utilities
local function safeGearRatio(index)
	if not gearbox.gearRatios or not gearbox.gearRatios[index] then return 1 end
	return gearbox.gearRatios[index]
end

local function getGearName()
	local prefix = ""
	if automaticHandling.mode == "S" then prefix = "S"
	elseif string.sub(automaticHandling.mode, 1, 1) == "M" then prefix = "M" end
	return prefix ~= "" and prefix .. tostring(gearbox.gearIndex) or automaticHandling.mode
end

local function getGearPosition()
	return (automaticHandling.modeIndex - 1) / (#automaticHandling.modes - 1)
end

-- Gearbox mode logic
local function applyGearboxModeRestrictions()
	local minGear, maxGear = gearbox.minGearIndex, gearbox.maxGearIndex
	local manualIndex = tonumber(string.sub(automaticHandling.mode, 2))
	if manualIndex then minGear, maxGear = manualIndex, manualIndex end

	local mode = automaticHandling.mode
	if mode == "1" then minGear, maxGear = 1,1
	elseif mode == "2" then minGear, maxGear = 1,2
	elseif mode == "W" then minGear, maxGear = 2,2
	elseif mode == "K" then minGear, maxGear = automaticHandling.krawlerGearIndex,-1
	elseif mode == "B" then maxGear = automaticHandling.krawlerGearIndex-1
	elseif mode == "C" then minGear, maxGear = 1, automaticHandling.crawlerGearIndex
	elseif mode == "H" then minGear = automaticHandling.crawlerGearIndex+1 end

	automaticHandling.minGearIndex = minGear
	automaticHandling.maxGearIndex = maxGear
end

local function applyGearboxMode()
	local autoIndex = automaticHandling.modeIndexLookup[automaticHandling.mode]
	if autoIndex then
		automaticHandling.modeIndex = clamp(autoIndex, 1, #automaticHandling.modes)
		automaticHandling.mode = automaticHandling.modes[automaticHandling.modeIndex]
	end

	if automaticHandling.mode == "P" then gearbox:setGearIndex(0); gearbox:setMode("park")
	elseif automaticHandling.mode == "N" then gearbox:setGearIndex(0); gearbox:setMode("neutral")
	else
		gearbox:setMode("drive")
		if automaticHandling.mode == "R" then gearbox:setGearIndex(-1)
		elseif gearbox.gearIndex < 1 then gearbox:setGearIndex(1) end
	end

	M.isSportModeActive = automaticHandling.mode == "S"
end

-- Safe shift functions
local function shiftUpDown(isUp)
	local prevMode = automaticHandling.mode
	automaticHandling.modeIndex = isUp and automaticHandling.modeIndex+1 or automaticHandling.modeIndex-1
	automaticHandling.modeIndex = clamp(automaticHandling.modeIndex, 1, #automaticHandling.modes)
	automaticHandling.mode = automaticHandling.modes[automaticHandling.modeIndex]

	if M.gearboxHandling.gearboxSafety then
		local ratio = safeGearRatio(tonumber(string.sub(automaticHandling.mode,2)) or tonumber(automaticHandling.mode) or 0)
		if gearbox.outputAV1 * ratio > engine.maxAV then automaticHandling.mode = prevMode end
	end

	applyGearboxMode()
	applyGearboxModeRestrictions()
end

local function shiftToGearIndex(index)
	local desiredMode = automaticHandling.hShifterModeLookup[index] or "N"
	if not automaticHandling.existingModeLookup[desiredMode] then
		guihooks.message({txt="vehicle.drivetrain.cannotShiftAuto", context={mode=desiredMode}},2,"vehicle.shiftLogic.cannotShift")
		desiredMode = "N"
	end
	automaticHandling.mode = desiredMode
	applyGearboxMode()
	applyGearboxModeRestrictions()
end

-- Exposed Data Update
local function updateExposedData()
	M.rpm = engine and (engine.outputAV1 * constants.avToRPM) or 0
	M.smoothedAvgAVInput = sharedFunctions.updateAvgAVSingleDevice("gearbox")
	M.waterTemp = engine and (engine.thermals and (engine.thermals.coolantTemperature or engine.thermals.oilTemperature)) or 0
	M.oilTemp = engine and (engine.thermals and engine.thermals.oilTemperature) or 0
	M.checkEngine = engine and engine.isDisabled or false
	M.ignition = engine and (engine.ignitionCoef > 0 and not engine.isDisabled) or false
	M.engineThrottle = engine and not engine.isDisabled and M.throttle or 0
	M.engineLoad = engine and not engine.isDisabled and engine.instantEngineLoad or 0
	M.running = engine and not engine.isDisabled or false
	M.engineTorque = engine and engine.combustionTorque or 0
	M.flywheelTorque = engine and engine.outputTorque1 or 0
	M.gearboxTorque = gearbox and gearbox.outputTorque1 or 0
	M.isEngineRunning = engine and ((engine.isStalled or engine.ignitionCoef <= 0) and 0 or 1) or 1
	M.isShifting = gearbox and gearbox.isShifting or false
end

-- Shift and In-Gear Logic (simplified and safer)
local function updateInGear(dt)
	M.throttle, M.brake, M.isArcadeSwitched = M.inputValues.throttle, M.inputValues.brake, false

	local gearIndex = clamp(gearbox.gearIndex, automaticHandling.minGearIndex, automaticHandling.maxGearIndex)
	local engineAV = engine.outputAV1
	local gearboxInputAV, gearboxOutputAV = gearbox.inputAV, gearbox.outputAV1
	local isManualMode = string.sub(automaticHandling.mode,1,1)=="M"
	local isSportMode = automaticHandling.mode=="S"

	-- Auto downshift protection
	if isManualMode and gearIndex>automaticHandling.autoDownShiftMinGear and gearboxInputAV<engine.idleAV and M.shiftPreventionData.wheelSlipShiftDown and automaticHandling.autoDownShiftInM then
		gearIndex = gearIndex - 1
	end

	-- Torque Converter lockup logic
	if torqueConverterHandling.hasTorqueConverter and torqueConverterHandling.hasLockup then
		local lockupTarget = 0
		local revmatch = clamp((M.smoothedValues.drivingAggression-0.2)/0.3,0,1)
		local ratio = safeGearRatio(gearIndex)
		if engineAV < gearboxOutputAV * ratio * (1 - torqueConverterHandling.lockupAMTRevMargin) then
			M.throttle = min(max(automaticHandling.amtRevMatchThrottle*revmatch + automaticHandling.amtRevMatchMinThrottle*(1-revmatch), M.throttle), automaticHandling.amtRevMatchMaxThrottle)
		elseif engineAV > gearboxOutputAV * ratio * (1 + torqueConverterHandling.lockupAMTRevMargin) and engineAV > engine.idleAV*(1+torqueConverterHandling.lockupAMTRevMargin) then
			M.throttle = min(automaticHandling.amtIdleThrottle, M.throttle)
		else
			M.throttle = clamp(M.throttle, 0, automaticHandling.amtRevMatchMaxThrottle)
		end
		electrics.values.lockupClutchRatio = torqueConverterHandling.lockupSmoother:getUncapped(lockupTarget, dt)
	end

	if gearbox.gearIndex ~= gearIndex then
		newDesiredGearIndex = gearIndex
		M.updateGearboxGFX = gearboxLogic.whileShifting
	end

	M.currentGearIndex = gearIndex
	updateExposedData()

	if isManualMode then
		automaticHandling.mode = "M"..gearIndex
		automaticHandling.modeIndex = automaticHandling.modeIndexLookup[automaticHandling.mode]
		applyGearboxModeRestrictions()
	end
end

-- Initialize
local function init(jbeamData, sharedFunctionTable)
	sharedFunctions = sharedFunctionTable
	engine = powertrain.getDevice("mainEngine")
	gearbox = powertrain.getDevice("gearbox")
	torqueConverter = powertrain.getDevice("torqueConverter")
	newDesiredGearIndex = 0

	-- Configure Automatic Modes
	automaticHandling.availableModeLookup = {}
	for _,v in ipairs(automaticHandling.availableModes) do automaticHandling.availableModeLookup[v]=true end
	automaticHandling.modes = {}
	automaticHandling.modeIndexLookup = {}
	automaticHandling.existingModeLookup = {}
	for i=1,#(jbeamData.automaticModes or "PRNDS21M") do
		local mode = (jbeamData.automaticModes or "PRNDS21M"):sub(i,i)
		if automaticHandling.availableModeLookup[mode] then
			if mode=="M" then
				for j=1,gearbox.maxGearIndex do
					local m="M"..j
					automaticHandling.modes[#automaticHandling.modes+1]=m
					automaticHandling.modeIndexLookup[m]=#automaticHandling.modes
					automaticHandling.existingModeLookup[m]=true
				end
			else
				automaticHandling.modes[#automaticHandling.modes+1]=mode
				automaticHandling.modeIndexLookup[mode]=#automaticHandling.modes
				automaticHandling.existingModeLookup[mode]=true
			end
		end
	end

	-- Torque Converter Settings
	if torqueConverter then
		torqueConverterHandling.hasTorqueConverter = true
		torqueConverterHandling.lockupAV = (jbeamData.torqueConverterLockupRPM or 0)*constants.rpmToAV
		torqueConverterHandling.lockupRange = (jbeamData.torqueConverterLockupRange or torqueConverterHandling.lockupAV*0.2)*constants.rpmToAV
		torqueConverterHandling.lockupThrottleRange = (jbeamData.torqueConverterThrottleLockupRange or 0)*constants.rpmToAV
		torqueConverterHandling.hasLockup = torqueConverterHandling.lockupAV>0
		torqueConverterHandling.lockupSmoother = newTemporalSmoothing(jbeamData.torqueConverterLockupRate or 5)
	end

	-- Default Gear
	automaticHandling.mode = automaticHandling.modes[automaticHandling.modeIndexLookup[jbeamData.defaultAutomaticMode or "N"]] or "N"
	automaticHandling.defaultForwardMode = jbeamData.defaultAutomaticForwardMode or "D"
	automaticHandling.maxGearIndex = gearbox.maxGearIndex
	automaticHandling.minGearIndex = gearbox.minGearIndex

	applyGearboxMode()
end

M.init = init
M.shiftUp, M.shiftDown = function() shiftUpDown(true) end, function() shiftUpDown(false) end
M.shiftToGearIndex = shiftToGearIndex
M.updateGearboxGFX = nop
M.getGearName = getGearName
M.getGearPosition = getGearPosition
M.sendTorqueData = function() if engine then engine:sendTorqueData() end end

return M
