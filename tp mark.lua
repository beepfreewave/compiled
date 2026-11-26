script_name("Smooth TP")
script_author("govnocode")

require "lib.moonloader"
require "lib.sampfuncs"
local sampev = require "samp.events"
local ffi = require "ffi"
local raknet = require "samp.raknet"

local cfg = {
    stepDist = 179.7,
    dipStartZ = -135.0,
    dipStepZ = -25.0,
    cruiseZ = -60.0,
    dipWaitMs = 25,
    stepWaitMs = 2850,
    microRestEverySteps = 4,
    microRestMs = 900,
    finishSettleMs = 120,
    safeDropAboveZ = 25.0,
    surfaceClearanceZ = 1.8,
    waterLevelZ = 0.0,
    collisionPollInterval = 0.25,
    command = "tp"
}

local tp = {
    active = false,
    thread = nil,
    startPos = nil,
    targetPos = nil,
    syncPos = nil,
    moveVel = { x = 0.0, y = 0.0, z = 0.0 },
    totalDist = 0.0,
    traveledDist = 0.0,
    lastCollisionTick = 0.0,
    lastLoggedBucket = -1,
    cancelGroundOverride = nil
}

local function setEntityCoordinates(entityPtr, x, y, z)
    if entityPtr and entityPtr ~= 0 then
        local matrixPtr = readMemory(entityPtr + 0x14, 4, false)
        if matrixPtr and matrixPtr ~= 0 then
            local posPtr = matrixPtr + 0x30
            writeMemory(posPtr + 0, 4, representFloatAsInt(x), false)
            writeMemory(posPtr + 4, 4, representFloatAsInt(y), false)
            writeMemory(posPtr + 8, 4, representFloatAsInt(z), false)
        end
    end
end

local function setCharCoordinatesDontResetAnim(char, x, y, z)
    if char and doesCharExist(char) then
        local ptr = getCharPointer(char)
        setEntityCoordinates(ptr, x, y, z)
    end
end

local function teleportPlayer(x, y, z)
    if not x or not y or not z then return end
    if doesCharExist(PLAYER_PED) and isCharInAnyCar(PLAYER_PED) then
        local car = storeCarCharIsInNoSave(PLAYER_PED)
        if car and doesVehicleExist(car) then
            pcall(setCarCoordinates, car, x, y, z)
        end
    end
    setCharCoordinatesDontResetAnim(PLAYER_PED, x, y, z)
end

local function setMovementFreeze(state)
    if not doesCharExist(PLAYER_PED) then return end
    if isCharInAnyCar(PLAYER_PED) then
        local car = storeCarCharIsInNoSave(PLAYER_PED)
        if car and doesVehicleExist(car) then
            pcall(freezeCarPosition, car, state)
        end
    else
        pcall(freezeCharPosition, PLAYER_PED, state)
    end
end

local function samp_create_sync_data(sync_type)
    local sync_traits = {
        player = { "PlayerSyncData", raknet.PACKET.PLAYER_SYNC, sampStorePlayerOnfootData },
        vehicle = { "VehicleSyncData", raknet.PACKET.VEHICLE_SYNC, sampStorePlayerIncarData }
    }
    local sync_info = sync_traits[sync_type] or sync_traits.player
    local data = ffi.new("struct " .. sync_info[1], {})
    local raw_ptr = tonumber(ffi.cast("uintptr_t", ffi.new("struct " .. sync_info[1] .. "*", data)))
    local _, pId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    sync_info[3](pId, raw_ptr)

    return setmetatable({
        send = function()
            local bs = raknetNewBitStream()
            raknetBitStreamWriteInt8(bs, sync_info[2])
            raknetBitStreamWriteBuffer(bs, raw_ptr, ffi.sizeof(data))
            raknetSendBitStreamEx(bs, 1, 3, 1)
            raknetDeleteBitStream(bs)
        end
    }, {
        __index = data,
        __newindex = function(t, k, v) data[k] = v end
    })
end

local function getTargetBlipFromRadarMemory()
    local targetBlipHandle = readMemory(0xBA6774 + 0x20, 4, false)
    if not targetBlipHandle or targetBlipHandle == 0 then
        return nil
    end
    local idx = bit.band(targetBlipHandle, 0xFFFF)
    if idx < 0 or idx >= 175 then
        return nil
    end
    local blipStruct = 0xBA86F0 + idx * 0x28
    local x = representIntAsFloat(readMemory(blipStruct + 0x08, 4, false))
    local y = representIntAsFloat(readMemory(blipStruct + 0x0C, 4, false))
    local z = representIntAsFloat(readMemory(blipStruct + 0x10, 4, false))
    if type(x) == "number" and type(y) == "number" and x == x and y == y then
        if math.abs(x) > 0.001 or math.abs(y) > 0.001 then
            return x, y, z
        end
    end
    return nil
end

local function maybeRequestCollision(x, y, nowClock, force)
    if type(requestCollision) ~= "function" then
        return
    end
    local t = nowClock or os.clock()
    if force or (t - tp.lastCollisionTick) >= cfg.collisionPollInterval then
        tp.lastCollisionTick = t
        pcall(requestCollision, x, y)
    end
end

local function resolveSurfaceZ(x, y, fallbackZ, nowClock, forceCollision)
    local baseFallback = (type(fallbackZ) == "number" and fallbackZ == fallbackZ and fallbackZ > -900.0)
        and fallbackZ
        or 20.0
    local finalZ = math.max(20.0, baseFallback + cfg.surfaceClearanceZ)

    maybeRequestCollision(x, y, nowClock, forceCollision)
    if type(getGroundZFor3dCoord) == "function" then
        local searchZ = math.max(finalZ + 80.0, 320.0)
        local okGz, gz = pcall(getGroundZFor3dCoord, x, y, searchZ)
        if okGz and type(gz) == "number" and gz == gz and gz > -900.0 then
            if gz < cfg.waterLevelZ + 0.25 then
                finalZ = math.max(cfg.waterLevelZ + 2.0, gz + cfg.surfaceClearanceZ)
            else
                finalZ = gz + cfg.surfaceClearanceZ
            end
        end
    end

    if finalZ < cfg.waterLevelZ + 1.5 then
        finalZ = cfg.waterLevelZ + 2.0
    end

    return finalZ
end

local function getMapMarkerCoords()
    local x, y, z = nil, nil, nil

    if type(getTargetBlipCoordinates) == "function" then
        local ok, res, bx, by, bz = pcall(getTargetBlipCoordinates)
        if ok and res and type(bx) == "number" and type(by) == "number" then
            x, y, z = bx, by, bz
        end
    end

    if not x or not y then
        x, y, z = getTargetBlipFromRadarMemory()
    end

    if type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    if x ~= x or y ~= y then
        return nil
    end
    if math.abs(x) < 0.001 and math.abs(y) < 0.001 then
        return nil
    end

    local finalZ = resolveSurfaceZ(x, y, z, os.clock(), true)
    return x, y, finalZ
end

local function resetCameraToPlayer()
    if type(restoreCameraJumpcut) == "function" then
        pcall(restoreCameraJumpcut)
    end
    if type(setCameraBehindPlayer) == "function" then
        pcall(setCameraBehindPlayer)
    end
end

local function resetTpState()
    tp.active = false
    tp.thread = nil
    tp.startPos = nil
    tp.targetPos = nil
    tp.syncPos = nil
    tp.moveVel = { x = 0.0, y = 0.0, z = 0.0 }
    tp.totalDist = 0.0
    tp.traveledDist = 0.0
    tp.lastLoggedBucket = -1
end

local function cancelSmoothTp(silent, snapToCurrentSync)
    local snapPos = (snapToCurrentSync and tp.syncPos) and { x = tp.syncPos.x, y = tp.syncPos.y, z = tp.syncPos.z } or nil
    local nowClock = os.clock()

    resetTpState()
    setMovementFreeze(false)

    if snapPos and doesCharExist(PLAYER_PED) then
        local sx, sy = snapPos.x, snapPos.y
        local aboveRefZ = math.max(cfg.waterLevelZ + 2.0, snapPos.z + 25.0)
        local groundZ = resolveSurfaceZ(sx, sy, aboveRefZ, nowClock, true)
        tp.cancelGroundOverride = { x = sx, y = sy, z = groundZ }
        pcall(teleportPlayer, sx, sy, groundZ)
    else
        tp.cancelGroundOverride = nil
    end

    if not silent and isSampAvailable() then
        sampAddChatMessage("{FFAA00}[TP] {FFFFFF}Teleport cancelled.", -1)
    end
end

local function reportProgressIfNeeded(ratio, remainingDist)
    local percent = math.floor(ratio * 100 + 0.5)
    if percent > 100 then percent = 100 end
    local bucket = math.floor(percent / 20)
    if bucket > tp.lastLoggedBucket and percent < 100 then
        tp.lastLoggedBucket = bucket
        local etaSec = remainingDist / math.max(1.0, cfg.stepDist / (cfg.stepWaitMs / 1000.0))
        sampAddChatMessage(
            string.format("{00FFFF}[TP] {FFFFFF}Progress: {00FF00}%d%% {FFFFFF}(~%.1fs left)", percent, etaSec),
            -1
        )
    end
end

local function sendDipSequence(syncData, x, y, fromZ, incar)
    local dropZ = incar and -0.1 or -0.7
    for zStep = fromZ, cfg.dipStartZ, cfg.dipStepZ do
        if not tp.active then return false end
        tp.syncPos = { x = x, y = y, z = zStep }
        tp.moveVel = { x = 0.0, y = 0.0, z = dropZ }
        syncData.moveSpeed = { 0.0, 0.0, dropZ }
        syncData.position = { x, y, zStep }
        syncData.send()
        wait(cfg.dipWaitMs)
    end
    return tp.active
end

local function runLargeStepTeleport(px, py, pz, tx, ty, tz)
    local incar = doesCharExist(PLAYER_PED) and isCharInAnyCar(PLAYER_PED)
    local syncData = samp_create_sync_data(incar and "vehicle" or "player")
    local dist2d = getDistanceBetweenCoords2d(px, py, tx, ty)
    local angle = -math.rad(getHeadingFromVector2d(tx - px, ty - py))
    local nx, ny, nz = px, py, pz
    local stepCounter = 0

    tp.totalDist = math.max(0.1, dist2d)
    tp.traveledDist = 0.0
    tp.lastLoggedBucket = 0
    setMovementFreeze(true)

    if dist2d > cfg.stepDist then
        for ds = dist2d - cfg.stepDist, 0, -cfg.stepDist do
            if not tp.active then
                cancelSmoothTp(true, false)
                return
            end

            if not sendDipSequence(syncData, nx, ny, nz, incar) then
                cancelSmoothTp(true, false)
                return
            end

            nx = nx + math.sin(angle) * cfg.stepDist
            ny = ny + math.cos(angle) * cfg.stepDist
            nz = cfg.cruiseZ
            stepCounter = stepCounter + 1

            tp.traveledDist = math.min(tp.totalDist, dist2d - ds)
            tp.syncPos = { x = nx, y = ny, z = nz }
            tp.moveVel = { x = 0.0, y = 0.0, z = 0.0 }
            syncData.moveSpeed = { 0.0, 0.0, 0.0 }
            syncData.position = { nx, ny, nz }
            syncData.send()

            maybeRequestCollision(nx, ny, os.clock(), false)
            reportProgressIfNeeded(tp.traveledDist / tp.totalDist, math.max(0.0, dist2d - tp.traveledDist))
            wait(cfg.stepWaitMs)

            if not tp.active then
                cancelSmoothTp(true, false)
                return
            end

            if cfg.microRestEverySteps > 0 and (stepCounter % cfg.microRestEverySteps == 0) then
                syncData.position = { nx, ny, nz }
                syncData.moveSpeed = { 0.0, 0.0, 0.0 }
                syncData.send()
                wait(cfg.microRestMs)
            end
        end
    end

    if not tp.active then
        cancelSmoothTp(true, false)
        return
    end

    if not sendDipSequence(syncData, nx, ny, nz, incar) then
        cancelSmoothTp(true, false)
        return
    end

    local nowClock = os.clock()
    local initialSurfaceZ = resolveSurfaceZ(tx, ty, tz, nowClock, true)
    local highSafeZ = math.max(initialSurfaceZ + cfg.safeDropAboveZ, 45.0)

    pcall(teleportPlayer, tx, ty, highSafeZ)
    wait(cfg.finishSettleMs)

    if not tp.active then
        cancelSmoothTp(true, false)
        return
    end

    local settledZ = resolveSurfaceZ(tx, ty, initialSurfaceZ, os.clock(), true)
    tp.syncPos = { x = tx, y = ty, z = settledZ }
    tp.moveVel = { x = 0.0, y = 0.0, z = 0.0 }
    syncData.moveSpeed = { 0.0, 0.0, 0.0 }
    syncData.position = { tx, ty, settledZ }
    syncData.send()

    resetTpState()
    setMovementFreeze(false)
    pcall(teleportPlayer, tx, ty, settledZ)
    sampAddChatMessage("{00FF00}[TP] {FFFFFF}Teleported successfully (100%).", -1)
end

local function startSmoothTpToMarker()
    if not doesCharExist(PLAYER_PED) then
        sampAddChatMessage("{FF0000}[TP] {FFFFFF}Player character not found.", -1)
        return
    end

    local tx, ty, tz = getMapMarkerCoords()
    if not tx then
        sampAddChatMessage("{FF0000}[TP] {FFFFFF}Place a marker on the map first.", -1)
        return
    end

    local okPos, px, py, pz = pcall(getCharCoordinates, PLAYER_PED)
    if not okPos or type(px) ~= "number" then
        sampAddChatMessage("{FF0000}[TP] {FFFFFF}Failed to get current position.", -1)
        return
    end

    tp.cancelGroundOverride = nil

    local dist = getDistanceBetweenCoords3d(px, py, pz, tx, ty, tz)
    if dist < 0.5 then
        pcall(teleportPlayer, tx, ty, tz)
        sampAddChatMessage("{00FF00}[TP] {FFFFFF}Teleported successfully (100%).", -1)
        return
    end

    local nowClock = os.clock()
    local startSurfaceZ = resolveSurfaceZ(px, py, pz, nowClock, true)
    local totalRouteDist = getDistanceBetweenCoords3d(px, py, startSurfaceZ, tx, ty, tz)
    local effSpeed = math.max(0.5, cfg.stepDist / (cfg.stepWaitMs / 1000.0))
    local etaSec = totalRouteDist / effSpeed

    tp.startPos = { x = px, y = py, z = startSurfaceZ }
    tp.targetPos = { x = tx, y = ty, z = tz }
    tp.syncPos = { x = px, y = py, z = startSurfaceZ }
    tp.lastCollisionTick = nowClock
    tp.active = true

    sampAddChatMessage(
        string.format("{00FF00}[TP] {FFFFFF}Started: %.1fm (~%.1fs)", dist, etaSec),
        -1
    )

    tp.thread = lua_thread.create(function()
        local ok, err = pcall(runLargeStepTeleport, px, py, startSurfaceZ, tx, ty, tz)
        if not ok then
            cancelSmoothTp(true, false)
            if isSampAvailable() then
                sampAddChatMessage("{FF0000}[TP Error] {FFFFFF}" .. tostring(err), -1)
            end
        end
    end)
end

local function handleOutgoingSync(data)
    if tp.active then
        return false
    end

    if tp.cancelGroundOverride and data and data.position then
        local ov = tp.cancelGroundOverride
        tp.cancelGroundOverride = nil
        data.position.x = ov.x
        data.position.y = ov.y
        data.position.z = ov.z
        if type(data.moveSpeed) == "table" then
            data.moveSpeed.x = 0.0
            data.moveSpeed.y = 0.0
            data.moveSpeed.z = 0.0
        end
    end

    return true
end

function sampev.onSendPlayerSync(data)
    return handleOutgoingSync(data)
end

function sampev.onSendVehicleSync(data)
    return handleOutgoingSync(data)
end

function sampev.onSendPassengerSync(data)
    return handleOutgoingSync(data)
end

function main()
    while not isSampAvailable() do wait(100) end
    resetCameraToPlayer()

    sampAddChatMessage("{00FF00}[TP] {FFFFFF}Script loaded. Use /" .. cfg.command, -1)

    sampRegisterChatCommand("tp", function()
        local ok, err = pcall(function()
            if tp.active then
                sampAddChatMessage("{FF0000}[TP] {FFFFFF}Teleport is already in progress. Cancellation is disabled.", -1)
                return
            end
            startSmoothTpToMarker()
        end)
        if not ok then
            cancelSmoothTp(true, false)
            sampAddChatMessage("{FF0000}[TP Error] {FFFFFF}" .. tostring(err), -1)
        end
    end)

    while true do
        wait(0)
    end
end