--- @diagnostic disable: undefined-global

local M = {}

local max = math.max
local min = math.min
local abs = math.abs
--- Clamps a number between two other numbers.
--- @param v number Value to be clamped.
--- @param x number Minimum value.
--- @param y number Maximum value.
local clamp = function(v, x, y) return min(max(v, x), y) end
--- Returns the sign of a number.
--- @param v number Value to be checked.
local fsign = function(v) return v >= 0 and 1 or -1 end

local constants = { rpmToAV = 0.104719755, avToRPM = 9.549296596425384 }

local newDesiredGearIndex = 0

local gearbox = nil
local engine = nil
local torqueConverter = nil

local sharedFunctions = nil
local gearboxAvailableLogic = nil
local gearboxLogic = nil

M.gearboxHandling = nil
M.timer = nil
M.timerConstants = nil
M.inputValues = nil
M.shiftPreventionData = nil
M.shiftBehavior = nil
M.smoothedValues = nil

M.currentGearIndex = 0
M.throttle = 0
M.brake = 0
M.clutchRatio = 1
M.isArcadeSwitched = false
M.isSportModeActive = false

M.smoothedAvgAVInput = 0
M.rpm = 0
M.idleRPM = 0
M.maxRPM = 0

M.engineThrottle = 0
M.engineLoad = 0
M.engineTorque = 0
M.flywheelTorque = 0
M.gearboxTorque = 0

M.ignition = true
M.isEngineRunning = 0

M.oilTemp = 0
M.waterTemp = 0
M.checkEngine = false

M.energyStorages = {}

local automaticHandling = {
	availableModes = { "P", "B", "K", "R", "N", "D", "H", "C", "S", "1", "2", "W", "M" },
	hShifterModeLookup = { [ -1] = "R",[0] = "N", "P", "D", "S", "2", "1", "M1" },
	forwardModes = { ["D"] = true,["S"] = true,["H"] = true,["C"] = true,["1"] = true,["2"] = true,["W"] = true,["M"] = true }, --mod HCW
	availableModeLookup = {},
	existingModeLookup = {},
	modeIndexLookup = {},
	modes = {},
	mode = nil,
	modeIndex = 0,
	maxAllowedGearIndex = 0,
	minAllowedGearIndex = 0,
	autoDownShiftInM = true,
	autoDownShiftMinGear = 1, --mod
	amtIdleThrottle = 0.01, --mod AMT upshift throttle cut
	amtRevMatchThrottle = 0.50, --mod AMT downshift rev match
	amtRevMatchMinThrottle = 0.50, --mod AMT downshift rev match
	amtRevMatchMaxThrottle = 1, --mod AMT downshift rev match cap
	defaultForwardMode = "D",
	throttleCoefWhileShifting = 1
}

local torqueConverterHandling = {
	lockupAV = 0,
	lockupRange = 0,
	lockupMinGear = 0,
	lockupIdleCoef = 0, --mod modern converter lockup idle speed
	lockupAMTCreep = 0, --mod AMT idle creep
	lockupAMTBrakeThreshold = 0.01, --mod brake disable idle creep
	lockupAMTRevMargin = 0, --mod AMT rev match margin
	lockupFullyMinGear = 0, --mod overdrive lockup
	hasLockup = false
}

local function getGearName()
	local modePrefix = ""
	if automaticHandling.mode == "S" then
		modePrefix = "S"
	elseif string.sub(automaticHandling.mode, 1, 1) == "M" then
		modePrefix = "M"
	end
	return modePrefix ~= "" and modePrefix .. tostring(gearbox.gearIndex) or automaticHandling.mode
end

local function getGearPosition()
	return (automaticHandling.modeIndex - 1) / (#automaticHandling.modes - 1)
end

local function applyGearboxModeRestrictions()
	local manualModeIndex
	if string.sub(automaticHandling.mode, 1, 1) == "M" then
		manualModeIndex = string.sub(automaticHandling.mode, 2)
	end
	local maxGearIndex = gearbox.maxGearIndex
	local minGearIndex = gearbox.minGearIndex
	if automaticHandling.mode == "1" then
		maxGearIndex = 1
		minGearIndex = 1
	elseif automaticHandling.mode == "W" then
		maxGearIndex = 2
		minGearIndex = 2 --mod logic winter mode
	elseif automaticHandling.mode == "K" then
		minGearIndex = automaticHandling.krawlerGearIndex
		maxGearIndex = -1
	elseif automaticHandling.mode == "B" then
		maxGearIndex = automaticHandling.krawlerGearIndex - 1
	elseif automaticHandling.mode == "C" then
		minGearIndex = 1
		maxGearIndex = automaticHandling.crawlerGearIndex
	elseif automaticHandling.mode == "H" then
		minGearIndex = automaticHandling.crawlerGearIndex + 1
		--mod krawler mode
	elseif automaticHandling.mode == "2" then
		maxGearIndex = 2
		minGearIndex = 1
	elseif manualModeIndex then
		maxGearIndex = manualModeIndex
		minGearIndex = manualModeIndex
	end

	automaticHandling.maxGearIndex = maxGearIndex
	automaticHandling.minGearIndex = minGearIndex
end

local function applyGearboxMode()
	local autoIndex = automaticHandling.modeIndexLookup[automaticHandling.mode]
	if autoIndex then
		automaticHandling.modeIndex = min(max(autoIndex, 1), #automaticHandling.modes)
		automaticHandling.mode = automaticHandling.modes[automaticHandling.modeIndex]
	end

	if automaticHandling.mode == "P" then
		gearbox:setGearIndex(0)
		gearbox:setMode("park")
	elseif automaticHandling.mode == "N" then
		gearbox:setGearIndex(0)
		gearbox:setMode("neutral")
	else
		gearbox:setMode("drive")
		if automaticHandling.mode == "R" and gearbox.gearIndex > -1 then
			gearbox:setGearIndex( -1)
		elseif automaticHandling.mode ~= "R" and gearbox.gearIndex < 1 then
			gearbox:setGearIndex(1)
		end
	end

	M.isSportModeActive = automaticHandling.mode == "S"
end

local function gearboxBehaviorChanged(behavior)
	gearboxLogic = gearboxAvailableLogic[behavior]
	M.updateGearboxGFX = gearboxLogic.inGear
	M.shiftUp = gearboxLogic.shiftUp
	M.shiftDown = gearboxLogic.shiftDown
	M.shiftToGearIndex = gearboxLogic.shiftToGearIndex

	if behavior == "arcade" then
		if gearbox.gearIndex > 0 then
			automaticHandling.mode = automaticHandling.defaultForwardMode
			if automaticHandling.mode == "M1" then
				automaticHandling.mode = "M" .. tostring(max(gearbox.gearIndex, 1))
			end
		elseif gearbox.gearIndex < 0 then
			automaticHandling.mode = "R"
		else
			automaticHandling.mode = "N"
		end
	end

	applyGearboxMode()
end

local function setDefaultForwardMode(mode)
	--todo directly set the active mode as well if we are in forward
	automaticHandling.defaultForwardMode = mode
	if automaticHandling.mode == "D" or automaticHandling.mode == "S" or automaticHandling.mode == "1" or automaticHandling.mode == "2" or automaticHandling.mode == "M1" then
		automaticHandling.mode = mode
		applyGearboxMode()
	end
end

local function shiftUp()
	if automaticHandling.mode == "N" then
		M.timer.gearChangeDelayTimer = M.timerConstants.gearChangeDelay
	end

	local previousMode = automaticHandling.mode
	automaticHandling.modeIndex = min(automaticHandling.modeIndex + 1, #automaticHandling.modes)
	automaticHandling.mode = automaticHandling.modes[automaticHandling.modeIndex]

	if automaticHandling.mode == "M1" then --we just shifted into M1
		automaticHandling.mode = "M" .. tostring(max(gearbox.gearIndex, 1))
	end

	if M.gearboxHandling.gearboxSafety then
		local gearRatio = 0
		if string.find(automaticHandling.mode, "M") then
			local gearIndex = tonumber(string.sub(automaticHandling.mode, 2))
			gearRatio = gearbox.gearRatios[gearIndex]
		end
		if tonumber(automaticHandling.mode) then
			local gearIndex = tonumber(automaticHandling.mode)
			gearRatio = gearbox.gearRatios[gearIndex]
		end
		if gearbox.outputAV1 * gearRatio > engine.maxAV then
			automaticHandling.mode = previousMode
		end
	end

	if automaticHandling.mode == "D" or automaticHandling.mode == "R" or automaticHandling.mode == "S" then
		local gearIndex = 1
		local tmpEngineAV = gearbox.outputAV1 * gearbox.gearRatios[gearIndex]

		while tmpEngineAV >= engine.maxAV * 0.9 do
			gearIndex = gearIndex + fsign(gearIndex)
			tmpEngineAV = gearbox.outputAV1 * (gearbox.gearRatios[gearIndex] or 0)
		end
		gearbox:setGearIndex(gearIndex, 0)
	end

	applyGearboxMode()
	applyGearboxModeRestrictions()
end

local function shiftDown()
	if automaticHandling.mode == "N" then
		M.timer.gearChangeDelayTimer = M.timerConstants.gearChangeDelay
	end

	local previousMode = automaticHandling.mode
	automaticHandling.modeIndex = max(automaticHandling.modeIndex - 1, 1)
	automaticHandling.mode = automaticHandling.modes[automaticHandling.modeIndex]

	if previousMode == "M1" and electrics.values.wheelspeed > 2 and M.gearboxHandling.gearboxSafety then
		--we just tried to downshift past M1, something that is irritating while racing, so we disallow this shift unless we are really slow
		automaticHandling.mode = previousMode
	end

	if M.gearboxHandling.gearboxSafety then
		local gearRatio = 0
		if string.find(automaticHandling.mode, "M") then
			local gearIndex = tonumber(string.sub(automaticHandling.mode, 2))
			gearRatio = gearbox.gearRatios[gearIndex]
		end
		if tonumber(automaticHandling.mode) then
			local gearIndex = tonumber(automaticHandling.mode)
			gearRatio = gearbox.gearRatios[gearIndex]
		end
		if gearbox.outputAV1 * gearRatio > engine.maxAV then
			automaticHandling.mode = previousMode
		end
	end

	if automaticHandling.mode == "D" or automaticHandling.mode == "R" or automaticHandling.mode == "S" then
		local gearIndex = 1
		local tmpEngineAV = gearbox.outputAV1 * gearbox.gearRatios[gearIndex]

		while tmpEngineAV >= engine.maxAV * 0.9 do
			gearIndex = gearIndex + fsign(gearIndex)
			tmpEngineAV = gearbox.outputAV1 * (gearbox.gearRatios[gearIndex] or 0)
		end
		gearbox:setGearIndex(gearIndex, 0)
	end

	applyGearboxMode()
	applyGearboxModeRestrictions()
end

local function shiftToGearIndex(index)
	local desiredMode = automaticHandling.hShifterModeLookup[index]
	if not desiredMode or not automaticHandling.existingModeLookup[desiredMode] then
		if desiredMode and not automaticHandling.existingModeLookup[desiredMode] then
			guihooks.message({ txt = "vehicle.drivetrain.cannotShiftAuto", context = { mode = desiredMode } }, 2,
				"vehicle.shiftLogic.cannotShift")
		end
		desiredMode = "N"
	end
	automaticHandling.mode = desiredMode

	if automaticHandling.mode == "D" or automaticHandling.mode == "R" or automaticHandling.mode == "S" then
		local gearIndex = 1
		local tmpEngineAV = gearbox.outputAV1 * gearbox.gearRatios[gearIndex]

		while tmpEngineAV >= engine.maxAV * 0.9 do
			gearIndex = gearIndex + fsign(gearIndex)
			tmpEngineAV = gearbox.outputAV1 * (gearbox.gearRatios[gearIndex] or 0)
		end
		gearbox:setGearIndex(gearIndex, 0)
	end

	applyGearboxMode()
	applyGearboxModeRestrictions()
end

local function updateExposedData()
	M.rpm = engine and (engine.outputAV1 * constants.avToRPM) or 0
	M.smoothedAvgAVInput = sharedFunctions.updateAvgAVSingleDevice("gearbox")
	M.waterTemp = (engine and engine.thermals) and
		(engine.thermals.coolantTemperature and engine.thermals.coolantTemperature or engine.thermals.oilTemperature) or
		0
	M.oilTemp = (engine and engine.thermals) and engine.thermals.oilTemperature or 0
	M.checkEngine = engine and engine.isDisabled or false
	M.ignition = engine and (engine.ignitionCoef > 0 and not engine.isDisabled) or false
	M.engineThrottle = (engine and engine.isDisabled) and 0 or M.throttle
	M.engineLoad = engine and (engine.isDisabled and 0 or engine.instantEngineLoad) or 0
	M.running = engine and not engine.isDisabled or false
	M.engineTorque = engine and engine.combustionTorque or 0
	M.flywheelTorque = engine and engine.outputTorque1 or 0
	M.gearboxTorque = gearbox and gearbox.outputTorque1 or 0
	M.isEngineRunning = engine and ((engine.isStalled or engine.ignitionCoef <= 0) and 0 or 1) or 1
	M.isShifting = gearbox and gearbox.isShifting or false
end

local function updateInGearArcade(dt)
	M.throttle = M.inputValues.throttle
	M.brake = M.inputValues.brake
	M.isArcadeSwitched = false

	local gearIndex = gearbox.gearIndex
	local gearboxInputAV = gearbox.inputAV
	local gearboxOutputAV = gearbox.outputAV1 --mod output lockup
	local engineAV = engine.outputAV1

	-- driving backwards? - only with automatic shift - for obvious reasons ;)
	if (gearIndex < 0 and M.smoothedValues.avgAV <= 0.15) or (gearIndex <= 0 and M.smoothedValues.avgAV < -1) then
		M.throttle, M.brake = M.brake, M.throttle
		M.isArcadeSwitched = true
	end

	--Arcade mode gets a "rev limiter" in case the engine does not have one
	if engineAV > engine.maxAV and not engine.hasRevLimiter then
		local throttleAdjust = min(max((engineAV - engine.maxAV * 1.02) / (engine.maxAV * 0.03), 0), 1)
		M.throttle = min(max(M.throttle - throttleAdjust, 0), 1)
	end

	if M.timer.gearChangeDelayTimer <= 0 and automaticHandling.mode ~= "N" then
		local tmpEngineAV = gearboxInputAV
		local relEngineAV = gearboxInputAV / gearbox.gearRatio

		sharedFunctions.selectShiftPoints(gearIndex)

		local wheelSlipCanShiftDown = M.shiftPreventionData.wheelSlipShiftDown or M.brake <= 0
		while tmpEngineAV < M.shiftBehavior.shiftDownAV and abs(gearIndex) > 1 and wheelSlipCanShiftDown and abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold do
			gearIndex = gearIndex - fsign(gearIndex)
			tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)
			if tmpEngineAV > engine.maxAV * 0.95 then
				tmpEngineAV = relEngineAV / (gearbox.gearRatios[gearIndex] or 0)
				gearIndex = gearIndex + fsign(gearIndex)
				break
			end

			sharedFunctions.selectShiftPoints(gearIndex)
		end

		local wheelSlipCanShiftUp = M.shiftPreventionData.wheelSlipShiftUp or M.throttle <= 0
		--shift up?
		local isRevLimitReached = engine.revLimiterActive and not (engine.isTempRevLimiterActive or false)
		if (tmpEngineAV >= M.shiftBehavior.shiftUpAV or isRevLimitReached) and (M.brake <= 0 or engineAV >= engine.maxAV) and wheelSlipCanShiftUp and abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold and gearIndex < gearbox.maxGearIndex and gearIndex > gearbox.minGearIndex then
			gearIndex = gearIndex + fsign(gearIndex)
			tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)
			if tmpEngineAV < engine.idleAV * 1.1 then
				gearIndex = gearIndex - fsign(gearIndex)
			else
				sharedFunctions.selectShiftPoints(gearIndex)
			end
		end
	end

	if torqueConverterHandling.hasTorqueConverter then
		local lockupTarget = 0
		local revmatchmodifier = clamp((M.smoothedValues.drivingAggression - 0.2) / 0.3, 0, 1) --mod revmatch throttle 0.2 min 0.5 max
		if torqueConverterHandling.hasLockup then
			if torqueConverterHandling.lockupAMTRevMargin > 0 and gearbox.isShifting or (engine.ignitionCoef < 1 or (engine.idleAVStartOffset > 1 and M.throttle <= 0)) then
				lockupTarget = 0
				if (engine.ignitionCoef < 1 or (engine.idleAVStartOffset > 1 and M.throttle <= 0)) then
					M.throttle = M.throttle
				elseif engineAV < gearboxOutputAV * gearbox.gearRatios[gearIndex] * (1 - torqueConverterHandling.lockupAMTRevMargin) then
					M.throttle = min(
							max(
								automaticHandling.amtRevMatchThrottle * revmatchmodifier +
								automaticHandling.amtRevMatchMinThrottle * (1 - revmatchmodifier), M.throttle),
							automaticHandling.amtRevMatchMaxThrottle)
				elseif engineAV > gearboxOutputAV * gearbox.gearRatios[gearIndex] * (1 + torqueConverterHandling.lockupAMTRevMargin) and engineAV > engine.idleAV * (1 + torqueConverterHandling.lockupAMTRevMargin) then
					M.throttle = min(automaticHandling.amtIdleThrottle, M.throttle)
					if (M.smoothedValues.drivingAggression > 0.75 and abs(gearIndex) > 1) and not (isSportMode or isManualMode) then
						engine:cutIgnition(automaticHandling.sportGearChangeTime * 0.5)
					end
				else
					M.throttle = clamp(M.throttle, 0, automaticHandling.amtRevMatchMaxThrottle)
				end
			elseif torqueConverterHandling.lockupAMTRevMargin > 0 and gearIndex >= torqueConverterHandling.lockupFullyMinGear and gearboxInputAV > engine.idleAV * (1 + torqueConverterHandling.lockupAMTRevMargin) then
				lockupTarget = 1
			elseif torqueConverterHandling.lockupAMTRevMargin > 0 then
				lockupTarget = max(
						clamp(
							(max(engineAV, gearboxInputAV) - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) /
							torqueConverterHandling.lockupRange, 0, 1),
						clamp(
							torqueConverterHandling.lockupAMTCreep -
							max(M.brake, input.parkingbrake) * torqueConverterHandling.lockupAMTCreep /
							torqueConverterHandling.lockupAMTBrakeThreshold, 0, torqueConverterHandling.lockupAMTCreep))
				if gearboxInputAV < -1 then
					M.brake = max(M.brake, torqueConverterHandling.lockupAMTBrakeThreshold)
					lockupTarget = clamp(
							(max(engineAV, gearboxInputAV) - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) /
							torqueConverterHandling.lockupRange, 0, 1)
				end
			elseif torqueConverterHandling.lockupIdleCoef > 0 and gearboxInputAV > engine.idleAV * torqueConverterHandling.lockupIdleCoef and M.brake <= 0.25 then
				lockupTarget = clamp(
						(gearboxOutputAV - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) /
						torqueConverterHandling.lockupRange, 0, 1)
			elseif torqueConverterHandling.lockupFullyMinGear > 0 and gearIndex >= torqueConverterHandling.lockupFullyMinGear and gearboxInputAV > engine.idleAV and M.brake <= 0.25 then
				lockupTarget = 1
			elseif torqueConverterHandling.lockupMinGear > 0 and gearIndex >= torqueConverterHandling.lockupMinGear and M.brake <= 0.2 and (not gearbox.isShifting or isSportMode) then
				lockupTarget = clamp(
						(gearboxInputAV - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) /
						torqueConverterHandling.lockupRange, 0, 1)
			elseif torqueConverterHandling.lockupMinGear > 0 and gearIndex >= torqueConverterHandling.lockupMinGear and M.brake <= 0.2 and gearbox.isShifting then
				lockupTarget = clamp(
						clamp(0.5 - M.smoothedValues.drivingAggression, 0, 0.5) *
						((gearboxInputAV - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) / torqueConverterHandling.lockupRange),
						0, 0.5)
			end
		end
		--mod lockup logic
		electrics.values.lockupClutchRatio = torqueConverterHandling.lockupSmoother:getUncapped(lockupTarget, dt)
	end

	-- neutral gear handling
	if abs(gearbox.gearIndex) <= 1 and M.timer.neutralSelectionDelayTimer <= 0 then
		if automaticHandling.mode ~= "P" and abs(M.smoothedValues.avgAV) < M.gearboxHandling.arcadeAutoBrakeAVThreshold and M.throttle <= 0 then
			M.brake = max(M.brake, M.gearboxHandling.arcadeAutoBrakeAmount)
		end

		if automaticHandling.mode ~= "N" and abs(M.smoothedValues.avgAV) < M.gearboxHandling.arcadeAutoBrakeAVThreshold and M.smoothedValues.throttle <= 0 then
			gearIndex = 0
			automaticHandling.mode = "N"
			applyGearboxMode()
		else
			if M.smoothedValues.throttleInput > 0 and M.inputValues.throttle > 0 and M.smoothedValues.brakeInput <= 0 and M.smoothedValues.avgAV > -1 and gearIndex < 1 then
				gearIndex = 1
				M.timer.neutralSelectionDelayTimer = M.timerConstants.neutralSelectionDelay
				automaticHandling.mode = automaticHandling.defaultForwardMode
				applyGearboxMode()
			end

			if M.smoothedValues.brakeInput > 0.1 and M.inputValues.brake > 0 and M.smoothedValues.throttleInput <= 0 and M.smoothedValues.avgAV <= 0.15 and gearIndex > -1 then
				gearIndex = -1
				M.timer.neutralSelectionDelayTimer = M.timerConstants.neutralSelectionDelay
				automaticHandling.mode = "R"
				applyGearboxMode()
			end
		end
	end

	M.throttle = automaticHandling.mode ~= "N" and M.throttle or 0
	M.throttle = gearbox.isShiftingUp and min(M.throttle, automaticHandling.throttleCoefWhileShifting) or M.throttle

	if gearbox.gearIndex ~= gearIndex then
		newDesiredGearIndex = gearIndex
		M.updateGearboxGFX = gearboxLogic.whileShifting
	end

	M.currentGearIndex = gearIndex
	updateExposedData()
end

local function updateWhileShiftingArcade()
	M.throttle = M.inputValues.throttle
	M.brake = M.inputValues.brake
	M.isArcadeSwitched = false

	-- old -> wait -> new -> in gear update
	local gearIndex = gearbox.gearIndex
	if (gearIndex < 0 and M.smoothedValues.avgAV <= 0.15) or (gearIndex <= 0 and M.smoothedValues.avgAV < -1) then
		M.throttle, M.brake = M.brake, M.throttle
		M.isArcadeSwitched = true
	end

	local gearChangeTime = min(
			max(
				automaticHandling.gearChangeTimeRange * (M.smoothedValues.drivingAggression - 0.5) * 2 +
				automaticHandling.maxGearChangeTime, automaticHandling.minGearChangeTime),
			automaticHandling.maxGearChangeTime)
	local autoMode = string.sub(automaticHandling.mode, 1, 1)
	if (autoMode == "S" or autoMode == "M") then
		if abs(newDesiredGearIndex) > 1 and abs(newDesiredGearIndex) > abs(gearbox.gearIndex) and M.throttle > 0 then
			engine:cutIgnition(automaticHandling.sportGearChangeTime * 0.5)
			gearChangeTime = automaticHandling.sportGearChangeTime
		elseif abs(newDesiredGearIndex) > 0 and abs(newDesiredGearIndex) < abs(gearbox.gearIndex) then
			M.throttle = 1
		end
	end
	gearbox:setGearIndex(newDesiredGearIndex, gearChangeTime)
	newDesiredGearIndex = 0
	M.timer.gearChangeDelayTimer = M.timerConstants.gearChangeDelay
	M.updateGearboxGFX = gearboxLogic.inGear
	updateExposedData()
end

local function updateInGear(dt)
	M.throttle = M.inputValues.throttle
	M.brake = M.inputValues.brake
	M.isArcadeSwitched = false

	local gearIndex = gearbox.gearIndex
	local gearboxInputAV = gearbox.inputAV
	local engineAV = engine.outputAV1 --mod AMT clutch use this
	local gearboxOutputAV = gearbox.outputAV1 --mod output lockup

	if M.timer.gearChangeDelayTimer <= 0 and automaticHandling.mode ~= "N" then
		local tmpEngineAV = gearboxInputAV
		local relEngineAV = gearboxInputAV / gearbox.gearRatio

		sharedFunctions.selectShiftPoints(gearIndex)

		local wheelSlipCanShiftDown = M.shiftPreventionData.wheelSlipShiftDown or M.brake <= 0
		--shift down?
		while tmpEngineAV < M.shiftBehavior.shiftDownAV and abs(gearIndex) > 1 and wheelSlipCanShiftDown and abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold do
			gearIndex = gearIndex - fsign(gearIndex)
			tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)
			if tmpEngineAV > engine.maxAV then
				gearIndex = gearIndex + fsign(gearIndex)
				break
			end

			sharedFunctions.selectShiftPoints(gearIndex)
		end

		local wheelSlipCanShiftUp = M.shiftPreventionData.wheelSlipShiftUp or M.throttle <= 0
		--shift up?
		local isRevLimitReached = engine.revLimiterActive and not (engine.isTempRevLimiterActive or false)
		if (tmpEngineAV >= M.shiftBehavior.shiftUpAV or isRevLimitReached) and (M.brake <= 0 or engineAV >= engine.maxAV) and wheelSlipCanShiftUp and abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold and gearIndex < gearbox.maxGearIndex and gearIndex > gearbox.minGearIndex then
			gearIndex = gearIndex + fsign(gearIndex)
			tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)
			if tmpEngineAV < engine.idleAV then
				gearIndex = gearIndex - fsign(gearIndex)
			end

			sharedFunctions.selectShiftPoints(gearIndex)
		end
	end
	local isManualMode = string.sub(automaticHandling.mode, 1, 1) == "M"
	gearIndex = clamp(gearIndex, automaticHandling.minGearIndex, automaticHandling.maxGearIndex)
	if isManualMode and gearIndex > automaticHandling.autoDownShiftMinGear and gearboxInputAV < engine.idleAV and M.shiftPreventionData.wheelSlipShiftDown and automaticHandling.autoDownShiftInM then
		gearIndex = gearIndex - 1
	end
	local isSportMode = automaticHandling.mode == "S"
	if torqueConverterHandling.hasTorqueConverter then
		local lockupTarget = 0
		local revmatchmodifier = clamp((M.smoothedValues.drivingAggression - 0.2) / 0.3, 0, 1) --mod revmatch throttle 0.2 min 0.5 max
		if torqueConverterHandling.hasLockup then
			if torqueConverterHandling.lockupAMTRevMargin > 0 and gearbox.isShifting or (engine.ignitionCoef < 1 or (engine.idleAVStartOffset > 1 and M.throttle <= 0)) then
				lockupTarget = 0
				if (engine.ignitionCoef < 1 or (engine.idleAVStartOffset > 1 and M.throttle <= 0)) then
					M.throttle = M.throttle
				elseif engineAV < gearboxOutputAV * gearbox.gearRatios[gearIndex] * (1 - torqueConverterHandling.lockupAMTRevMargin) then
					if isManualMode then
						M.throttle = min(max(automaticHandling.amtRevMatchThrottle, M.throttle),
								automaticHandling.amtRevMatchMaxThrottle)
					else
						M.throttle = min(
								max(
									automaticHandling.amtRevMatchThrottle * revmatchmodifier +
									automaticHandling.amtRevMatchMinThrottle * (1 - revmatchmodifier), M.throttle),
								automaticHandling.amtRevMatchMaxThrottle)
					end
				elseif engineAV > gearboxOutputAV * gearbox.gearRatios[gearIndex] * (1 + torqueConverterHandling.lockupAMTRevMargin) and engineAV > engine.idleAV * (1 + torqueConverterHandling.lockupAMTRevMargin) then
					M.throttle = min(automaticHandling.amtIdleThrottle, M.throttle)
					if (M.smoothedValues.drivingAggression > 0.75 and abs(gearIndex) > 1) and not (isSportMode or isManualMode) then --mod since we already cut ignition in Sport/Manual mode
						engine:cutIgnition(automaticHandling.sportGearChangeTime * 0.5)
					end
				else
					M.throttle = clamp(M.throttle, 0, automaticHandling.amtRevMatchMaxThrottle)
				end
			elseif torqueConverterHandling.lockupAMTRevMargin > 0 and gearIndex >= torqueConverterHandling.lockupFullyMinGear and gearboxInputAV > engine.idleAV * (1 + torqueConverterHandling.lockupAMTRevMargin) then
				lockupTarget = 1
			elseif torqueConverterHandling.lockupAMTRevMargin > 0 then
				lockupTarget = max(
						clamp(
							(max(engineAV, gearboxInputAV) - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) /
							torqueConverterHandling.lockupRange, 0, 1),
						clamp(
							torqueConverterHandling.lockupAMTCreep -
							max(M.brake, input.parkingbrake) * torqueConverterHandling.lockupAMTCreep /
							torqueConverterHandling.lockupAMTBrakeThreshold, 0, torqueConverterHandling.lockupAMTCreep))
				if gearboxInputAV < -1 then
					M.brake = max(M.brake, torqueConverterHandling.lockupAMTBrakeThreshold - input.parkingbrake)
					lockupTarget = clamp(
							(max(engineAV, gearboxInputAV) - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) /
							torqueConverterHandling.lockupRange, 0, 1)
				end
			elseif torqueConverterHandling.lockupIdleCoef > 0 and gearboxInputAV > engine.idleAV * torqueConverterHandling.lockupIdleCoef and M.brake <= 0.25 then
				lockupTarget = clamp(
						(gearboxOutputAV - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) /
						torqueConverterHandling.lockupRange, 0, 1)
			elseif torqueConverterHandling.lockupFullyMinGear > 0 and gearIndex >= torqueConverterHandling.lockupFullyMinGear and gearboxInputAV > engine.idleAV and M.brake <= 0.25 then
				lockupTarget = 1
			elseif torqueConverterHandling.lockupMinGear > 0 and gearIndex >= torqueConverterHandling.lockupMinGear and M.brake <= 0.2 and (not gearbox.isShifting or isSportMode) then
				lockupTarget = clamp(
						(gearboxInputAV - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) /
						torqueConverterHandling.lockupRange, 0, 1)
			elseif torqueConverterHandling.lockupMinGear > 0 and gearIndex >= torqueConverterHandling.lockupMinGear and M.brake <= 0.2 and gearbox.isShifting then
				lockupTarget = clamp(
						clamp(0.5 - M.smoothedValues.drivingAggression, 0, 0.5) *
						((gearboxInputAV - torqueConverterHandling.lockupThrottleRange * clamp(M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) + torqueConverterHandling.lockupDelayMinThrottle / (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle), 0, 1) - torqueConverterHandling.lockupAV) / torqueConverterHandling.lockupRange),
						0, 0.5)
			end
		end
		--mod lockup logic
		electrics.values.lockupClutchRatio = torqueConverterHandling.lockupSmoother:getUncapped(lockupTarget, dt)
	end

	M.throttle = (gearbox.isShiftingUp and not isSportMode) and
		min(M.throttle, automaticHandling.throttleCoefWhileShifting) or M.throttle

	if gearbox.gearIndex ~= gearIndex then
		newDesiredGearIndex = gearIndex
		M.updateGearboxGFX = gearboxLogic.whileShifting
	end

	M.currentGearIndex = gearIndex
	updateExposedData()

	if isManualMode then
		automaticHandling.mode = "M" .. gearIndex
		automaticHandling.modeIndex = automaticHandling.modeIndexLookup[automaticHandling.mode]
		applyGearboxModeRestrictions()
	end
end

local function updateWhileShifting()
	-- old -> wait -> new -> in gear update
	M.throttle = M.inputValues.throttle
	M.brake = M.inputValues.brake
	M.isArcadeSwitched = false

	local gearChangeTime = min(
			max(
				automaticHandling.gearChangeTimeRange * (M.smoothedValues.drivingAggression - 0.5) * 2 +
				automaticHandling.maxGearChangeTime, automaticHandling.minGearChangeTime),
			automaticHandling.maxGearChangeTime)
	local autoMode = string.sub(automaticHandling.mode, 1, 1)
	if (autoMode == "S" or autoMode == "M") then
		if abs(newDesiredGearIndex) > 1 and abs(newDesiredGearIndex) > abs(gearbox.gearIndex) and M.throttle > 0 then
			engine:cutIgnition(automaticHandling.sportGearChangeTime * 0.5)
			gearChangeTime = automaticHandling.sportGearChangeTime
		elseif abs(newDesiredGearIndex) > 0 and abs(newDesiredGearIndex) < abs(gearbox.gearIndex) then
			M.throttle = 1
		end
	end
	gearbox:setGearIndex(newDesiredGearIndex, gearChangeTime)
	newDesiredGearIndex = 0
	M.timer.gearChangeDelayTimer = M.timerConstants.gearChangeDelay
	M.updateGearboxGFX = gearboxLogic.inGear
	updateExposedData()
end

local function sendTorqueData()
	if engine then
		engine:sendTorqueData()
	end
end

local function init(jbeamData, sharedFunctionTable)
	sharedFunctions = sharedFunctionTable
	engine = powertrain.getDevice("mainEngine")
	gearbox = powertrain.getDevice("gearbox")
	torqueConverter = powertrain.getDevice("torqueConverter")
	newDesiredGearIndex = 0

	M.currentGearIndex = 0
	M.throttle = 0
	M.brake = 0
	M.clutchRatio = 1

	gearboxAvailableLogic = {
		arcade = {
			inGear = updateInGearArcade,
			whileShifting = updateWhileShiftingArcade,
			shiftUp = sharedFunctions.warnCannotShiftSequential,
			shiftDown = sharedFunctions.warnCannotShiftSequential,
			shiftToGearIndex = sharedFunctions.switchToRealisticBehavior
		},
		realistic = {
			inGear = updateInGear,
			whileShifting = updateWhileShifting,
			shiftUp = shiftUp,
			shiftDown = shiftDown,
			shiftToGearIndex = shiftToGearIndex
		}
	}

	automaticHandling.availableModeLookup = {}
	for _, v in pairs(automaticHandling.availableModes) do
		automaticHandling.availableModeLookup[v] = true
	end

	automaticHandling.modes = {}
	automaticHandling.modeIndexLookup = {}
	local modes = jbeamData.automaticModes or "PRNDS21M"
	local modeCount = #modes
	local modeOffset = 0
	local forwardModes = {}
	for i = 1, modeCount do
		local mode = modes:sub(i, i)
		if automaticHandling.availableModeLookup[mode] then
			if automaticHandling.forwardModes[mode] then
				table.insert(forwardModes, mode)
			end
			if mode ~= "M" then
				automaticHandling.modes[i + modeOffset] = mode
				automaticHandling.modeIndexLookup[mode] = i + modeOffset
				automaticHandling.existingModeLookup[mode] = true
			else
				for j = 1, gearbox.maxGearIndex, 1 do
					local manualMode = "M" .. tostring(j)
					local manualModeIndex = i + j - 1
					automaticHandling.modes[manualModeIndex] = manualMode
					automaticHandling.modeIndexLookup[manualMode] = manualModeIndex
					automaticHandling.existingModeLookup[manualMode] = true
					modeOffset = j - 1
				end
			end
		else
			print("unknown auto mode: " .. mode)
		end
	end

	if torqueConverter then
		torqueConverterHandling.hasTorqueConverter = true
		torqueConverterHandling.lockupAV = (jbeamData.torqueConverterLockupRPM or 0) * constants.rpmToAV
		torqueConverterHandling.lockupRange = (jbeamData.torqueConverterLockupRange or (torqueConverterHandling.lockupAV * 0.2 * constants.avToRPM)) *
			constants.rpmToAV
		torqueConverterHandling.lockupThrottleRange = (jbeamData.torqueConverterThrottleLockupRange or 0) *
			constants.rpmToAV
		--mod delay torqueConverterLockup with throttle application
		torqueConverterHandling.lockupDelayMinThrottle = jbeamData.torqueConverterDelayLockupMinThrottle or 0
		--mod no lockup delay below this throttle value
		torqueConverterHandling.lockupDelayMaxThrottle = jbeamData.torqueConverterDelayLockupMaxThrottle or 1
		--mod max lockup delay above this throttle value
		torqueConverterHandling.lockupMinGear = jbeamData.torqueConverterLockupMinGear or 0
		torqueConverterHandling.lockupFullyMinGear = jbeamData.torqueConverterLockupFullyMinGear or
			0 --mod overdrive always lock TC
		torqueConverterHandling.hasLockup = torqueConverterHandling.lockupAV > 0
		torqueConverterHandling.lockupIdleCoef = jbeamData.torqueConverterlockupIdleCoef or
			0 --mod output speed lock stall prevention
		torqueConverterHandling.lockupAMTRevMargin = jbeamData.torqueConverterAMTRevMargin or
			0 --mod AMT rev match margin
		torqueConverterHandling.lockupAMTCreep = jbeamData.torqueConverterAMTCreep or 0 --mod AMT idle creep
		torqueConverterHandling.lockupAMTBrakeThreshold = jbeamData.torqueConverterAMTBrakeThreshold or
			0.01 --mod AMT this amount of brake disable idle creep
		local lockupRate = jbeamData.torqueConverterLockupRate or 5
		local lockupInRate = jbeamData.torqueConverterLockupInRate or lockupRate * 2
		local lockupOutRate = jbeamData.torqueConverterLockupOutRate or lockupRate
		torqueConverterHandling.lockupSmoother = newTemporalSmoothing(lockupInRate, lockupOutRate)
	end

	local defaultMode = jbeamData.defaultAutomaticMode or "N"
	local defaultForwardMode = jbeamData.defaultAutomaticForwardMode or forwardModes[1] or "D"
	if defaultMode == "M" then
		defaultMode = "M1"
	end
	if defaultForwardMode == "M" then
		defaultForwardMode = "M1"
	end
	if not automaticHandling.existingModeLookup[defaultMode] then
		defaultMode = "D"
	end

	automaticHandling.modeIndex = automaticHandling.modeIndexLookup[defaultMode]
	automaticHandling.defaultForwardMode = defaultForwardMode
	automaticHandling.mode = automaticHandling.modes[automaticHandling.modeIndex]
	automaticHandling.maxGearIndex = gearbox.maxGearIndex
	automaticHandling.minGearIndex = gearbox.minGearIndex
	automaticHandling.krawlerGearIndex = jbeamData.krawlerGearIndex or -2 --mod krawler gear
	automaticHandling.crawlerGearIndex = jbeamData.crawlerGearIndex or 2 --mod crawler gear
	automaticHandling.maxGearChangeTime = jbeamData.maxGearChangeTime or 0
	automaticHandling.minGearChangeTime = jbeamData.minGearChangeTime or 0
	automaticHandling.sportGearChangeTime = jbeamData.sportGearChangeTime or 0
	automaticHandling.gearChangeTimeRange = automaticHandling.minGearChangeTime - automaticHandling.maxGearChangeTime
	automaticHandling.autoDownShiftInM = jbeamData.autoDownShiftInM == nil and true or jbeamData.autoDownShiftInM
	automaticHandling.autoDownShiftMinGear = jbeamData.autoDownShiftMinGear or 1 --mod
	automaticHandling.throttleCoefWhileShifting = jbeamData.throttleCoefWhileShifting or 1
	automaticHandling.amtIdleThrottle = jbeamData.amtIdleThrottle or 0.01 --mod AMT upshift throttle cut
	automaticHandling.amtRevMatchThrottle = jbeamData.amtRevMatchThrottle or 0.5 --mod AMT downshift rev match
	automaticHandling.amtRevMatchMinThrottle = jbeamData.amtRevMatchMinThrottle or
		automaticHandling.amtRevMatchThrottle --mod AMT downshift rev match
	automaticHandling.amtRevMatchMaxThrottle = jbeamData.amtRevMatchMaxThrottle or 1 --mod AMT downshift rev match
	M.maxRPM = engine.maxRPM
	M.idleRPM = engine.idleRPM
	M.maxGearIndex = automaticHandling.maxGearIndex
	local minGearIndex = select(2, pcall(abs, automaticHandling.minGearIndex))
	if type(minGearIndex) == "number" then
		M.minGearIndex = minGearIndex
	end
	M.energyStorages = sharedFunctions.getEnergyStorages({ engine })
	applyGearboxMode()
end

M.init = init

M.gearboxBehaviorChanged = gearboxBehaviorChanged
M.shiftUp = shiftUp
M.shiftDown = shiftDown
M.shiftToGearIndex = shiftToGearIndex
M.updateGearboxGFX = nop
M.getGearName = getGearName
M.getGearPosition = getGearPosition
M.setDefaultForwardMode = setDefaultForwardMode
M.sendTorqueData = sendTorqueData

return M
