--[[--------------------------------------------------------------------
	SB <-> JMod Link :: EZ-Battery Deposition
	Версия: 4.1 — контактный перелив заряда при касании устройства.
	Приложите заряженную ent_jack_gmod_ezbattery к устройству — заряд
	перетекает порциями. Пустая батарея исчезает с искрами.
	Разовый дамп по E сохранён как дополнение.
--------------------------------------------------------------------]]

if not SERVER then return end

SB_JMOD = SB_JMOD or {}

local VERSION = "4.1"

local cvTouch = CreateConVar("sbjmod_ezbat_touch", "1", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
	"Контактный перелив заряда от EZ-батареи (1/0)")
local cvDist = CreateConVar("sbjmod_ezbat_touchdist", "50", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
	"Дистанция касания для контактного перелива")
local cvRate = CreateConVar("sbjmod_ezbat_rate", "25", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
	"Скорость контактного перелива, ед/сек")
local cvRange = CreateConVar("sbjmod_ezbat_range", "150", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
	"Радиус поиска устройства для разового дампа по E")

local BATTERY_CLASS = "ent_jack_gmod_ezbattery"
local BIG = 1000000000

local function IsBattery(e)
	return IsValid(e) and e:GetClass() == BATTERY_CLASS
end

-- Определение типа устройства (совместимо с ядром мода)
local function Identify(e)
	if not IsValid(e) then return nil end
	if isfunction(e.GetElectricity) and isfunction(e.SetElectricity) then return "jmod" end
	if isfunction(e.GetResourceAmount) and isfunction(e.SetResourceAmount) then return "sb" end
	if RD and isfunction(RD.GetEntityTable) then
		local ok, tab = pcall(RD.GetEntityTable, e)
		if ok and tab then return "caf" end
	end
	local cls = tostring(e:GetClass() or "")
	for _, p in ipairs({ "storage_", "generator_", "other_", "residue_" }) do
		if string.find(cls, p, 1, true) then return "caf" end
	end
	return nil
end

local function GetCharge(e, t)
	if t == "jmod" then
		local ok, cur = pcall(e.GetElectricity, e)
		if not ok then return nil end
		local max = tonumber(e.MaxElectricity) or 1000
		return tonumber(cur) or 0, max
	elseif t == "sb" then
		local ok, cur = pcall(e.GetResourceAmount, e, "energy")
		if not ok then return nil end
		return tonumber(cur) or 0, 10000
	elseif t == "caf" then
		if not (RD and isfunction(RD.GetResourceAmount)) then return nil end
		local ok, cur = pcall(RD.GetResourceAmount, e, "energy")
		if not ok then return nil end
		local cap = 10000
		if RD and isfunction(RD.GetNetworkCapacity) then
			local okc, c = pcall(RD.GetNetworkCapacity, e, "energy")
			if okc and tonumber(c) then cap = tonumber(c) end
		end
		return tonumber(cur) or 0, cap
	end
	return nil
end

local function AddCharge(e, t, amt)
	amt = math.min(amt, BIG)
	local cur, cap = GetCharge(e, t)
	if not cur then return 0 end
	local space = cap - cur
	if space <= 0 then return 0 end
	local give = math.min(space, amt)
	if give <= 0 then return 0 end
	if t == "jmod" then
		pcall(e.SetElectricity, e, cur + give)
	elseif t == "sb" then
		pcall(e.SetResourceAmount, e, "energy", cur + give)
	elseif t == "caf" then
		if RD and isfunction(RD.SetResourceAmount) then
			pcall(RD.SetResourceAmount, e, "energy", cur + give)
		end
	end
	return give
end

local function GetBatteryCharge(bat)
	local ok, v = pcall(bat.GetElectricity, bat)
	if ok and tonumber(v) then return tonumber(v) end
	return tonumber(bat.Electricity) or 0
end

local function SetBatteryCharge(bat, v)
	v = math.max(0, math.floor(v))
	if isfunction(bat.SetElectricity) then
		pcall(bat.SetElectricity, bat, v)
	end
	bat.Electricity = v
end

local function Sparks(pos)
	local ed = EffectData()
	ed:SetOrigin(pos)
	util.Effect("GlassImpact", ed)
end

local function KillBattery(bat)
	Sparks(bat:GetPos())
	bat:EmitSound("ambient/energy/zap" .. math.random(1, 3) .. ".wav", 70)
	bat:Remove()
end

-- Ближайшее совместимое устройство к точке
local function FindDevice(pos, radius, exclude)
	local best, bestT, bestD = nil, nil, nil
	for _, e in ipairs(ents.FindInSphere(pos, math.max(radius, 1))) do
		if IsValid(e) and e ~= exclude and not IsBattery(e) then
			local t = Identify(e)
			if t then
				local d = e:GetPos():Distance(pos)
				if (not bestD) or (d < bestD) then
					best, bestT, bestD = e, t, d
				end
			end
		end
	end
	return best, bestT
end

-- КОНТАКТНЫЙ ПЕРЕЛИВ: раз в секунду ищем заряженные батареи рядом с устройствами
timer.Create("SBJMOD_EZBAT_Touch", 1, 0, function()
	if not cvTouch:GetBool() then return end
	local rate = math.max(1, cvRate:GetInt())
	local dist = math.max(0, cvDist:GetFloat())

	for _, bat in ipairs(ents.FindByClass(BATTERY_CLASS)) do
		local charge = GetBatteryCharge(bat)
		if charge > 0 then
			local dev, devT = FindDevice(bat:GetPos(), dist, bat)
			if dev then
				local give = AddCharge(dev, devT, rate)
				if give > 0 then
					charge = charge - give
					if charge <= 0 then
						KillBattery(bat)
					else
						SetBatteryCharge(bat, charge)
					end
				end
			end
		end
	end
end)

-- РАЗОВЫЙ ДАМП ПО E: навелись на заряженную батарею, нажали E — заряд ушёл целиком
hook.Add("PlayerUse", "SBJMOD_EZBAT_Dump", function(ply, e)
	if not IsBattery(e) then return end

	local charge = GetBatteryCharge(e)
	if not charge or charge <= 0 then return end -- пустая — обычный подбор в инвентарь

	local dev, devT = FindDevice(e:GetPos(), cvRange:GetFloat(), e)
	if not dev then return end -- рядом нет устройства — обычный подбор в инвентарь

	local give = AddCharge(dev, devT, BIG)
	if give <= 0 then
		ply:ChatPrint("[SBJMOD] " .. dev:GetClass() .. " уже полон.")
		return false
	end

	local rest = charge - give
	if rest <= 0 then
		KillBattery(e)
		ply:ChatPrint("[SBJMOD] Вставлено " .. give .. " ед. в " .. dev:GetClass() .. ". Батарея израсходована.")
	else
		SetBatteryCharge(e, rest)
		ply:ChatPrint("[SBJMOD] Влито " .. give .. " ед. в " .. dev:GetClass() .. ", в батарее осталось " .. rest .. " ед.")
	end
	return false -- блокируем подбор, чтобы батарея не улетела в инвентарь вместе с переливом
end)

print("[SBJMOD] EZ-Battery module v" .. VERSION .. " загружен.")
