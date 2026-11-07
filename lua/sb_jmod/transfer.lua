--[[--------------------------------------------------------------------
	SB <-> JMod Link :: Transfer (v7.3)
	Поддержка: JMod, Spacebuild/SB, CAF + resource_node (SB3/CAF)

	Роли устройств:
	  генератор   ("generator", "gen_", "_gen", "powersource", "reactor")
	  потребитель (turret, sentry)
	  накопитель  (банки, батареи, resource_node)

	Правила сети:
	  генератор -> банк/потребитель : можно
	  банк <-> банк                 : равный делёж
	  потребитель -> кто угодно     : ЗАПРЕЩЕНО
	  банк -> генератор и генератор <-> генератор: ЗАПРЕЩЕНО

	Интервал: 0,1 секунды. Лог: sbjmod_transferlog 1
	Диагностика: sbjmod_test_energy (устройство под прицелом).
--------------------------------------------------------------------]]

local cvLog = CreateConVar("sbjmod_transferlog", "0", FCVAR_ARCHIVE,
	"Показывать перекачку энергии в консоли (0/1)")

-- ======== Доступ к Resource Distribution (SB3/CAF) ========

local function GetRD()
	if RD and isfunction(RD.GetResourceAmount) then return RD end
	if CAF and CAF.GetAddon then
		local ok, rd = pcall(CAF.GetAddon, "Resource Distribution")
		if ok and rd and isfunction(rd.GetResourceAmount) then return rd end
	end
	return nil
end

-- Ёмкость сети по ресурсу energy: сначала RD, потом методы энтити, потом 10000
local function GetCap(e, rd)
	if rd and isfunction(rd.GetNetworkCapacity) then
		local ok, c = pcall(rd.GetNetworkCapacity, e, "energy")
		if ok and tonumber(c) and tonumber(c) > 0 then return tonumber(c) end
	end
	if isfunction(e.GetNetworkCapacity) then
		local ok, c = pcall(e.GetNetworkCapacity, e, "energy")
		if ok and tonumber(c) and tonumber(c) > 0 then return tonumber(c) end
	end
	return 10000
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

-- ======== Чтение заряда устройства: возвращает текущее значение и ёмкость ========

local function GetCharge(e, t)
	if t == "jmod" then
		local ok, cur = pcall(e.GetElectricity, e)
		if not ok or cur == nil then return nil end
		local max = tonumber(e.MaxElectricity) or 1000
		if max <= 0 then max = 1000 end
		return tonumber(cur) or 0, max

	elseif t == "sbres" then
		-- resource_node: окно в RD-сеть, читаем через RD
		local rd = GetRD()
		if rd then
			local ok, cur = pcall(rd.GetResourceAmount, e, "energy")
			if ok and cur ~= nil then
				return tonumber(cur) or 0, GetCap(e, rd)
			end
		end
		-- запасной вариант: методы на самой энтити
		if isfunction(e.GetResourceAmount) then
			local ok, cur = pcall(e.GetResourceAmount, e, "energy")
			if ok and cur ~= nil then
				return tonumber(cur) or 0, GetCap(e, nil)
			end
		end
		return nil

	elseif t == "sb" or t == "caf" then
		-- единый устойчивый путь: RD -> методы энтити
		local rd = GetRD()
		if rd then
			local ok, cur = pcall(rd.GetResourceAmount, e, "energy")
			if ok and cur ~= nil then
				return tonumber(cur) or 0, GetCap(e, rd)
			end
		end
		if isfunction(e.GetResourceAmount) then
			local ok, cur = pcall(e.GetResourceAmount, e, "energy")
			if ok and cur ~= nil then
				return tonumber(cur) or 0, GetCap(e, nil)
			end
		end
		return nil
	end

	return nil
end

-- ======== Запись заряда устройства ========

local function SetCharge(e, t, val)
	val = math.max(0, math.floor(val))

	if t == "jmod" then
		pcall(e.SetElectricity, e, val)

	elseif t == "sbres" then
		local rd = GetRD()
		if rd and isfunction(rd.SetResourceAmount) then
			local ok = pcall(rd.SetResourceAmount, e, "energy", val)
			if ok then return end
		end
		if isfunction(e.SetResourceAmount) then
			pcall(e.SetResourceAmount, e, "energy", val)
		end

	elseif t == "caf" then
		local rd = GetRD()
		if rd and isfunction(rd.SetResourceAmount) then
			local ok = pcall(rd.SetResourceAmount, e, "energy", val)
			if ok then return end
		end
		if isfunction(e.SetResourceAmount) then
			pcall(e.SetResourceAmount, e, "energy", val)
		end

	elseif t == "sb" then
		if isfunction(e.SetResourceAmount) then
			pcall(e.SetResourceAmount, e, "energy", val)
		else
			local rd = GetRD()
			if rd and isfunction(rd.SetResourceAmount) then
				pcall(rd.SetResourceAmount, e, "energy", val)
			end
		end
	end
end

-- ======== Роль устройства: "gen", "cons" или "bank" ========

local function GetRole(e)
	local cls = string.lower(e:GetClass() or "")
	if string.find(cls, "turret", 1, true)
		or string.find(cls, "sentry", 1, true) then
		return "cons"
	end
	if string.find(cls, "generator", 1, true)
		or string.find(cls, "gen_", 1, true)
		or string.find(cls, "_gen", 1, true)
		or string.find(cls, "powersource", 1, true)
		or string.find(cls, "reactor", 1, true) then
		return "gen"
	end
	-- resource_node и всё остальное — накопители
	return "bank"
end

-- ======== Перекачка энергии по одной связи ========

local function TransferLink(l)
	if not IsValid(l.a) or not IsValid(l.b) then return end

	local ta = SB_JMOD.Identify and SB_JMOD.Identify(l.a) or nil
	local tb = SB_JMOD.Identify and SB_JMOD.Identify(l.b) or nil
	if not ta or not tb then return end

	local roleA = GetRole(l.a)
	local roleB = GetRole(l.b)

	if roleA == "gen" and roleB == "gen" then return end

	local allowAB = true
	local allowBA = true
	if roleA == "bank" and roleB == "gen" then
		allowAB = false
	elseif roleB == "bank" and roleA == "gen" then
		allowBA = false
	elseif roleA == "cons" then
		allowAB = false
	elseif roleB == "cons" then
		allowBA = false
	end

	local curA, capA = GetCharge(l.a, ta)
	local curB, capB = GetCharge(l.b, tb)
	if not curA or not curB or not capA or not capB then return end
	if capA <= 0 or capB <= 0 then return end

	local total = curA + curB
	if total <= 0 then return end

	local wantA = math.min(math.floor(total / 2), capA)
	local wantB = math.min(total - wantA, capB)
	if wantB < total - wantA then
		wantA = math.min(total - wantB, capA)
	elseif wantA < total - wantB then
		wantB = math.min(total - wantA, capB)
	end

	local function DoMove(src, srcT, dst, dstT, sCur, sWant, dCur, dWant, srcEnt, dstEnt)
		local surplus = sCur - sWant
		local deficit = dWant - dCur
		if surplus <= 0 or deficit <= 0 then return 0 end
		local give = math.min(surplus, deficit)
		if give <= 0 then return 0 end

		SetCharge(src, srcT, sCur - give)
		SetCharge(dst, dstT, dCur + give)

		if cvLog:GetBool() then
			print(("[SBJMOD] %s (%s) -> %s (%s): +%d"):format(
				srcEnt:GetClass(), srcEnt == l.a and roleA or roleB,
				dstEnt:GetClass(), dstEnt == l.a and roleA or roleB, give))
		end
		return give
	end

	if allowAB and curA > wantA then
		DoMove(l.a, ta, l.b, tb, curA, wantA, curB, wantB, l.a, l.b)
	end
	if allowBA and curB > wantB then
		DoMove(l.b, tb, l.a, ta, curB, wantB, curA, wantA, l.b, l.a)
	end
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

	if t == "sbres" or t == "sb" or t == "caf" then
		local rd = GetRD()
		if rd then
			local ok, v = pcall(rd.GetResourceAmount, e, "energy")
			print("RD.GetResourceAmount -> ok=" .. tostring(ok) .. " val=" .. tostring(v))
			if isfunction(rd.GetNetworkCapacity) then
				local okc, c = pcall(rd.GetNetworkCapacity, e, "energy")
				print("RD.GetNetworkCapacity -> ok=" .. tostring(okc) .. " val=" .. tostring(c))
			end
		else
			print("RD недоступен: нет ни глобального RD, ни CAF.GetAddon!")
		end
		if isfunction(e.GetResourceAmount) then
			local ok, v = pcall(e.GetResourceAmount, e, "energy")
			print("e:GetResourceAmount -> ok=" .. tostring(ok) .. " val=" .. tostring(v))
		else
			print("e:GetResourceAmount — метода на энтити нет")
		end
		if t == "sbres" and not rd then
			print("[SBJMOD] Внимание: для resource_node нужен RD, без него обмен невозможен.")
		end
	elseif t == "jmod" then
		if isfunction(e.GetElectricity) then
			local ok, v = pcall(e.GetElectricity, e)
			print("GetElectricity -> ok=" .. tostring(ok) .. " val=" .. tostring(v))
			print("MaxElectricity = " .. tostring(e.MaxElectricity))
		end
	else
		print("Тип не определён: тул не сможет связать это устройство.")
	end

	print("[SBJMOD] === Конец диагностики ===")
end)

print("[SBJMOD] Модуль transfer v7.3 загружен: JMod/SB/CAF + resource_node (RD)")
