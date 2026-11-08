--[[--------------------------------------------------------------------
	SB <-> JMod Link :: Fusion Generator (v2.1)
	Патч Fusion Generators (generator_energy_fusion) из SpaceBuild /
	SpaceBuild Life Support по реальной RD3-механике (проверено по
	исходникам github.com/spacebuild/spacebuild, файл
	lua/caf/addons/server/resourcedistribution.lua):

	  1. Без повреждений  — EntityTakeDamage блокируется + перехват
	     CAF Life Support DamageLS (урон от перегрева/нехватки воды).
	  2. Лимит воды       — ёмкость БАКА ПРИБОРА (меняется дельтой и в
	     nettable.maxvalue; сетевое значение воды не трогается).
	  3. Лимит энергии    — ЭТО КЛАМП ЗНАЧЕНИЯ СЕТИ (nettable value), а
	     не только ёмкости прибора: в RD3 «energy» хранится один раз на
	     всю сеть, поэтому лимит энергии ограничивает запас ВСЕЙ сети,
	     включая банки (storage_energy). Ёмкость юнита тоже режется
	     (min(заводская, лимит)) и учитывается в transfer.lua через
	     F.Capacity.
	  4. Бесконечная вода — ConsumeResource("water") ничего не тратит
	     + фоновый доливатель держит бак полным (на случай прямых
	     обращений к RD).

	Как правильно менять ЁМКОСТЬ и ЗАПАС в RD3 (почему старые версии
	«не работали»):
	  * SetResourceAmount в RD3 НЕ СУЩЕСТВУЕТ — pcall по нему молча
	    падал и ничего не происходило.
	  * RD.AddResource(ent, res, max, default) присваивает value =
	    default, то есть обнуляет/портит содержимое бака.
	  * Для устройства в сети (index.network ~= 0) все Supply/Consume/
	    Get работают с nettable[net].resources[res], а его maxvalue —
	    это СУММА ёмкостей всех приборов сети, пересчитываемая только
	    при Link/Unlink.
	  * У генератора собственная ёмкость по энергии крошечная
	    (5000*mult), а вся выработка копится в nettable — и именно
	    сетевое значение мода проверяет на >= 100000. Поэтому лимита
	    «только по ёмкости» мало: надо клампить ещё и net value.
	  Значит ёмкость меняем напрямую в ent_table И, следом, сдвигаем
	    дельту в nettable, а сверху клампим сетевое значение. Только
	    тогда лимит виден и RD, и HUD, и перекачке, и самому генератору.

	Механика ванильного генератора (lua/entities/generator_energy_fusion):
	  за тик требует 45*mult воды (Coolant_Increment), собственный бак
	  воды = 0.08*45*mult, при нехватке — DamageLS + дым;
	  energy >= 100000 -> critical -> Destruct = ядерный взрыв.

	Метод: на каждый распознанный генератор ставятся ПЕРСОНАЛЬНЫЕ
	переопределения методов (e.AddResource/e.ConsumeResource/
	e.SupplyResource/e.GetUnitCapacity) — глобальные таблицы RD не
	трогаем, другим устройствам ничего не мешает. Настройки читаются
	на лету. e.SupplyResource нужен потому, что генератор вливает
	5000*mult раз в СЕКУНДУ (generator_energy_fusion/init.lua:16, :298,
	:345 NextThink(CurTime()+1)) — одного 1-секундного таймера-клампа
	мало, сеть успевала переполниться сверх лимита между проверками;
	теперь amount подрезается ровно в момент вброса.

	Конвары (сервер, сохраняются):
	  sbjmod_fusion_energy_limit   — ПОТОЛОК сетевого запаса энергии
	                                 (nettable value; 0 = как в моде)
	  sbjmod_fusion_water_limit    — ёмкость бака воды прибора
	                                 (nettable value воды не трогает;
	                                 0 = как в моде)
	  sbjmod_fusion_infinite_water — бесконечная вода (0/1)
	  sbjmod_fusion_no_damage      — без повреждений (0/1, по умолчанию 1)
	  sbjmod_fusion_match          — доп. подстроки классов, через запятую

	Диагностика: sbjmod_fusion_scan. Управление: вкладка SBJLink.
--------------------------------------------------------------------]]

if CLIENT then return end

SB_JMOD.Fusion = SB_JMOD.Fusion or {}
local F = SB_JMOD.Fusion

local NET_SYNC = "SBJMOD_FusionSet" -- сервер -> клиент: текущие значения
local NET_CMD = "SBJMOD_FusionCmd"  -- клиент -> сервер: применить/запросить

--------------------------------------------------------------------
-- Конвары
--------------------------------------------------------------------
local CV_ENERGY = CreateConVar("sbjmod_fusion_energy_limit", "0",
	FCVAR_ARCHIVE, "Лимит энергии Fusion Generators, 0 = как в моде", 0, 100000000)

local CV_WATERCAP = CreateConVar("sbjmod_fusion_water_limit", "0",
	FCVAR_ARCHIVE, "Ёмкость бака воды Fusion Generators, 0 = как в моде", 0, 100000000)

local CV_INF = CreateConVar("sbjmod_fusion_infinite_water", "0",
	FCVAR_ARCHIVE, "Бесконечная вода в Fusion Generators (0/1)")

local CV_NODMG = CreateConVar("sbjmod_fusion_no_damage", "1",
	FCVAR_ARCHIVE, "Fusion Generators без повреждений (0/1)")

local CV_MATCH = CreateConVar("sbjmod_fusion_match", "",
	FCVAR_ARCHIVE, "Дополнительные подстроки в имени класса, через запятую")

function F.EnergyLimit() return CV_ENERGY:GetInt() end
function F.WaterLimit() return CV_WATERCAP:GetInt() end
function F.InfiniteWater() return CV_INF:GetBool() end
function F.NoDamage() return CV_NODMG:GetBool() end

--- Ёмкость с учётом лимита энергии (для transfer.lua)
function F.Capacity(cap)
	local lim = F.EnergyLimit()
	if lim <= 0 then return cap end
	if not isnumber(cap) or cap <= 0 then return lim end
	return math.min(cap, lim)
end

--------------------------------------------------------------------
-- RD-доступ
--------------------------------------------------------------------
function F.RD()
	if RD and isfunction(RD.GetEntityTable) then return RD end
	if CAF and isfunction(CAF.GetAddon) then
		local ok, rd = pcall(CAF.GetAddon, "Resource Distribution")
		if ok and rd and isfunction(rd.GetEntityTable) then return rd end
	end
	return nil
end

--------------------------------------------------------------------
-- Детект
--------------------------------------------------------------------
local cache = setmetatable({}, {__mode = "k"})

local function MatchExtra(cls)
	local s = CV_MATCH:GetString()
	if not s or s == "" then return false end
	for _, p in ipairs(string.Split(string.lower(s), ",")) do
		p = p:Trim()
		if p ~= "" and string.find(cls, p, 1, true) then return true end
	end
	return false
end

function SB_JMOD.IsFusionGenerator(e)
	if not IsValid(e) then return false end
	local c = cache[e]
	if c ~= nil then return c end

	local cls = string.lower(e:GetClass() or "")
	local hit = cls == "generator_energy_fusion"
		or string.find(cls, "fusion", 1, true) ~= nil
	if not hit then
		local ok, pn = pcall(function() return e:GetPrintName() or e.PrintName or "" end)
		if ok and isstring(pn) and string.find(string.lower(pn), "fusion", 1, true) then hit = true end
	end
	if not hit then hit = MatchExtra(cls) end

	cache[e] = hit
	return hit
end

F.Is = SB_JMOD.IsFusionGenerator

-- Распознаём для тула и перекачки
local OldIdentify = SB_JMOD.Identify
SB_JMOD.Identify = function(e)
	if not IsValid(e) then return nil end
	if SB_JMOD.IsFusionGenerator(e) then return "fusion" end
	return OldIdentify and OldIdentify(e) or nil
end

--------------------------------------------------------------------
-- Персональные переопределения методов генератора
--------------------------------------------------------------------
function F.Install(e)
	if not IsValid(e) then return end

	-- Запоминаем заводские ёмкости (для возврата «как в моде»).
	-- RD мог ещё не зарегистрировать устройство на первом вызове,
	-- поэтому пробуем при каждом Install, пока обе не зафиксируем.
	if not (e.SBJMOD_WaterOrig and e.SBJMOD_EnergyOrig) then
		local rd = F.RD()
		if rd then
			local t = rd.GetEntityTable(e)
			local w = t and t.resources and t.resources["water"]
			if w and isnumber(w.maxvalue) then e.SBJMOD_WaterOrig = w.maxvalue end
			local en = t and t.resources and t.resources["energy"]
			if en and isnumber(en.maxvalue) then e.SBJMOD_EnergyOrig = en.maxvalue end
		end
	end

	if e.SBJMOD_FusionInstalled then return end
	e.SBJMOD_FusionInstalled = true

	e.AddResource = function(self, res, maxamount, defaultvalue)
		local r = F.RD()
		if not r then return end
		if res == "water" and F.WaterLimit() > 0 then
			maxamount = F.WaterLimit()
		elseif res == "energy" and F.EnergyLimit() > 0 then
			maxamount = math.min(maxamount or 0, F.EnergyLimit())
		end
		return r.AddResource(self, res, maxamount, defaultvalue)
	end

	e.ConsumeResource = function(self, res, amount)
		local r = F.RD()
		if not r then return 0 end
		if res == "water" then
			if F.InfiniteWater() then return amount or 0 end
			local lim = F.WaterLimit()
			if lim > 0 and isnumber(amount) then amount = math.min(amount, lim) end
		end
		return r.ConsumeResource(self, res, amount)
	end

	e.GetUnitCapacity = function(self, res)
		local r = F.RD()
		if not r then return 0 end
		local c = r.GetUnitCapacity(self, res)
		if res == "energy" then c = F.Capacity(c) end
		if res == "water" and F.WaterLimit() > 0 then c = F.WaterLimit() end
		return c
	end

	-- Кламп на САМОМsupply: генератор вырабатывает раз в секунду
	-- (init.lua:345 NextThink(CurTime()+1)) по 5000*mult (init.lua:16,
	-- init.lua:298 SupplyResource("energy", inc)), поэтому 1-секундный
	-- таймер-кламп ловил передержку до 5000*mult сверх лимита. Теперь
	-- количество подрезается ровно в момент вброса, превысить лимит
	-- нельзя даже на одном тике.
	e.SupplyResource = function(self, res, amount)
		local r = F.RD()
		if not r then return 0 end
		if res == "energy" and isnumber(amount) and amount > 0 then
			local lim = F.EnergyLimit()
			if lim > 0 then
				-- sumconnectednets = false: считаем ТОЛЬКО свою сеть,
				-- иначе RD.GetResourceAmount по умолчанию (:1247 -> :1227)
				-- суммирует все соединённые сети и кламп был бы строже,
				-- чем ClampNet (он правит nettable[net].value).
				local ok, cur = pcall(r.GetResourceAmount, self, res, false)
				if ok and isnumber(cur) then
					local room = lim - cur
					if room <= 0 then return amount end
					if amount > room then amount = room end
				end
			end
		end
		return r.SupplyResource(self, res, amount)
	end
end

hook.Add("EntitySpawned", "SBJMOD_Fusion_Install", function(ent)
	if ent and ent:IsValid() and SB_JMOD.IsFusionGenerator(ent) then
		F.Install(ent)
	end
end)

local function InstallAll()
	for _, e in ipairs(ents.GetAll()) do
		if IsValid(e) and SB_JMOD.IsFusionGenerator(e) then F.Install(e) end
	end
end
timer.Create("SBJMOD_Fusion_InstallMap", 1, 10, function()
	if F.RD() then InstallAll() timer.Remove("SBJMOD_Fusion_InstallMap") end
end)

--------------------------------------------------------------------
-- 1. Без повреждений
--------------------------------------------------------------------
hook.Add("EntityTakeDamage", "SBJMOD_Fusion_NoDamage", function(target, dmg)
	if not F.NoDamage() then return end
	if not SB_JMOD.IsFusionGenerator(target) then return end
	dmg:SetDamage(0)
	if isfunction(dmg.ScaleDamage) then dmg:ScaleDamage(0) end
	return true
end)

-- Внутренний урон мода (перегрев/нехватка воды) идёт мимо EntityTakeDamage,
-- напрямую через CAF Life Support DamageLS — патчим его.
local function PatchDamageLS()
	if not CAF or not isfunction(CAF.GetAddon) then return false end
	local ok, ls = pcall(CAF.GetAddon, "Life Support")
	if not ok or not istable(ls) or not isfunction(ls.DamageLS) then return false end
	if ls.DamageLS.SBJMOD_Patched then return true end
	local old = ls.DamageLS
	ls.DamageLS = function(ent, dam)
		if F.NoDamage() and SB_JMOD.IsFusionGenerator(ent) then return end
		return old(ent, dam)
	end
	ls.DamageLS.SBJMOD_Patched = true
	print("[SBJMOD] Fusion: внутренний урон Life Support.DamageLS перехвачен")
	return true
end
timer.Create("SBJMOD_Fusion_PatchLS", 2, 30, function()
	if PatchDamageLS() then timer.Remove("SBJMOD_Fusion_PatchLS") end
end)

--------------------------------------------------------------------
-- 2. Ёмкость воды/энергии: применение лимитов к УЖЕ созданным
--    генераторам.
--
-- ВАЖНО (по исходникам RD3, lua/caf/addons/server/resourcedistribution.lua):
--   RD.AddResource(ent, res, max, default) ПРИСВАИВАЕТ value = default,
--   поэтому её для изменения ёмкости не используем.
--   Если устройство подключено к RD-сети (index.network ~= 0), то
--   nettable[net].resources[res].maxvalue хранит СУММУ ёмкостей всех
--   приборов сети и пересчитывается только при Link/Unlink.
--   Значит ёмкость правим и за юнит, и за сеть — иначе «лимит не
--   меняется»: сеть продолжала бы считать старый объём, а
--   SupplyResource/ConsumeResource работают именно с сетью.
--
-- КРИТИЧНО: лимит энергии — это ПОТОЛОК на сетевой запас (nettable
-- value). Поскольку все генераторы в одной сети делят один nettable,
-- изменение лимита энергии срезает запас ВСЕХ накопителей сети
-- (банков, генераторов), а не только fusion-генераторов. Если в сети
-- есть другие источники энергии — лимит их тоже ограничит. Лимит воды
-- такого эффекта НЕ имеет: он меняет только ёмкость бака каждого
-- генератора, а не сетевое значение.
--
-- Почему это происходит (RD3, resourcedistribution.lua):
--   SupplyResource: если index.network != 0 -> RD.SupplyNetResource(
--     netid, res, amount) (:719) -> сетевое значение растёт до
--     nettable[res].maxvalue (:727-736), excess spill in (:741-756).
--   Конкретно: nettable[net].resources[res].value — ЕДИНОЕ хранилище
--   для ВСЕХ приборов сети. Нет пер-приборного учёта.
--   SupplyNetResource clamps value to maxvalue (:727-736), then spills
--   left to connected nets (:741-756).
--   ApplyCap/EnergyCap clamps nettable value at F.EnergyLimit() (our
--   ClampNet closure), но это обрезает ЗАПАС СЕТИ — т.е. то, что
--   накоплено в storage_energy и любых других устройствах этой сети.
--
-- Практический вывод: держите реактор в ОТДЕЛЬНОЙ RD-сети (Link-tool
-- по генератору -> «Create new network»), тогда кламп энергии затрагивает
-- только его выработку; либо ставьте лимит не ниже суммарного запаса сети.
--------------------------------------------------------------------
local function ApplyCap(res, lim, origField)
	local rd = F.RD()
	if not rd then return end
	local canNet = isfunction(rd.GetNetTable)
	local doneNets -- сети обрабатываем один раз: их значения общие

	-- ЗНАЧЕНИЕ СЕТИ не может превышать лимит. Критично для энергии:
	-- у генератора собственная ёмкость по энергии крошечная
	-- (5000*mult), а вся выработка копится в nettable — именно сетевое
	-- значение мода проверяется на >= 100000.
	-- Для воды не делаем: lim там — объём бака прибора, а не планка
	-- для всей сети.
	local function ClampNet(netid)
		if res ~= "energy" or lim <= 0 then return end
		if not canNet or not netid or netid == 0 then return end
		if not doneNets then doneNets = {} end
		if doneNets[netid] then return end
		doneNets[netid] = true

		local nt = rd.GetNetTable(netid)
		local nr = nt and nt.resources and nt.resources[res]
		if nr and isnumber(nr.value) and nr.value > lim then
			nr.value = lim
			nr.haschanged = true
			nt.haschanged = true
		end
	end

	for _, e in ipairs(ents.GetAll()) do
		if IsValid(e) and SB_JMOD.IsFusionGenerator(e) then
			local t = rd.GetEntityTable(e)
			if istable(t) then
				local r = t.resources and t.resources[res]

				if r and isnumber(r.maxvalue) then
					if not e[origField] then e[origField] = r.maxvalue end
					local factory = e[origField] or r.maxvalue

					-- Вода: lim — это объём бака, ставим как есть (можно и
					-- больше заводского). Энергия: lim — ПОТОЛОК, выше
					-- заводской ёмкости не поднимаем.
					local newMax
					if lim > 0 then
						newMax = (res == "energy") and math.min(factory, lim) or lim
					else
						newMax = factory
					end

					-- ЁМКОСТЬ: юнит + дельта в сети
					if r.maxvalue ~= newMax then
						local oldMax = r.maxvalue
						r.maxvalue = newMax
						r.haschanged = true
						t.haschanged = true

						local netid = t.network
						if canNet and netid and netid ~= 0 then
							local nt = rd.GetNetTable(netid)
							local nr = nt and nt.resources and nt.resources[res]
							if nr and isnumber(nr.maxvalue) then
								nr.maxvalue = math.max(0, nr.maxvalue + (newMax - oldMax))
								-- Как это делает сам RD: запас сети не
								-- может превышать новую ёмкость сети
								if isnumber(nr.value) and nr.value > nr.maxvalue then
									nr.value = nr.maxvalue
								end
								nr.haschanged = true
								nt.haschanged = true
							end
						end
					end

					-- ЗНАЧЕНИЕ юнита не может превышать новую ёмкость
					if isnumber(r.value) and r.value > r.maxvalue then
						r.value = r.maxvalue
						r.haschanged = true
						t.haschanged = true
					end
				end

				-- Сеть клампим и когда у прибора нет собственной записи
				-- по ресурсу (RegisterNonStorageDevice) — иначе на таких
				-- генераторах лимит энергии не срабатывал бы вовсе
				ClampNet(t.network)
			end
		end
	end
end

local function ApplyWaterCap() ApplyCap("water", F.WaterLimit(), "SBJMOD_WaterOrig") end
local function ApplyEnergyCap() ApplyCap("energy", F.EnergyLimit(), "SBJMOD_EnergyOrig") end
local function ApplyAllCaps() ApplyWaterCap() ApplyEnergyCap() end

-- Генераторы продолжают вырабатывать энергию, поэтому одного применения
-- при смене ползунка мало: кламп ставим постоянно.
timer.Create("SBJMOD_Fusion_Caps", 1, 0, function()
	if F.EnergyLimit() <= 0 and F.WaterLimit() <= 0 then return end
	ApplyAllCaps()
end)

--------------------------------------------------------------------
-- 3. Бесконечная вода: фоновый долив (страховка от прямых вызовов RD)
--------------------------------------------------------------------
timer.Create("SBJMOD_Fusion_Refill", 0.5, 0, function()
	if not F.InfiniteWater() then return end
	local rd = F.RD()
	if not rd then return end
	for _, e in ipairs(ents.GetAll()) do
		if IsValid(e) and SB_JMOD.IsFusionGenerator(e) then
			local t = rd.GetEntityTable(e)
			local w = t and t.resources and t.resources["water"]
			if w and isnumber(w.maxvalue) and w.maxvalue > 0 and w.value < w.maxvalue then
				rd.SupplyResource(e, "water", w.maxvalue - w.value)
			end
		end
	end
end)

--------------------------------------------------------------------
-- 4. Синхронизация настроек: сервер <-> клиент (вкладка SBJLink)
--------------------------------------------------------------------
util.AddNetworkString(NET_SYNC)
util.AddNetworkString(NET_CMD)

local function WriteAll()
	net.WriteUInt(math.Clamp(CV_ENERGY:GetInt(), 0, 100000000), 32)
	net.WriteUInt(math.Clamp(CV_WATERCAP:GetInt(), 0, 100000000), 32)
	net.WriteBit(CV_INF:GetBool())
	net.WriteBit(CV_NODMG:GetBool())
end

local function SendTo(ply)
	if not IsValid(ply) then return end
	net.Start(NET_SYNC)
	WriteAll()
	net.Send(ply)
end

local function Broadcast()
	net.Start(NET_SYNC)
	WriteAll()
	net.Broadcast()
end

-- [apply?][energy][water][inf][nodmg]; apply=0 — «пришли текущие»
net.Receive(NET_CMD, function(_, ply)
	if not IsValid(ply) then return end
	if net.ReadBit() == 1 then
		local e = math.Clamp(net.ReadUInt(32), 0, 100000000)
		local w = math.Clamp(net.ReadUInt(32), 0, 100000000)
		local i = net.ReadBit() == 1
		local d = net.ReadBit() == 1
		local waterChanged = CV_WATERCAP:GetInt() ~= w
		local energyChanged = CV_ENERGY:GetInt() ~= e
		if energyChanged then CV_ENERGY:SetInt(e) end
		if waterChanged then CV_WATERCAP:SetInt(w) end
		if CV_INF:GetBool() ~= i then CV_INF:SetBool(i) end
		if CV_NODMG:GetBool() ~= d then CV_NODMG:SetBool(d) end
		if waterChanged or energyChanged then ApplyAllCaps() end
	end
	SendTo(ply)
end)

hook.Add("PlayerInitialSpawn", "SBJMOD_Fusion_Sync", function(ply)
	timer.Simple(1, function() SendTo(ply) end)
end)

-- Ёмкость правим не только по net-команде, но и при любой смене конвара
-- (консоль, srcds, другой админ) — иначе ползунок «не работает».
cvars.AddChangeCallback("sbjmod_fusion_energy_limit", function()
	ApplyEnergyCap()
	Broadcast()
end, "SBJMOD_Fusion")
cvars.AddChangeCallback("sbjmod_fusion_water_limit", function()
	ApplyWaterCap()
	Broadcast()
end, "SBJMOD_Fusion")
cvars.AddChangeCallback("sbjmod_fusion_infinite_water", function() Broadcast() end, "SBJMOD_Fusion")
cvars.AddChangeCallback("sbjmod_fusion_no_damage", function() Broadcast() end, "SBJMOD_Fusion")

-- Консоль: sbjmod_fusion_set <energy> <water> <inf 0/1> <nodmg 0/1>
concommand.Add("sbjmod_fusion_set", function(ply, _, args)
	if IsValid(ply) and not ply:IsAdmin() then return end
	-- Ёмкости пересчитывают change-callback'и конваров
	if args[1] then CV_ENERGY:SetInt(math.Clamp(math.floor(tonumber(args[1]) or 0), 0, 100000000)) end
	if args[2] then CV_WATERCAP:SetInt(math.Clamp(math.floor(tonumber(args[2]) or 0), 0, 100000000)) end
	if args[3] then CV_INF:SetBool(tonumber(args[3]) ~= 0) end
	if args[4] then CV_NODMG:SetBool(tonumber(args[4]) ~= 0) end
end)

--------------------------------------------------------------------
-- 5. Диагностика
--------------------------------------------------------------------
concommand.Add("sbjmod_fusion_scan", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local rd = F.RD()
	local n = 0
	print("[SBJMOD] === Fusion Generators ===")
	for _, e in ipairs(ents.GetAll()) do
		if IsValid(e) and SB_JMOD.IsFusionGenerator(e) then
			n = n + 1
			local info = ""
			if rd then
				local t = rd.GetEntityTable(e)
				local w = t and t.resources and t.resources["water"]
				local en = t and t.resources and t.resources["energy"]
				info = (" water=%s/%s energy=%s/%s net=%s"):format(
					tostring(w and w.value), tostring(w and w.maxvalue),
					tostring(en and en.value), tostring(en and en.maxvalue),
					tostring(t and t.network))
				if isfunction(rd.GetNetTable) and t and t.network and t.network ~= 0 then
					local nt = rd.GetNetTable(t.network)
					local nw = nt and nt.resources and nt.resources["water"]
					local ne = nt and nt.resources and nt.resources["energy"]
					info = info .. (" | NET water=%s/%s energy=%s/%s"):format(
						tostring(nw and nw.value), tostring(nw and nw.maxvalue),
						tostring(ne and ne.value), tostring(ne and ne.maxvalue))
				end
			else
				info = " RD НЕДОСТУПЕН!"
			end
			print(("%d) %s id=%d%s"):format(n, e:GetClass(), e:EntIndex(), info))
		end
	end
	if n == 0 then
		print("не найдено. Класс по умолчанию: generator_energy_fusion.")
		print("Свой класс: sbjmod_fusion_match <подстрока>")
	end
	print(("[SBJMOD] Всего: %d | энергия=%d | вода=%d | беск.вода=%s | без урона=%s"):format(
		n, F.EnergyLimit(), F.WaterLimit(), tostring(F.InfiniteWater()), tostring(F.NoDamage())))
end)

print("[SBJMOD] Модуль Fusion Generator v2.1 загружен (server). Ёмкость правится напрямую в ent_table+nettable (RD3)")
