--[[--------------------------------------------------------------------
	SB <-> JMod Link :: Transfer (v8.1)
	Поддержка: JMod, Spacebuild/SB, CAF/RD3 + resource_node (SB3/CAF)

	Правила сети (строго):
	  генератор -> банк/потребитель : МОЖНО
	    генератор отдаёт ровно столько, сколько нужно принимающему
	    до его полной ёмкости (банк на 1000 получает ровно 1000,
	    и не больше — пока не освободится место)
	  банк <-> банк                 : равный делёж 1-в-1, до единицы
	  потребитель -> кто угодно     : ЗАПРЕЩЕНО (только принимает)
	  банк -> генератор             : ЗАПРЕЩЕНО
	  генератор <-> генератор       : ЗАПРЕЩЕНО

	Интервал: 0,1 секунды. Лог: sbjmod_transferlog 1
	Диагностика: sbjmod_test_energy (устройство под прицелом).
--------------------------------------------------------------------]]

local cvLog = CreateConVar("sbjmod_transferlog", "0", FCVAR_ARCHIVE,
	"Показывать перекачку энергии в консоли (0/1)")

-- ======== Доступ к Resource Distribution (SB3/CAF) ========

local function GetRD()
	if RD and isfunction(RD.GetResourceAmount) then return RD end
	if CAF and isfunction(CAF.GetAddon) then
		local ok, rd = pcall(CAF.GetAddon, "Resource Distribution")
		if ok and rd and isfunction(rd.GetResourceAmount) then return rd end
	end
	return nil
end

-- Ёмкость по ресурсу energy: сеть RD -> юнит-ёмкость -> методы энтити -> 10000
local function GetCap(e, rd)
	local cap
	if rd and isfunction(rd.GetNetworkCapacity) then
		local ok, c = pcall(rd.GetNetworkCapacity, e, "energy")
		if ok and tonumber(c) and tonumber(c) > 0 then cap = tonumber(c) end
	end
	if not cap and rd and isfunction(rd.GetUnitCapacity) then
		local ok, c = pcall(rd.GetUnitCapacity, e, "energy")
		if ok and tonumber(c) and tonumber(c) > 0 then cap = tonumber(c) end
	end
	if not cap and isfunction(e.GetNetworkCapacity) then
		local ok, c = pcall(e.GetNetworkCapacity, e, "energy")
		if ok and tonumber(c) and tonumber(c) > 0 then cap = tonumber(c) end
	end
	cap = cap or 10000
	-- Лимит энергии Fusion Generators (sbjmod_fusion_energy_limit).
	-- учтён: GetNetworkCapacity (см. выше) возвращает maxvalue сети, а
	-- лимит энергии в RD3 — это ПОТОЛОК СЕТЕВОГО значения (nettable
	-- value), поэтому он ограничивает и перекачку во всю сеть, не
	-- только генератор. Подробности — в заголовке fusion.lua, раздел 2.
	local F = SB_JMOD.Fusion
	if F and isfunction(F.Is) and isfunction(F.Capacity) and F.Is(e) then
		cap = F.Capacity(cap)
	end
	return cap
end

-- ======== Расширение ядра: resource_node (SB3/CAF) ========

local IsResNode = function(e)
	return string.lower(e:GetClass() or "") == "resource_node"
end

local OldIdentify = SB_JMOD.Identify
SB_JMOD.Identify = function(e)
	if not IsValid(e) then return nil end
	if IsResNode(e) then return "sbres" end
	return OldIdentify and OldIdentify(e) or nil
end

-- ======== Чтение заряда: возвращает текущее значение и ёмкость ========

local function GetCharge(e, t)
	if t == "jmod" or t == "both" then
		local ok, cur = pcall(e.GetElectricity, e)
		if not ok or cur == nil then return nil end
		local max = tonumber(e.MaxElectricity) or 1000
		if max <= 0 then max = 1000 end
		return tonumber(cur) or 0, max
	end

	-- sbres / sb / caf / fusion — единый устойчивый путь: RD -> методы энтити
	local rd = GetRD()
	if rd then
		local ok, cur = pcall(rd.GetResourceAmount, e, "energy")
		if ok and isnumber(cur) then
			return cur, GetCap(e, rd)
		end
	end
	if isfunction(e.GetResourceAmount) then
		local ok, cur = pcall(e.GetResourceAmount, e, "energy")
		if ok and isnumber(cur) then
			return cur, GetCap(e, nil)
		end
	end
	return nil
end

-- ======== Запись заряда ========
-- Важно: в RD3 НЕТ SetResourceAmount. Правильный способ изменить
-- количество — дельта через SupplyResource / ConsumeResource
-- (они корректно обновляют и сеть, и локальные счётчики).

local function SetCharge(e, t, val)
	val = math.max(0, math.floor(val + 0.5))

	if t == "jmod" or t == "both" then
		pcall(e.SetElectricity, e, val)
		return
	end

	local cur = GetCharge(e, t)
	if cur == nil then return end
	local diff = val - cur
	if diff == 0 then return end

	local rd = GetRD()
	if diff > 0 then
		if rd and isfunction(rd.SupplyResource) then
			pcall(rd.SupplyResource, e, "energy", diff)
		elseif isfunction(e.SupplyResource) then
			pcall(e.SupplyResource, e, "energy", diff)
		end
	else
		if rd and isfunction(rd.ConsumeResource) then
			pcall(rd.ConsumeResource, e, "energy", -diff)
		elseif isfunction(e.ConsumeResource) then
			pcall(e.ConsumeResource, e, "energy", -diff)
		end
	end
end

-- ======== Роль устройства: "gen", "cons" или "bank" ========

local function GetRole(e)
	local F = SB_JMOD.Fusion
	if F and isfunction(F.Is) and F.Is(e) then return "gen" end
	local cls = string.lower(e:GetClass() or "")
	if string.find(cls, "turret", 1, true)
		or string.find(cls, "sentry", 1, true)
		or string.find(cls, "consumer", 1, true) then
		return "cons"
	end
	if string.find(cls, "generator", 1, true)
		or string.find(cls, "gen_", 1, true)
		or string.find(cls, "_gen", 1, true)
		or string.find(cls, "powersource", 1, true)
		or string.find(cls, "reactor", 1, true) then
		return "gen"
	end
	-- resource_node, банки, всё остальное — накопители
	return "bank"
end

SB_JMOD.GetRole = GetRole -- доступно модулям (fusion.lua)

-- ======== Перекачка энергии по одной связи ========

local function Move(src, srcT, dst, dstT, give)
	if give <= 0 then return end
	local sCur = GetCharge(src, srcT)
	local dCur, dCap = GetCharge(dst, dstT)
	if not sCur or not dCur or not dCap then return end
	-- Не отдаём больше, чем источник имеет, и не вливаем больше,
	-- чем принимающий может вместить (иначе энергия теряется)
	give = math.min(give, sCur, dCap - dCur)
	if give <= 0 then return end
	SetCharge(src, srcT, sCur - give)
	SetCharge(dst, dstT, dCur + give)
	if cvLog:GetBool() then
		print(("[SBJMOD] %s -> %s: +%d"):format(src:GetClass(), dst:GetClass(), give))
	end
end

local function TransferLink(l)
	if not IsValid(l.a) or not IsValid(l.b) then return end

	local ta = SB_JMOD.Identify and SB_JMOD.Identify(l.a) or nil
	local tb = SB_JMOD.Identify and SB_JMOD.Identify(l.b) or nil
	if not ta or not tb then return end

	local roleA = GetRole(l.a)
	local roleB = GetRole(l.b)

	-- генератор <-> генератор: ЗАПРЕЩЕНО
	if roleA == "gen" and roleB == "gen" then return end

	local curA, capA = GetCharge(l.a, ta)
	local curB, capB = GetCharge(l.b, tb)
	if not curA or not curB or not capA or not capB then return end

	-- генератор -> банк/потребитель: заполняем принимающий ДО ЕГО ЁМКОСТИ
	if roleA == "gen" then
		local free = capB - curB
		if free > 0 then Move(l.a, ta, l.b, tb, math.min(free, curA)) end
		return
	end
	if roleB == "gen" then
		local free = capA - curA
		if free > 0 then Move(l.b, tb, l.a, ta, math.min(free, curB)) end
		return
	end

	-- потребитель -> кто угодно: ЗАПРЕЩЕНО (в т.ч. cons -> cons).
	-- банк -> потребитель: только пополнение потребителя
	if roleA == "cons" then
		if roleB ~= "cons" then
			local free = capA - curA
			if free > 0 then Move(l.b, tb, l.a, ta, math.min(free, curB)) end
		end
		return
	end
	if roleB == "cons" then
		local free = capB - curB
		if free > 0 then Move(l.a, ta, l.b, tb, math.min(free, curA)) end
		return
	end

	-- банк <-> банк: равный делёж 1-в-1, до единицы
	if capA <= 0 or capB <= 0 then return end
	local total = curA + curB
	if total <= 0 then return end

	local wantA = math.min(math.floor(total / 2), capA)
	local wantB = math.min(total - wantA, capB)
	if wantB < total - wantA then
		wantA = math.min(total - wantB, capA)
	end

	if curA > wantA then Move(l.a, ta, l.b, tb, curA - wantA) end
	if curB > wantB then Move(l.b, tb, l.a, ta, curB - wantB) end
end

timer.Create("SBJMOD_Transfer", 0.1, 0, function()
	if not SB_JMOD.Links or #SB_JMOD.Links == 0 then return end
	for _, l in ipairs(SB_JMOD.Links) do
		pcall(TransferLink, l)
	end
end)

-- ======== Диагностика устройства под прицелом ========

concommand.Add("sbjmod_test_energy", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local e = ply:GetEyeTrace().Entity
	if not IsValid(e) then
		print("[SBJMOD] Под прицелом ничего.")
		return
	end

	local t = SB_JMOD.Identify and SB_JMOD.Identify(e) or nil

	print("[SBJMOD] === Диагностика: " .. e:GetClass() .. " ===")
	print("Роль: " .. GetRole(e) .. " | Тип: " .. tostring(t))

	if IsResNode(e) then
		print("resource_node: окно в RD-сеть, ресурс 'energy'")
	end

	if t == "jmod" or t == "both" then
		if isfunction(e.GetElectricity) then
			local ok, v = pcall(e.GetElectricity, e)
			print("GetElectricity -> ok=" .. tostring(ok) .. " val=" .. tostring(v))
			print("MaxElectricity = " .. tostring(e.MaxElectricity))
		end
	elseif t then
		local cur, cap = GetCharge(e, t)
		print("energy: " .. tostring(cur) .. " / " .. tostring(cap))
		local rd = GetRD()
		if rd then
			local ok, v = pcall(rd.GetResourceAmount, e, "energy")
			print("RD.GetResourceAmount -> ok=" .. tostring(ok) .. " val=" .. tostring(v))
			if isfunction(rd.GetNetworkCapacity) then
				local okc, c = pcall(rd.GetNetworkCapacity, e, "energy")
				print("RD.GetNetworkCapacity -> ok=" .. tostring(okc) .. " val=" .. tostring(c))
			end
			if isfunction(rd.GetUnitCapacity) then
				local oku, u = pcall(rd.GetUnitCapacity, e, "energy")
				print("RD.GetUnitCapacity -> ok=" .. tostring(oku) .. " val=" .. tostring(u))
			end
		else
			print("RD недоступен: нет ни глобального RD, ни CAF.GetAddon!")
		end
	else
		print("Тип не определён: тул не сможет связать это устройство.")
	end

	print("[SBJMOD] === Конец диагностики ===")
end)

print("[SBJMOD] Модуль transfer v8.1 загружен: правила сети (gen->bank/cons, bank<->bank 1:1, cons не отдаёт)")
