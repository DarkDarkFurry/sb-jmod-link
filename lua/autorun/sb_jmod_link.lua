--[[--------------------------------------------------------------------
	SB <-> JMod Link v7.9
	Беспроводная перекачка энергии: Spacebuild (energy) <-> JMod (Electricity).
	Совместимость с CAF (Resource Distribution): устройства распознаются
	через RD.GetEntityTable, Auto Link Tool умеет подключать JMod-банки
	к нодам RD-сети.
	Модули: transfer.lua (насос), rope.lua (совместимость, трос отключён),
	caf.lua (мост RD), autolink.lua (патч Auto Link Tool).
	Новое в 7.9: чекбокс в меню тула — чёрная плашка с белым текстом
	«Показывать соединения при наведении» (по умолчанию выключен).
	Связь невидимая (без кабелей и лучей), зарядка мгновенная.
]]

SB_JMOD = SB_JMOD or {}
SB_JMOD.Version = "7.9"
SB_JMOD.Links = SB_JMOD.Links or {}
SB_JMOD.NextID = SB_JMOD.NextID or 1

local NET_NAME = "SBJMOD_Links"
local NET_INTERVAL = 5
local TOOL_MODE = "sb_jmodlink"

SB_JMOD.NetReady = false

--------------------------------------------------------------------
-- ОПРЕДЕЛЕНИЕ ТУЛА (единый источник)
--------------------------------------------------------------------
SB_JMOD.ToolDef = SB_JMOD.ToolDef or {}
local D = SB_JMOD.ToolDef

D.Mode = TOOL_MODE
D.Category = "Construction"
D.Name = "SB <-> JMod Link"
D.ClientConVar = { hud_links = "0" }

D.Information = {
	{ name = "left" },
	{ name = "right" },
	{ name = "reload" },
	{ name = "0", stage = 0 },
	{ name = "1", stage = 1 },
	{ name = "2", stage = 2 },
}

D.SetStage = function(self, s)
	self.Stage = s
	if SERVER then
		local wep = self:GetWeapon()
		if IsValid(wep) then wep:SetNW2Int("SBJMOD_Stage", s) end
	end
end

D.GetStage = function(self)
	local wep = self:GetWeapon()
	if IsValid(wep) then return wep:GetNW2Int("SBJMOD_Stage", self.Stage or 0) end
	return self.Stage or 0
end

D.LeftClick = function(self, tr)
	if not SERVER then return true end
	local ply = self:GetOwner()
	if not IsValid(ply) then return true end
	local ent = (tr and IsValid(tr.Entity)) and tr.Entity or nil

	if not IsValid(ent) then
		ply:ChatPrint("[SBJMOD] Ни по чему не попали.")
		return true
	end

	if not SB_JMOD.Identify(ent) then
		ply:ChatPrint("[SBJMOD] Это не устройство SB/JMod/CAF: " .. ent:GetClass())
		return true
	end

	local sel = SB_JMOD.Sel(ply)

	if not IsValid(sel.first) then
		sel.first = ent
		self:SetStage(1)
		ply:ChatPrint("[SBJMOD] Выбрано: " .. ent:GetClass() .. " — второй ЛКМ создаст связь.")
		return true
	end

	local target = IsValid(sel.second) and sel.second or ent
	local ok, msg = SB_JMOD.CreateLink(sel.first, target)
	if ok then
		ply:ChatPrint("[SBJMOD] Связь создана: " .. sel.first:GetClass() .. " <-> " .. target:GetClass())
	else
		ply:ChatPrint("[SBJMOD] Ошибка: " .. tostring(msg))
	end
	SB_JMOD.SelClear(ply)
	self:SetStage(0)
	return true
end

D.RightClick = function(self, tr)
	if not SERVER then return true end
	local ply = self:GetOwner()
	if not IsValid(ply) then return true end
	local ent = (tr and IsValid(tr.Entity)) and tr.Entity or nil

	if not IsValid(ent) then
		ply:ChatPrint("[SBJMOD] Ни по чему не попали.")
		self:SetStage(0)
		return true
	end

	if not SB_JMOD.Identify(ent) then
		ply:ChatPrint("[SBJMOD] Это не устройство SB/JMod/CAF: " .. ent:GetClass())
		return true
	end

	local sel = SB_JMOD.Sel(ply)

	if not IsValid(sel.first) then
		sel.first = ent
		sel.second = nil
		self:SetStage(1)
		ply:ChatPrint("[SBJMOD] Цель 1: " .. ent:GetClass() .. " — теперь ПКМ по второй цели.")
	elseif not IsValid(sel.second) then
		if ent == sel.first then
			ply:ChatPrint("[SBJMOD] Это уже первая цель — выберите другую.")
			return true
		end
		sel.second = ent
		self:SetStage(2)
		ply:ChatPrint("[SBJMOD] Цель 2: " .. ent:GetClass() .. " — ещё ПКМ для создания связи.")
	else
		local ok, msg = SB_JMOD.CreateLink(sel.first, sel.second)
		if ok then
			ply:ChatPrint("[SBJMOD] Связь создана: " .. sel.first:GetClass() .. " <-> " .. sel.second:GetClass())
		else
			ply:ChatPrint("[SBJMOD] Ошибка: " .. tostring(msg))
		end
		SB_JMOD.SelClear(ply)
		self:SetStage(0)
	end

	return true
end

D.Reload = function(self, tr)
	if not SERVER then return true end
	local ply = self:GetOwner()
	if not IsValid(ply) then return true end
	local ent = (tr and IsValid(tr.Entity)) and tr.Entity or nil

	if IsValid(ent) and SB_JMOD.Identify(ent) then
		local n = SB_JMOD.RemoveLinks(ent)
		if n > 0 then
			ply:ChatPrint(("[SBJMOD] Убрано связей: %d (%s)."):format(n, ent:GetClass()))
			return true
		end
		SB_JMOD.SelClear(ply)
		self:SetStage(0)
		ply:ChatPrint("[SBJMOD] У " .. ent:GetClass() .. " нет связей. Выбор сброшен.")
		return true
	end

	SB_JMOD.SelClear(ply)
	self:SetStage(0)
	ply:ChatPrint("[SBJMOD] Выбор сброшен.")
	return true
end

D.BuildCPanel = function(CPanel)
	CPanel:AddControl("Header", { Description = "Беспроводная перекачка энергии: Spacebuild (energy) <-> JMod (Electricity). R по устройству — убрать его связи." })
	CPanel:AddControl("Label", { Text = "Зарядка: мгновенная (до полного)" })

	-- Чекбокс на чёрной плашке с белым текстом
	local wrap = vgui.Create("DPanel")
	wrap:SetTall(34)
	wrap:DockPadding(8, 5, 8, 5)
	wrap.Paint = function(_, w, h)
		draw.RoundedBox(4, 0, 0, w, h, Color(0, 0, 0, 230))
	end

	local chk = wrap:Add("DCheckBoxLabel")
	chk:Dock(FILL)
	chk:SetText("Показывать соединения при наведении")
	chk:SetTextColor(Color(255, 255, 255, 255))
	chk:SetFont("DermaDefaultBold")
	chk:SetConVar(TOOL_MODE .. "_hud_links")
	chk:SetValue(GetConVar(TOOL_MODE .. "_hud_links") and GetConVar(TOOL_MODE .. "_hud_links"):GetBool() or false)

	CPanel:AddPanel(wrap)

	CPanel:Button("Сбросить выбор", "sbjmod_reset")
end

--------------------------------------------------------------------
-- ПРИМЕНЕНИЕ ОПРЕДЕЛЕНИЯ К ЗАРЕГИСТРИРОВАННОМУ ТУЛУ
--------------------------------------------------------------------
function SB_JMOD.ReloadTool()
	local gmod_tool = weapons.GetStored("gmod_tool")
	if not gmod_tool then return false, "gmod_tool не загружен" end

	gmod_tool.Tool = gmod_tool.Tool or {}
	local tool = gmod_tool.Tool[TOOL_MODE]

	if not tool then
		return false, "тул не зарегистрирован загрузчиком — нужен полный перезапуск игры"
	end

	for k, v in pairs(SB_JMOD.ToolDef) do
		tool[k] = v
	end

	tool.Objects = tool.Objects or {}
	tool.LastMessage = tool.LastMessage or 0
	tool.Stage = tool.Stage or 0
	tool.Message = tool.Message or ""

	if isfunction(tool.CreateConVars) then
		pcall(function() tool:CreateConVars() end)
	end

	list.Set("Tool", TOOL_MODE, tool)
	return true
end

if SERVER then
	AddCSLuaFile("autorun/sb_jmod_link.lua")
	util.AddNetworkString(NET_NAME)
	SB_JMOD.NetReady = true

	function SB_JMOD.Identify(e)
		if not IsValid(e) then return nil end
		if isfunction(SB_JMOD.IdentifyExt) then
			local ok, t = pcall(SB_JMOD.IdentifyExt, e)
			if ok and t then return t end
		end
		local isJMod = isfunction(e.GetElectricity) and isfunction(e.SetElectricity)
		local isSB = isfunction(e.GetResourceAmount) and isfunction(e.SetResourceAmount)
		if isJMod and isSB then return "both" end
		if isJMod then return "jmod" end
		if isSB then return "sb" end

		-- CAF (Resource Distribution): устройство зарегистрировано в RD-сети
		local okRD, isCAF = pcall(function()
			if RD and isfunction(RD.GetEntityTable) then
				return RD.GetEntityTable(e) ~= nil
			end
			return false
		end)
		if okRD and isCAF then return "caf" end

		-- Запасной вариант: известные классы Life Support,
		-- если RD ещё не успел зарегистрировать девайс
		local cls = e:GetClass()
		for _, pref in ipairs({ "storage_", "generator_", "other_", "residue_", "reactor_" }) do
			if string.find(cls, pref, 1, true) then return "caf" end
		end
		return nil
	end

	function SB_JMOD.Sel(ply)
		ply.SBJMOD_Sel = ply.SBJMOD_Sel or {}
		return ply.SBJMOD_Sel
	end

	function SB_JMOD.SelClear(ply)
		if IsValid(ply) then ply.SBJMOD_Sel = {} end
	end

	function SB_JMOD.CreateLink(a, b)
		if not IsValid(a) or not IsValid(b) then return false, "объект недействителен" end
		if a == b then return false, "нельзя связать объект с самим собой" end
		if not SB_JMOD.Identify(a) then return false, "первый объект — не устройство SB/JMod/CAF" end
		if not SB_JMOD.Identify(b) then return false, "второй объект — не устройство SB/JMod/CAF" end
		for _, l in ipairs(SB_JMOD.Links) do
			if (l.a == a and l.b == b) or (l.a == b and l.b == a) then
				return false, "эти объекты уже связаны"
			end
		end
		local id = SB_JMOD.NextID
		SB_JMOD.NextID = id + 1
		local l = {
			id = id, a = a, b = b,
			res = "energy",
		}
		table.insert(SB_JMOD.Links, l)
		if isfunction(SB_JMOD.RopeCreate) then SB_JMOD.RopeCreate(l) end
		print("[SBJMOD] Связь #" .. id .. ": " .. a:GetClass() .. " <-> " .. b:GetClass())
		SB_JMOD.SyncSoon()
		return true, id
	end

	function SB_JMOD.RemoveLinks(e)
		local removed = 0
		for i = #SB_JMOD.Links, 1, -1 do
			local l = SB_JMOD.Links[i]
			if l.a == e or l.b == e then
				if isfunction(SB_JMOD.RopeRemove) then SB_JMOD.RopeRemove(l) end
				table.remove(SB_JMOD.Links, i)
				removed = removed + 1
			end
		end
		if removed > 0 then SB_JMOD.SyncSoon() end
		return removed
	end

	function SB_JMOD.RemoveEntity(e)
		SB_JMOD.RemoveLinks(e)
	end

	hook.Add("EntityRemoved", "SBJMOD_Cleanup", function(e)
		SB_JMOD.RemoveEntity(e)
	end)

	-- Синхронизация: передаём клиентам список связей (индексы энтити),
	-- чтобы HUD мог показывать, с чем устройство соединено
	function SB_JMOD.Sync()
		if not SB_JMOD.NetReady then return end
		local n = math.min(#SB_JMOD.Links, 255)
		net.Start(NET_NAME)
		net.WriteUInt(n, 8)
		for i = 1, n do
			local l = SB_JMOD.Links[i]
			net.WriteUInt(l.a:EntIndex() % 65536, 16)
			net.WriteUInt(l.b:EntIndex() % 65536, 16)
		end
		net.Broadcast()
	end

	function SB_JMOD.SyncSoon()
		timer.Create("SBJMOD_SyncOnce", 0.1, 1, SB_JMOD.Sync)
	end

	timer.Create("SBJMOD_SyncLoop", NET_INTERVAL, 0, SB_JMOD.Sync)

	timer.Create("SBJMOD_Pump", 1, 0, function()
		for i = #SB_JMOD.Links, 1, -1 do
			local l = SB_JMOD.Links[i]
			if not IsValid(l.a) or not IsValid(l.b) then
				if isfunction(SB_JMOD.RopeRemove) then SB_JMOD.RopeRemove(l) end
				table.remove(SB_JMOD.Links, i)
				SB_JMOD.SyncSoon()
			else
				if isfunction(SB_JMOD.RopeEnsure) then SB_JMOD.RopeEnsure(l) end
				if isfunction(SB_JMOD.Pump) then SB_JMOD.Pump(l) end
			end
		end
	end)

	concommand.Add("sbjmod_select", function(ply)
		local e = ply:GetEyeTrace().Entity
		if not IsValid(e) then ply:ChatPrint("[SBJMOD] Под прицелом ничего.") return end
		SB_JMOD.Sel(ply).first = e
		SB_JMOD.Sel(ply).second = nil
		ply:ChatPrint("[SBJMOD] Выбрано: " .. e:GetClass())
	end)

	concommand.Add("sbjmod_link", function(ply)
		local sel = SB_JMOD.Sel(ply)
		if not IsValid(sel.first) then ply:ChatPrint("[SBJMOD] Сначала выполните sbjmod_select.") return end
		local e = ply:GetEyeTrace().Entity
		if not IsValid(e) then ply:ChatPrint("[SBJMOD] Под прицелом ничего.") return end
		local ok, msg = SB_JMOD.CreateLink(sel.first, e)
		ply:ChatPrint(ok and ("[SBJMOD] Связь создана (#" .. tostring(msg) .. ").")
			or ("[SBJMOD] Ошибка: " .. tostring(msg)))
		if ok then SB_JMOD.SelClear(ply) end
	end)

	concommand.Add("sbjmod_reset", function(ply)
		SB_JMOD.SelClear(ply)
		ply:ChatPrint("[SBJMOD] Сброшено.")
	end)

	concommand.Add("sb_jmod_dump", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then return end
		print("=== SB <-> JMod Link v" .. SB_JMOD.Version .. ": связи ===")
		if #SB_JMOD.Links == 0 then print("(нет связей)") return end
		for _, l in ipairs(SB_JMOD.Links) do
			local ka = SB_JMOD.Identify(l.a) or "?"
			local kb = SB_JMOD.Identify(l.b) or "?"
			print(("#%d: %s [%s] <-> %s [%s], ресурс %s (беспроводная связь)"):format(
				l.id, l.a:GetClass(), ka, l.b:GetClass(), kb, l.res or "energy"))
		end
	end)

	concommand.Add("sbjmod_reload", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then
			ply:ChatPrint("[SBJMOD] Нужны права админа.")
			return
		end

		local files = {
			"autorun/sb_jmod_link.lua",
			"sb_jmod/transfer.lua",
			"sb_jmod/rope.lua",
			"sb_jmod/caf.lua",
			"sb_jmod/autolink.lua",
		}
		for _, f in ipairs(files) do
			local ok, err = pcall(include, f)
			print(ok and ("[SBJMOD] Перезагрузка: " .. f .. " OK")
				or ("[SBJMOD] Перезагрузка: " .. f .. " ОШИБКА: " .. tostring(err)))
		end

		local okT, errT = SB_JMOD.ReloadTool()
		print(okT and "[SBJMOD] Перезагрузка: тул OK"
			or ("[SBJMOD] Перезагрузка: тул ОШИБКА: " .. tostring(errT)))

		if IsValid(ply) then
			ply:ChatPrint("[SBJMOD] Перезагрузка завершена. Теперь sbjmod_reload_cl в своей консоли и тулган в руки заново.")
		end
	end)

	print("[SBJMOD] Ядро SB <-> JMod Link v" .. SB_JMOD.Version .. " загружено (server)")

	-- Загрузка модулей (отсутствие файла не роняет ядро)
	local modules = { "transfer", "rope", "caf", "autolink" }
	for _, m in ipairs(modules) do
		local ok, err = pcall(include, "sb_jmod/" .. m .. ".lua")
		if not ok then
			print("[SBJMOD] Модуль " .. m .. " ОШИБКА: " .. tostring(err))
		end
	end
end

if CLIENT then
	SB_JMOD.ClientLinks = SB_JMOD.ClientLinks or {}
	SB_JMOD.ClientNet = SB_JMOD.ClientNet or {}

	-- Показ надписи «Соединено:» при наведении. По умолчанию ВЫКЛЮЧЕНА.
	CreateClientConVar("sb_jmodlink_hud_links", "0", true, false,
		"Показывать соединения при наведении на устройство (0/1)")

	surface.CreateFont("SBJMOD_LinkHUD", {
		font = "Tahoma",
		size = 22,
		weight = 700,
		antialias = true,
	})

	surface.CreateFont("SBJMOD_LinkHUDSmall", {
		font = "Tahoma",
		size = 18,
		weight = 700,
		antialias = true,
	})

	-- Приём связей от сервера: строим таблицу «устройство -> список партнёров»
	net.Receive(NET_NAME, function()
		local n = net.ReadUInt(8)
		local adj = {}
		for i = 1, n do
			local ai = net.ReadUInt(16)
			local bi = net.ReadUInt(16)
			adj[ai] = adj[ai] or {}
			table.insert(adj[ai], bi)
			adj[bi] = adj[bi] or {}
			table.insert(adj[bi], ai)
		end
		SB_JMOD.ClientNet = adj
	end)

	-- Убираем старые лучи, если остались от прошлых версий
	hook.Remove("PostDrawTranslucentRenderables", "SBJMOD_Beams")
	hook.Remove("PostDrawOpaqueRenderables", "SBJMOD_Beams")

	-- Красивое имя класса: убираем технические префиксы
	local function PrettifyClass(cls)
		cls = cls:gsub("^ent_jack_gmod_", ""):gsub("^gmod_", "")
		cls = cls:gsub("^storage_", ""):gsub("^generator_", "")
		cls = cls:gsub("^other_", ""):gsub("^residue_", ""):gsub("^reactor_", "")
		return cls:sub(1, 1):upper() .. cls:sub(2)
	end

	-- Надпись при наведении: «Соединено:» + список партнёров с количеством.
	-- Работает только если конвар sb_jmodlink_hud_links = 1.
	hook.Add("HUDPaint", "SBJMOD_LinkHUD", function()
		local cv = GetConVar("sb_jmodlink_hud_links")
		if not cv or not cv:GetBool() then return end

		local ply = LocalPlayer()
		if not IsValid(ply) then return end

		local e = ply:GetEyeTrace().Entity
		if not IsValid(e) then return end

		local partners = SB_JMOD.ClientNet[e:EntIndex()]
		if not partners or #partners == 0 then return end

		-- Считаем партнёров по типам
		local counts, order = {}, {}
		for _, idx in ipairs(partners) do
			local p = Entity(idx)
			if IsValid(p) then
				local name = PrettifyClass(p:GetClass())
				if not counts[name] then
					counts[name] = 0
					table.insert(order, name)
				end
				counts[name] = counts[name] + 1
			end
		end

		if #order == 0 then return end

		local parts = {}
		for _, name in ipairs(order) do
			table.insert(parts, name .. " (" .. counts[name] .. ")")
		end

		local pos = e:LocalToWorld(e:OBBCenter()):ToScreen()
		if not pos.visible then return end

		local head = "Соединено:"
		local body = table.concat(parts, " - ")

		draw.SimpleText(head, "SBJMOD_LinkHUDSmall", pos.x, pos.y - 26,
			Color(120, 220, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText(body, "SBJMOD_LinkHUD", pos.x, pos.y,
			Color(255, 255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end)

	concommand.Add("sbjmod_reload_cl", function()
		local ok, err = pcall(include, "autorun/sb_jmod_link.lua")
		print(ok and "[SBJMOD] Клиент: ядро OK"
			or ("[SBJMOD] Клиент: ядро ОШИБКА: " .. tostring(err)))

		local okT, errT = SB_JMOD.ReloadTool()
		print(okT and "[SBJMOD] Клиент: тул OK — закройте меню и возьмите тулган заново."
			or ("[SBJMOD] Клиент: тул ОШИБКА: " .. tostring(errT)))
	end)

	print("[SBJMOD] Ядро SB <-> JMod Link v" .. SB_JMOD.Version .. " загружено (client)")
end
