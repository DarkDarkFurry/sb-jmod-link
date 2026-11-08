--[[--------------------------------------------------------------------
	SB <-> JMod Link — Spawnmenu-вкладка «SBJLink» (клиент)
	Своя верхняя вкладка рядом с Tool / Utilities / Options
	(spawnmenu.AddToolTab). Содержит:
	  - кнопку взятия тула SB <-> JMod Link;
	  - меню Fusion Generator: лимит энергии, ёмкость бака воды,
	    бесконечная вода, без повреждений;
	  - кнопки диагностики и обновления значений.

	Настройки живут в СЕРВЕРНЫХ конварах sbjmod_fusion_* (fusion.lua).
	Клиентские зеркала sb_jmodlink_* — только для привязки слайдеров.

	Формат net (совпадает с fusion.lua v2.0):
	  SBJMOD_FusionSet (серв->кл): UInt32 energy, UInt32 water, Bit inf, Bit nodmg
	  SBJMOD_FusionCmd (кл->серв): Bit apply; при apply=1 дальше
	                               UInt32 energy, UInt32 water, Bit inf, Bit nodmg
--------------------------------------------------------------------]]

if SERVER then return end

SB_JMOD = SB_JMOD or {}

--------------------------------------------------------------------
-- Клиентские зеркала (привязка слайдеров/чекбоксов).
-- На сервер уходит net-сообщение; сервер валидирует и рассылает
-- обратно — единый источник истины всегда сервер.
--------------------------------------------------------------------
CreateClientConVar("sb_jmodlink_energy_limit", "0", false, false,
	"Лимит энергии Fusion Generators, 0 = как в моде")
CreateClientConVar("sb_jmodlink_water_limit", "0", false, false,
	"Ёмкость бака воды Fusion Generators, 0 = как в моде")
CreateClientConVar("sb_jmodlink_infinite_water", "0", false, false,
	"Бесконечная вода в Fusion Generators (0/1)")
CreateClientConVar("sb_jmodlink_no_damage", "1", false, false,
	"Fusion Generators без повреждений (0/1)")

SB_JMOD.FusionSynced = false
SB_JMOD.FusionSent = {}

local CVars = {
	energy = "sb_jmodlink_energy_limit",
	water = "sb_jmodlink_water_limit",
	inf = "sb_jmodlink_infinite_water",
	nodmg = "sb_jmodlink_no_damage",
}

local function CV(name) return GetConVar(CVars[name]) end

local function ReadAll()
	return {
		energy = math.Clamp(math.floor(CV("energy"):GetFloat()), 0, 100000000),
		water = math.Clamp(math.floor(CV("water"):GetFloat()), 0, 100000000),
		inf = CV("inf"):GetBool(),
		nodmg = CV("nodmg"):GetBool(),
	}
end

local function SendAsk()
	if not LocalPlayer():IsValid() then return end
	net.Start("SBJMOD_FusionCmd")
	net.WriteBit(0)
	net.SendToServer()
end

local function SendApply(v)
	if not LocalPlayer():IsValid() then return end
	net.Start("SBJMOD_FusionCmd")
	net.WriteBit(1)
	net.WriteUInt(v.energy, 32)
	net.WriteUInt(v.water, 32)
	net.WriteBit(v.inf and 1 or 0)
	net.WriteBit(v.nodmg and 1 or 0)
	net.SendToServer()
end

--------------------------------------------------------------------
-- Синхронизация
--------------------------------------------------------------------
net.Receive("SBJMOD_FusionSet", function()
	local v = {
		energy = net.ReadUInt(32),
		water = net.ReadUInt(32),
		inf = net.ReadBit() == 1,
		nodmg = net.ReadBit() == 1,
	}
	SB_JMOD.FusionSynced = true
	SB_JMOD.FusionSent = v
	timer.Remove("SBJMOD_FusionAsk")

	local function set(name, val)
		local cv = CV(name)
		if cv and cv:GetInt() ~= val then cv:SetInt(val) end
	end
	set("energy", v.energy)
	set("water", v.water)
	set("inf", v.inf and 1 or 0)
	set("nodmg", v.nodmg and 1 or 0)
end)

-- При заходе на сервер сбрасываем синхронизацию, чтобы не отправить
-- серверу значения от прошлого сервера
hook.Add("InitPostEntity", "SBJMOD_FusionReset", function()
	SB_JMOD.FusionSynced = false
	SB_JMOD.FusionSent = {}
end)

local function TryAsk()
	if SB_JMOD.FusionSynced then return end
	SendAsk()
end

-- Если значения так и не пришли (сервер перезагрузили, мы зашли
-- раньше мода) — периодически просим, пока не получим
timer.Create("SBJMOD_FusionAsk", 3, 10, TryAsk)

-- Фоновая отправка: раз в 0,3 с, только если значения изменились
local nextPush = 0
hook.Add("Think", "SBJMOD_FusionPush", function()
	if not SB_JMOD.FusionSynced then return end
	if CurTime() < nextPush then return end
	nextPush = CurTime() + 0.3

	local v = ReadAll()
	local s = SB_JMOD.FusionSent
	if s.energy == v.energy and s.water == v.water
		and s.inf == v.inf and s.nodmg == v.nodmg then return end

	SB_JMOD.FusionSent = v
	SendApply(v)
end)

--------------------------------------------------------------------
-- Вкладка: вкладка + категория + опция с ControlPanel
--------------------------------------------------------------------
hook.Add("AddToolMenuTabs", "SBJMOD_Tab", function()
	spawnmenu.AddToolTab("SBJLink", "SBJLink", "icon16/link.png")
	spawnmenu.AddToolCategory("SBJLink", "sbjmod_main", "SB <-> JMod Link")
end)

hook.Add("PopulateToolMenu", "SBJMOD_Tab", function()
	spawnmenu.AddToolMenuOption("SBJLink", "sbjmod_main", "sbjmod_panel",
		"Link & Fusion Generator", "", "", function(CPanel)

		----------------------------------------------------------------
		-- Кнопка взятия инструмента
		----------------------------------------------------------------
		local btnTool = vgui.Create("DButton")
		btnTool:SetText("Take Tool: SB <-> JMod Link")
		btnTool:SetTall(44)
		btnTool.DoClick = function()
			RunConsoleCommand("gmod_tool", "sb_jmodlink")
			-- Закрываем меню спавна (метод Close есть у SpawnMenu-панели)
			if g_SpawnMenu and IsValid(g_SpawnMenu) and isfunction(g_SpawnMenu.Close) then
				g_SpawnMenu:Close()
			end
		end
		CPanel:AddPanel(btnTool)

		----------------------------------------------------------------
		-- Fusion Generator
		----------------------------------------------------------------
		CPanel:AddControl("Header", {
			Text = "Fusion Generator (SpaceBuild)",
			Description = "Настройки серверные: действуют на все генераторы на карте.",
		})

		local fp = vgui.Create("DPanel")
		fp:SetTall(230)
		fp:DockPadding(10, 8, 10, 8)
		fp.Paint = function(_, w, h)
			draw.RoundedBox(4, 0, 0, w, h, Color(0, 0, 0, 150))
		end
		CPanel:AddPanel(fp)

		-- Лимит энергии
		local sldE = fp:Add("DNumSlider")
		sldE:Dock(TOP)
		sldE:SetTall(40)
		sldE:SetText("Energy limit (0 = stock)")
		sldE:SetMin(0)
		sldE:SetMax(1000000)
		sldE:SetDecimals(0)
		sldE:SetConVar(CVars.energy)

		-- Предупреждение об опасности (критический режим >= 100000)
		local lblWarn = fp:Add("DLabel")
		lblWarn:Dock(TOP)
		lblWarn:SetTall(30)
		lblWarn:SetWrap(true)
		lblWarn:SetFont("Trebuchet18")
		lblWarn:SetTextColor(Color(255, 120, 120, 255))
		lblWarn:SetText("WARNING: at energy >= 100000 the reactor goes critical and explodes like a nuke when destroyed. Safe limit is below 100000.")
		local function UpdateWarn(val)
			lblWarn:SetVisible(val == 0 or val >= 100000)
		end
		UpdateWarn(CV("energy"):GetInt())
		sldE.OnValueChanged = function(_, v) UpdateWarn(math.floor(v or 0)) end

		-- Ёмкость бака воды
		local sldW = fp:Add("DNumSlider")
		sldW:Dock(TOP)
		sldW:SetTall(40)
		sldW:SetText("Water tank capacity (0 = stock)")
		sldW:SetMin(0)
		sldW:SetMax(100000)
		sldW:SetDecimals(0)
		sldW:SetConVar(CVars.water)

		-- Бесконечная вода
		local chkI = fp:Add("DCheckBoxLabel")
		chkI:Dock(TOP)
		chkI:SetTall(24)
		chkI:SetText("Infinite water (generator never runs dry)")
		chkI:SetTextColor(Color(120, 220, 255, 255))
		chkI:SetConVar(CVars.inf)

		-- Без повреждений
		local chkD = fp:Add("DCheckBoxLabel")
		chkD:Dock(TOP)
		chkD:SetTall(24)
		chkD:SetText("No damage (full immunity)")
		chkD:SetTextColor(Color(120, 255, 160, 255))
		chkD:SetConVar(CVars.nodmg)

		----------------------------------------------------------------
		-- Кнопки
		----------------------------------------------------------------
		local btnAsk = vgui.Create("DButton")
		btnAsk:SetText("Refresh values")
		btnAsk:SetTall(28)
		btnAsk.DoClick = function()
			SB_JMOD.FusionSynced = false
			TryAsk()
		end
		CPanel:AddPanel(btnAsk)

		local btnScan = vgui.Create("DButton")
		btnScan:SetText("Scan Fusion Generators (see console)")
		btnScan:SetTall(28)
		btnScan.DoClick = function()
			RunConsoleCommand("sbjmod_fusion_scan")
		end
		CPanel:AddPanel(btnScan)

		CPanel:AddControl("Label", {
			Text = "Changing the water capacity is applied to every generator already on the map.",
		})

		-- При открытии панели просим актуальные значения
		TryAsk()
	end)
end)

print("[SBJMOD] Вкладка SBJLink загружена (client)")
