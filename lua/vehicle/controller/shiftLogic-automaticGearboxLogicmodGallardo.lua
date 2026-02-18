local M = {}

local max, min, abs = math.max, math.min, math.abs
local clamp = function(v, x, y) return min(max(v, x), y) end
local fsign = function(v) return v >= 0 and 1 or -1 end

local constants = { rpmToAV = 0.104719755, avToRPM = 9.549296596425384 }

local newDesiredGearIndex = 0

local gearbox, engine, torqueConverter = nil, nil, nil
local sharedFunctions, gearboxAvailableLogic, gearboxLogic = nil, nil, nil

M.gearboxHandling, M.timer, M.timerConstants, M.inputValues, M.shiftPreventionData, M.shiftBehavior, M.smoothedValues = nil, nil, nil, nil, nil, nil, nil

M.currentGearIndex, M.throttle, M.brake, M.clutchRatio = 0, 0, 0, 1
M.isArcadeSwitched, M.isSportModeActive = false, false

M.smoothedAvgAVInput, M.rpm, M.idleRPM, M.maxRPM = 0, 0, 0, 0
M.engineThrottle, M.engineLoad, M.engineTorque, M.flywheelTorque, M.gearboxTorque = 0, 0, 0, 0, 0

M.ignition = true
M.isEngineRunning = 0
M.oilTemp, M.waterTemp = 0, 0
M.checkEngine = false

M.energyStorages = {}

local automaticHandling = {
	availableModes = { "P", "B", "K", "R", "N", "D", "H", "C", "S", "1", "2", "W", "M" },
	hShifterModeLookup = { [-1] = "R", [0] = "N", "P", "D", "S", "2", "1", "M1" },
	forwardModes = { ["D"] = true, ["S"] = true, ["H"] = true, ["C"] = true, ["1"] = true, ["2"] = true, ["W"] = true, ["M"] = true },
	availableModeLookup = {},
	existingModeLookup = {},
	modeIndexLookup = {},
	modes = {},
	mode = nil,
	modeIndex = 0,
	maxAllowedGearIndex = 0,
	minAllowedGearIndex = 0,
	autoDownShiftInM = true,
	autoDownShiftMinGear = 1,
	amtIdleThrottle = 0.01,
	amtRevMatchThrottle = 0.5,
	amtRevMatchMinThrottle = 0.5,
	amtRevMatchMaxThrottle = 1,
	defaultForwardMode = "D",
	throttleCoefWhileShifting = 1
}

local torqueConverterHandling = {
	lockupAV = 0,
	lockupRange = 0,
	lockupMinGear = 0,
	lockupIdleCoef = 0,
	lockupAMTCreep = 0,
	lockupAMTBrakeThreshold = 0.01,
	lockupAMTRevMargin = 0,
	lockupFullyMinGear = 0,
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

	local maxGearIndex, minGearIndex = gearbox.maxGearIndex, gearbox.minGearIndex

	if automaticHandling.mode == "1" then
		maxGearIndex, minGearIndex = 1, 1
	elseif automaticHandling.mode == "W" then
		maxGearIndex, minGearIndex = 2, 2
	elseif automaticHandling.mode == "K" then
		minGearIndex, maxGearIndex = automaticHandling.krawlerGearIndex, -1
	elseif automaticHandling.mode == "B" then
		maxGearIndex = automaticHandling.krawlerGearIndex - 1
	elseif automaticHandling.mode == "C" then
		minGearIndex, maxGearIndex = 1, automaticHandling.crawlerGearIndex
	elseif automaticHandling.mode == "H" then
		minGearIndex = automaticHandling.crawlerGearIndex + 1
	elseif automaticHandling.mode == "2" then
		maxGearIndex, minGearIndex = 2, 1
	elseif manualModeIndex then
		maxGearIndex, minGearIndex = manualModeIndex, manualModeIndex
	end

	automaticHandling.maxGearIndex, automaticHandling.minGearIndex = maxGearIndex, minGearIndex
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
			gearbox:setGearIndex(-1)
		elseif automaticHandling.mode ~= "R" and gearbox.gearIndex < 1 then
			gearbox:setGearIndex(1)
		end
	end

	M.isSportModeActive = automaticHandling.mode == "S"
end

local function gearboxBehaviorChanged(behavior)
	gearboxLogic = gearboxAvailableLogic[behavior]

	M.updateGearboxGFX, M.shiftUp, M.shiftDown, M.shiftToGearIndex =
		gearboxLogic.inGear, gearboxLogic.shiftUp, gearboxLogic.shiftDown, gearboxLogic.shiftToGearIndex

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

    if automaticHandling.mode == "M1" then
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
            guihooks.message(
                { txt = "vehicle.drivetrain.cannotShiftAuto", context = { mode = desiredMode } },
                2,
                "vehicle.shiftLogic.cannotShift"
            )
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
    M.rpm                = engine and (engine.outputAV1 * constants.avToRPM) or 0
    M.smoothedAvgAVInput = sharedFunctions.updateAvgAVSingleDevice("gearbox")
    
    M.waterTemp = (engine and engine.thermals) and
                  (engine.thermals.coolantTemperature or engine.thermals.oilTemperature) or 0

    M.oilTemp          = (engine and engine.thermals) and engine.thermals.oilTemperature or 0
    M.checkEngine      = engine and engine.isDisabled or false
    M.ignition         = engine and (engine.ignitionCoef > 0 and not engine.isDisabled) or false
    M.engineThrottle   = (engine and engine.isDisabled) and 0 or M.throttle
    M.engineLoad       = engine and (engine.isDisabled and 0 or engine.instantEngineLoad) or 0
    M.running          = engine and not engine.isDisabled or false
    M.engineTorque     = engine and engine.combustionTorque or 0
    M.flywheelTorque   = engine and engine.outputTorque1 or 0
    M.gearboxTorque    = gearbox and gearbox.outputTorque1 or 0
    M.isEngineRunning  = engine and ((engine.isStalled or engine.ignitionCoef <= 0) and 0 or 1) or 1
    M.isShifting       = gearbox and gearbox.isShifting or false
end

local function updateInGearArcade(dt)
    M.throttle          = M.inputValues.throttle
    M.brake             = M.inputValues.brake
    M.isArcadeSwitched  = false

    local gearIndex       = gearbox.gearIndex
    local gearboxInputAV  = gearbox.inputAV
    local gearboxOutputAV = gearbox.outputAV1
    local engineAV       = engine.outputAV1

    -- Driving backwards? Only with automatic shift
    if (gearIndex < 0 and M.smoothedValues.avgAV <= 0.15) or (gearIndex <= 0 and M.smoothedValues.avgAV < -1) then
        M.throttle, M.brake = M.brake, M.throttle
        M.isArcadeSwitched  = true
    end

    -- Arcade mode rev limiter
    if engineAV > engine.maxAV and not engine.hasRevLimiter then
        local throttleAdjust = clamp(
            (engineAV - engine.maxAV * 1.02) / (engine.maxAV * 0.03),
            0,
            1
        )
        M.throttle = clamp(M.throttle - throttleAdjust, 0, 1)
    end

    -- Automatic shifting logic
    if M.timer.gearChangeDelayTimer <= 0 and automaticHandling.mode ~= "N" then
        local tmpEngineAV  = gearboxInputAV
        local relEngineAV  = gearboxInputAV / gearbox.gearRatio

        sharedFunctions.selectShiftPoints(gearIndex)

        local wheelSlipCanShiftDown = M.shiftPreventionData.wheelSlipShiftDown or M.brake <= 0

        while tmpEngineAV < M.shiftBehavior.shiftDownAV and abs(gearIndex) > 1 and wheelSlipCanShiftDown
              and abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold do
            gearIndex  = gearIndex - fsign(gearIndex)
            tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)

            if tmpEngineAV > engine.maxAV * 0.95 then
                tmpEngineAV = relEngineAV / (gearbox.gearRatios[gearIndex] or 0)
                gearIndex  = gearIndex + fsign(gearIndex)
                break
            end

            sharedFunctions.selectShiftPoints(gearIndex)
        end

        local wheelSlipCanShiftUp = M.shiftPreventionData.wheelSlipShiftUp or M.throttle <= 0
        local isRevLimitReached   = engine.revLimiterActive and not (engine.isTempRevLimiterActive or false)

        if (tmpEngineAV >= M.shiftBehavior.shiftUpAV or isRevLimitReached)
           and (M.brake <= 0 or engineAV >= engine.maxAV)
           and wheelSlipCanShiftUp
           and abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold
           and gearIndex < gearbox.maxGearIndex
           and gearIndex > gearbox.minGearIndex then
            gearIndex  = gearIndex + fsign(gearIndex)
            tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)

            if tmpEngineAV < engine.idleAV * 1.1 then
                gearIndex = gearIndex - fsign(gearIndex)
            else
                sharedFunctions.selectShiftPoints(gearIndex)
            end
        end
    end

    -- Torque converter lockup logic
    if torqueConverterHandling.hasTorqueConverter then
        local lockupTarget      = 0
        local revmatchmodifier  = clamp((M.smoothedValues.drivingAggression - 0.2) / 0.3, 0, 1)

        if torqueConverterHandling.hasLockup then
            -- lockup control logic
            if torqueConverterHandling.lockupAMTRevMargin > 0
               and (gearbox.isShifting or engine.ignitionCoef < 1 or (engine.idleAVStartOffset > 1 and M.throttle <= 0)) then

                lockupTarget = 0

                if engineAV < gearboxOutputAV * gearbox.gearRatios[gearIndex] * (1 - torqueConverterHandling.lockupAMTRevMargin) then
                    M.throttle = min(
                        max(
                            automaticHandling.amtRevMatchThrottle * revmatchmodifier +
                            automaticHandling.amtRevMatchMinThrottle * (1 - revmatchmodifier),
                            M.throttle
                        ),
                        automaticHandling.amtRevMatchMaxThrottle
                    )

                elseif engineAV > gearboxOutputAV * gearbox.gearRatios[gearIndex] * (1 + torqueConverterHandling.lockupAMTRevMargin)
                       and engineAV > engine.idleAV * (1 + torqueConverterHandling.lockupAMTRevMargin) then
                    M.throttle = min(automaticHandling.amtIdleThrottle, M.throttle)

                else
                    M.throttle = clamp(M.throttle, 0, automaticHandling.amtRevMatchMaxThrottle)
                end

            elseif torqueConverterHandling.lockupAMTRevMargin > 0
                   and gearIndex >= torqueConverterHandling.lockupFullyMinGear
                   and gearboxInputAV > engine.idleAV * (1 + torqueConverterHandling.lockupAMTRevMargin) then
                lockupTarget = 1
            end
        end

        electrics.values.lockupClutchRatio = torqueConverterHandling.lockupSmoother:getUncapped(lockupTarget, dt)
    end

    -- Neutral gear handling
    if abs(gearbox.gearIndex) <= 1 and M.timer.neutralSelectionDelayTimer <= 0 then
        if automaticHandling.mode ~= "P"
           and abs(M.smoothedValues.avgAV) < M.gearboxHandling.arcadeAutoBrakeAVThreshold
           and M.throttle <= 0 then
            M.brake = max(M.brake, M.gearboxHandling.arcadeAutoBrakeAmount)
        end

        if automaticHandling.mode ~= "N"
           and abs(M.smoothedValues.avgAV) < M.gearboxHandling.arcadeAutoBrakeAVThreshold
           and M.smoothedValues.throttle <= 0 then
            gearIndex = 0
            automaticHandling.mode = "N"
            applyGearboxMode()
        else
            if M.smoothedValues.throttleInput > 0 and M.inputValues.throttle > 0
               and M.smoothedValues.brakeInput <= 0 and M.smoothedValues.avgAV > -1 and gearIndex < 1 then
                gearIndex = 1
                M.timer.neutralSelectionDelayTimer = M.timerConstants.neutralSelectionDelay
                automaticHandling.mode = automaticHandling.defaultForwardMode
                applyGearboxMode()
            end

            if M.smoothedValues.brakeInput > 0.1 and M.inputValues.brake > 0
               and M.smoothedValues.throttleInput <= 0 and M.smoothedValues.avgAV <= 0.15 and gearIndex > -1 then
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
        M.updateGearboxGFX  = gearboxLogic.whileShifting
    end

    M.currentGearIndex = gearIndex
    updateExposedData()
end

local function updateWhileShiftingArcade()
    M.throttle         = M.inputValues.throttle
    M.brake            = M.inputValues.brake
    M.isArcadeSwitched = false

    -- Handle reverse swap in arcade mode
    local gearIndex = gearbox.gearIndex
    if (gearIndex < 0 and M.smoothedValues.avgAV <= 0.15) or (gearIndex <= 0 and M.smoothedValues.avgAV < -1) then
        M.throttle, M.brake = M.brake, M.throttle
        M.isArcadeSwitched  = true
    end

    -- Determine gear change time based on aggression
    local gearChangeTime = min(
        max(
            automaticHandling.gearChangeTimeRange * (M.smoothedValues.drivingAggression - 0.5) * 2 +
            automaticHandling.maxGearChangeTime,
            automaticHandling.minGearChangeTime
        ),
        automaticHandling.maxGearChangeTime
    )

    -- Sport/Manual mode adjustments
    local autoMode = string.sub(automaticHandling.mode, 1, 1)
    if autoMode == "S" or autoMode == "M" then
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
    M.updateGearboxGFX          = gearboxLogic.inGear

    updateExposedData()
end

local function updateInGear(dt)
    M.throttle         = M.inputValues.throttle
    M.brake            = M.inputValues.brake
    M.isArcadeSwitched = false

    local gearIndex       = gearbox.gearIndex
    local gearboxInputAV  = gearbox.inputAV
    local engineAV        = engine.outputAV1        -- mod AMT clutch use this
    local gearboxOutputAV = gearbox.outputAV1       -- mod output lockup

    if M.timer.gearChangeDelayTimer <= 0 and automaticHandling.mode ~= "N" then
        local tmpEngineAV = gearboxInputAV
        local relEngineAV = gearboxInputAV / gearbox.gearRatio

        sharedFunctions.selectShiftPoints(gearIndex)

        local wheelSlipCanShiftDown = M.shiftPreventionData.wheelSlipShiftDown or M.brake <= 0
        -- shift down?
        while tmpEngineAV < M.shiftBehavior.shiftDownAV and abs(gearIndex) > 1 and wheelSlipCanShiftDown and
              abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold do

            gearIndex   = gearIndex - fsign(gearIndex)
            tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)

            if tmpEngineAV > engine.maxAV then
                gearIndex = gearIndex + fsign(gearIndex)
                break
            end

            sharedFunctions.selectShiftPoints(gearIndex)
        end

        local wheelSlipCanShiftUp = M.shiftPreventionData.wheelSlipShiftUp or M.throttle <= 0
        local isRevLimitReached   = engine.revLimiterActive and not (engine.isTempRevLimiterActive or false)

        -- shift up?
        if (tmpEngineAV >= M.shiftBehavior.shiftUpAV or isRevLimitReached) and
           (M.brake <= 0 or engineAV >= engine.maxAV) and
           wheelSlipCanShiftUp and
           abs(M.throttle - M.smoothedValues.throttle) < M.smoothedValues.throttleUpShiftThreshold and
           gearIndex < gearbox.maxGearIndex and
           gearIndex > gearbox.minGearIndex then

            gearIndex   = gearIndex + fsign(gearIndex)
            tmpEngineAV = relEngineAV * (gearbox.gearRatios[gearIndex] or 0)

            if tmpEngineAV < engine.idleAV then
                gearIndex = gearIndex - fsign(gearIndex)
            end

            sharedFunctions.selectShiftPoints(gearIndex)
        end
    end

    local isManualMode = string.sub(automaticHandling.mode, 1, 1) == "M"
    gearIndex = clamp(gearIndex, automaticHandling.minGearIndex, automaticHandling.maxGearIndex)

    if isManualMode and
       gearIndex > automaticHandling.autoDownShiftMinGear and
       gearboxInputAV < engine.idleAV and
       M.shiftPreventionData.wheelSlipShiftDown and
       automaticHandling.autoDownShiftInM then
        gearIndex = gearIndex - 1
    end

    local isSportMode = automaticHandling.mode == "S"

    if torqueConverterHandling.hasTorqueConverter then
        local lockupTarget      = 0
        local revmatchmodifier  = clamp((M.smoothedValues.drivingAggression - 0.2) / 0.3, 0, 1)

        if torqueConverterHandling.hasLockup then
            -- complex lockup logic
            if torqueConverterHandling.lockupAMTRevMargin > 0 and gearbox.isShifting or
               (engine.ignitionCoef < 1 or (engine.idleAVStartOffset > 1 and M.throttle <= 0)) then

                lockupTarget = 0
                if engineAV < gearboxOutputAV * gearbox.gearRatios[gearIndex] * (1 - torqueConverterHandling.lockupAMTRevMargin) then
                    if isManualMode then
                        M.throttle = min(
                            max(automaticHandling.amtRevMatchThrottle, M.throttle),
                            automaticHandling.amtRevMatchMaxThrottle
                        )
                    else
                        M.throttle = min(
                            max(
                                automaticHandling.amtRevMatchThrottle * revmatchmodifier +
                                automaticHandling.amtRevMatchMinThrottle * (1 - revmatchmodifier),
                                M.throttle
                            ),
                            automaticHandling.amtRevMatchMaxThrottle
                        )
                    end

                elseif engineAV > gearboxOutputAV * gearbox.gearRatios[gearIndex] * (1 + torqueConverterHandling.lockupAMTRevMargin) and
                       engineAV > engine.idleAV * (1 + torqueConverterHandling.lockupAMTRevMargin) then

                    M.throttle = min(automaticHandling.amtIdleThrottle, M.throttle)

                    if M.smoothedValues.drivingAggression > 0.75 and abs(gearIndex) > 1 and not (isSportMode or isManualMode) then
                        engine:cutIgnition(automaticHandling.sportGearChangeTime * 0.5)
                    end

                else
                    M.throttle = clamp(M.throttle, 0, automaticHandling.amtRevMatchMaxThrottle)
                end

            elseif torqueConverterHandling.lockupAMTRevMargin > 0 and
                   gearIndex >= torqueConverterHandling.lockupFullyMinGear and
                   gearboxInputAV > engine.idleAV * (1 + torqueConverterHandling.lockupAMTRevMargin) then
                lockupTarget = 1

            else
                -- fallback lockup calculation
                lockupTarget = max(
                    clamp(
                        (max(engineAV, gearboxInputAV) -
                         torqueConverterHandling.lockupThrottleRange *
                         clamp(
                             M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) +
                             torqueConverterHandling.lockupDelayMinThrottle /
                             (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle),
                             0, 1
                         ) - torqueConverterHandling.lockupAV) /
                        torqueConverterHandling.lockupRange, 0, 1
                    ),
                    clamp(
                        torqueConverterHandling.lockupAMTCreep -
                        max(M.brake, input.parkingbrake) *
                        torqueConverterHandling.lockupAMTCreep /
                        torqueConverterHandling.lockupAMTBrakeThreshold,
                        0,
                        torqueConverterHandling.lockupAMTCreep
                    )
                )

                if gearboxInputAV < -1 then
                    M.brake = max(M.brake, torqueConverterHandling.lockupAMTBrakeThreshold - input.parkingbrake)
                    lockupTarget = clamp(
                        (max(engineAV, gearboxInputAV) -
                         torqueConverterHandling.lockupThrottleRange *
                         clamp(
                             M.throttle / (torqueConverterHandling.lockupDelayMaxThrottle - torqueConverterHandling.lockupDelayMinThrottle) +
                             torqueConverterHandling.lockupDelayMinThrottle /
                             (torqueConverterHandling.lockupDelayMinThrottle - torqueConverterHandling.lockupDelayMaxThrottle),
                             0, 1
                         ) - torqueConverterHandling.lockupAV) /
                        torqueConverterHandling.lockupRange, 0, 1
                    )
                end
            end
        end

        electrics.values.lockupClutchRatio = torqueConverterHandling.lockupSmoother:getUncapped(lockupTarget, dt)
    end

    -- throttle limit during upshift
    M.throttle = (gearbox.isShiftingUp and not isSportMode) and
                 min(M.throttle, automaticHandling.throttleCoefWhileShifting) or M.throttle

    if gearbox.gearIndex ~= gearIndex then
        newDesiredGearIndex  = gearIndex
        M.updateGearboxGFX   = gearboxLogic.whileShifting
    end

    M.currentGearIndex = gearIndex
    updateExposedData()

    if isManualMode then
        automaticHandling.mode      = "M" .. gearIndex
        automaticHandling.modeIndex = automaticHandling.modeIndexLookup[automaticHandling.mode]
        applyGearboxModeRestrictions()
    end
end

local function updateWhileShifting()
    -- old -> wait -> new -> in-gear update
    M.throttle         = M.inputValues.throttle
    M.brake            = M.inputValues.brake
    M.isArcadeSwitched = false

    local gearChangeTime = min(
        max(
            automaticHandling.gearChangeTimeRange * (M.smoothedValues.drivingAggression - 0.5) * 2 +
            automaticHandling.maxGearChangeTime,
            automaticHandling.minGearChangeTime
        ),
        automaticHandling.maxGearChangeTime
    )

    local autoMode = string.sub(automaticHandling.mode, 1, 1)

    if autoMode == "S" or autoMode == "M" then
        if abs(newDesiredGearIndex) > 1 and abs(newDesiredGearIndex) > abs(gearbox.gearIndex) and M.throttle > 0 then
            engine:cutIgnition(automaticHandling.sportGearChangeTime * 0.5)
            gearChangeTime = automaticHandling.sportGearChangeTime
        elseif abs(newDesiredGearIndex) > 0 and abs(newDesiredGearIndex) < abs(gearbox.gearIndex) then
            M.throttle = 1
        end
    end

    gearbox:setGearIndex(newDesiredGearIndex, gearChangeTime)
    newDesiredGearIndex                 = 0
    M.timer.gearChangeDelayTimer        = M.timerConstants.gearChangeDelay
    M.updateGearboxGFX                  = gearboxLogic.inGear

    updateExposedData()
end

local function sendTorqueData()
	if engine then
		engine:sendTorqueData()
	end
end

local function init(jbeamData, sharedFunctionTable)
    sharedFunctions  = sharedFunctionTable
    engine           = powertrain.getDevice("mainEngine")
    gearbox          = powertrain.getDevice("gearbox")
    torqueConverter  = powertrain.getDevice("torqueConverter")
    newDesiredGearIndex = 0

    M.currentGearIndex = 0
    M.throttle        = 0
    M.brake           = 0
    M.clutchRatio     = 1

    gearboxAvailableLogic = {
        arcade = {
            inGear         = updateInGearArcade,
            whileShifting  = updateWhileShiftingArcade,
            shiftUp        = sharedFunctions.warnCannotShiftSequential,
            shiftDown      = sharedFunctions.warnCannotShiftSequential,
            shiftToGearIndex = sharedFunctions.switchToRealisticBehavior
        },
        realistic = {
            inGear         = updateInGear,
            whileShifting  = updateWhileShifting,
            shiftUp        = shiftUp,
            shiftDown      = shiftDown,
            shiftToGearIndex = shiftToGearIndex
        }
    }

    automaticHandling.availableModeLookup = {}
    for _, v in pairs(automaticHandling.availableModes) do
        automaticHandling.availableModeLookup[v] = true
    end

    automaticHandling.modes         = {}
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
                automaticHandling.modes[i + modeOffset]      = mode
                automaticHandling.modeIndexLookup[mode]      = i + modeOffset
                automaticHandling.existingModeLookup[mode]   = true
            else
                for j = 1, gearbox.maxGearIndex do
                    local manualMode      = "M" .. tostring(j)
                    local manualModeIndex = i + j - 1
                    automaticHandling.modes[manualModeIndex]        = manualMode
                    automaticHandling.modeIndexLookup[manualMode]   = manualModeIndex
                    automaticHandling.existingModeLookup[manualMode] = true
                    modeOffset = j - 1
                end
            end
        else
            print("unknown auto mode: " .. mode)
        end
    end

    if torqueConverter then
        torqueConverterHandling.hasTorqueConverter        = true
        torqueConverterHandling.lockupAV                  = (jbeamData.torqueConverterLockupRPM or 0) * constants.rpmToAV
        torqueConverterHandling.lockupRange               = ((jbeamData.torqueConverterLockupRange or (torqueConverterHandling.lockupAV * 0.2 * constants.avToRPM)) * constants.rpmToAV)
        torqueConverterHandling.lockupThrottleRange       = (jbeamData.torqueConverterThrottleLockupRange or 0) * constants.rpmToAV
        torqueConverterHandling.lockupDelayMinThrottle    = jbeamData.torqueConverterDelayLockupMinThrottle or 0
        torqueConverterHandling.lockupDelayMaxThrottle    = jbeamData.torqueConverterDelayLockupMaxThrottle or 1
        torqueConverterHandling.lockupMinGear             = jbeamData.torqueConverterLockupMinGear or 0
        torqueConverterHandling.lockupFullyMinGear        = jbeamData.torqueConverterLockupFullyMinGear or 0
        torqueConverterHandling.hasLockup                 = torqueConverterHandling.lockupAV > 0
        torqueConverterHandling.lockupIdleCoef            = jbeamData.torqueConverterlockupIdleCoef or 0
        torqueConverterHandling.lockupAMTRevMargin        = jbeamData.torqueConverterAMTRevMargin or 0
        torqueConverterHandling.lockupAMTCreep            = jbeamData.torqueConverterAMTCreep or 0
        torqueConverterHandling.lockupAMTBrakeThreshold  = jbeamData.torqueConverterAMTBrakeThreshold or 0.01

        local lockupRate = jbeamData.torqueConverterLockupRate or 5
        local lockupInRate  = jbeamData.torqueConverterLockupInRate  or lockupRate * 2
        local lockupOutRate = jbeamData.torqueConverterLockupOutRate or lockupRate
        torqueConverterHandling.lockupSmoother            = newTemporalSmoothing(lockupInRate, lockupOutRate)
    end

    local defaultMode        = jbeamData.defaultAutomaticMode or "N"
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

    automaticHandling.modeIndex       = automaticHandling.modeIndexLookup[defaultMode]
    automaticHandling.defaultForwardMode = defaultForwardMode
    automaticHandling.mode            = automaticHandling.modes[automaticHandling.modeIndex]
    automaticHandling.maxGearIndex    = gearbox.maxGearIndex
    automaticHandling.minGearIndex    = gearbox.minGearIndex
    automaticHandling.krawlerGearIndex = jbeamData.krawlerGearIndex or -2
    automaticHandling.crawlerGearIndex = jbeamData.crawlerGearIndex or 2
    automaticHandling.maxGearChangeTime = jbeamData.maxGearChangeTime or 0
    automaticHandling.minGearChangeTime = jbeamData.minGearChangeTime or 0
    automaticHandling.sportGearChangeTime = jbeamData.sportGearChangeTime or 0
    automaticHandling.gearChangeTimeRange = automaticHandling.minGearChangeTime - automaticHandling.maxGearChangeTime
    automaticHandling.autoDownShiftInM  = jbeamData.autoDownShiftInM == nil and true or jbeamData.autoDownShiftInM
    automaticHandling.autoDownShiftMinGear = jbeamData.autoDownShiftMinGear or 1
    automaticHandling.throttleCoefWhileShifting = jbeamData.throttleCoefWhileShifting or 1
    automaticHandling.amtIdleThrottle        = jbeamData.amtIdleThrottle or 0.01
    automaticHandling.amtRevMatchThrottle   = jbeamData.amtRevMatchThrottle or 0.5
    automaticHandling.amtRevMatchMinThrottle = jbeamData.amtRevMatchMinThrottle or automaticHandling.amtRevMatchThrottle
    automaticHandling.amtRevMatchMaxThrottle = jbeamData.amtRevMatchMaxThrottle or 1

    M.maxRPM       = engine.maxRPM
    M.idleRPM      = engine.idleRPM
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
M.setDefaultForwardMode = setDefaultForwardMode

M.shiftUp = shiftUp
M.shiftDown = shiftDown
M.shiftToGearIndex = shiftToGearIndex

M.getGearName = getGearName
M.getGearPosition = getGearPosition

M.updateGearboxGFX = nop

M.sendTorqueData = sendTorqueData

return M
