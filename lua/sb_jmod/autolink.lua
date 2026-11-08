--[[
	SB <-> JMod Link — совместимость с Auto Link Tool из CAF/RD3 (сервер).
	Патчит rd3_dev_link / rd3_dev_link2 / rd3_dev_link3:
	  - клик по ноде: все JMod-устройства в радиусе ноды получают связь с ней;
	  - клик по JMod-банку: выбор цели 1, следующий клик — связь;
	  - ПКМ по JMod-банку: снятие наших связей с ним.
	Ресурсы RD не трогаем — пулы не смешиваются, двойного счёта нет.
]]

SB_JMOD.AutoLinkLoaded = true

local RD_MODES = { "rd3_dev_link", "rd3_dev_link2", "rd3_dev_link3" }

local function DefRate()
	local cv = GetConVar("sbjmod_defrate")
	if cv then return cv:GetInt() end
	return 50
end

local function IsLinkedTo(a, b)
	for _, l in ipairs(SB_JMOD.Links) do
		if (l.a == a and l.b == b) or (l.a == b and l.b == a) then return true end
	end
	return false
end

local function CountLinksOf(e)
	local n = 0
	for _, l in ipairs(SB_JMOD.Links) do
		if l.a == e or l.b == e then n = n + 1 end
	end
	return n
end

function SB_JMOD.AutoLinkHandle(self, tr)
	if not SERVER then return nil end
	local ply = self:GetOwner()
	if not IsValid(ply) then return nil end
	if not tr or not IsValid(tr.Entity) then return nil end
	local ent = tr.Entity
	if ent:IsPlayer() then return nil end

	local kind = SB_JMOD.Identify(ent)
	local sel = SB_JMOD.Sel(ply)

	-- 1) Клик по ноде RD: авто-подключение всех JMod-устройств в радиусе
	if ent.IsNode and isnumber(ent.netid) then
		local count = 0
		for _, e in ipairs(ents.FindInSphere(ent:GetPos(), ent.range or 512)) do
			if IsValid(e) and e ~= ent and SB_JMOD.Identify(e) == "jmod" and not IsLinkedTo(e, ent) then
				local ok = SB_JMOD.CreateLink(e, ent, DefRate(), false, 10)
				if ok then count = count + 1 end
			end
		end
		if count > 0 then
			ply:ChatPrint("[SBJMOD] Auto Link: подключено JMod-устройств: " .. count)
			SB_JMOD.SyncSoon()
		end
		if IsValid(sel.first) and SB_JMOD.Identify(sel.first) == "jmod" then
			local ok, msg = SB_JMOD.CreateLink(sel.first, ent, DefRate(), false, 10)
			ply:ChatPrint(ok and "[SBJMOD] Связь создана." or ("[SBJMOD] Ошибка: " .. tostring(msg)))
			SB_JMOD.SelClear(ply)
		end
		return nil -- штатная логика линкует RD-устройства как обычно
	end

	-- 2) Клик по JMod-устройству: выбор цели / создание связи
	if kind == "jmod" then
		if not IsValid(sel.first) then
			sel.first = ent
			sel.second = nil
			ply:ChatPrint("[SBJMOD] Auto Link: цель 1 = " .. ent:GetClass() ..
				" — теперь кликните по ноде или второму устройству.")
			return true
		end
		local ok, msg = SB_JMOD.CreateLink(sel.first, ent, DefRate(), false, 10)
		ply:ChatPrint(ok and "[SBJMOD] Связь создана." or ("[SBJMOD] Ошибка: " .. tostring(msg)))
		SB_JMOD.SelClear(ply)
		return true
	end

	-- 3) Отложенное JMod-выбрание + клик по RD/SB-устройству
	if IsValid(sel.first) and SB_JMOD.Identify(sel.first) == "jmod" and (kind == "caf" or kind == "sb") then
		local ok, msg = SB_JMOD.CreateLink(sel.first, ent, DefRate(), false, 10)
		ply:ChatPrint(ok and "[SBJMOD] Связь создана." or ("[SBJMOD] Ошибка: " .. tostring(msg)))
		SB_JMOD.SelClear(ply)
		return true
	end

	return nil
end

local function PatchTool(tool)
	if not istable(tool) or not isfunction(tool.LeftClick) then return false end
	if tool.SBJMOD_Patched then return true end

	local oldLC = tool.LeftClick
	tool.LeftClick = function(self, tr)
		local handled = SB_JMOD.AutoLinkHandle(self, tr)
		if handled ~= nil then return handled end
		return oldLC(self, tr)
	end

	if isfunction(tool.RightClick) then
		local oldRC = tool.RightClick
		tool.RightClick = function(self, tr)
			if SERVER and tr and IsValid(tr.Entity) and not tr.Entity:IsPlayer() then
				if SB_JMOD.Identify(tr.Entity) == "jmod" then
					local n = CountLinksOf(tr.Entity)
					if n > 0 then
						SB_JMOD.RemoveEntity(tr.Entity)
						self:GetOwner():ChatPrint("[SBJMOD] Auto Link: снято связей: " .. n)
						return true
					end
				end
			end
			return oldRC(self, tr)
		end
	end

	tool.SBJMOD_Patched = true
	print("[SBJMOD] Auto Link Tool (" .. tostring(tool.Mode or "?") .. ") теперь совместим с JMod")
	return true
end

timer.Create("SBJMOD_ALPatch", 2, 30, function()
	local gm = weapons.GetStored("gmod_tool")
	if not gm or not istable(gm.Tool) then return end
	for _, mode in ipairs(RD_MODES) do
		local tool = gm.Tool[mode]
		if tool and not tool.SBJMOD_Patched then
			PatchTool(tool)
		end
	end
end)
