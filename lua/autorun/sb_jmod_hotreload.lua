--[[
	SB <-> JMod Link — Hot Reload v1.0
	Умная горячая перезагрузка аддона без смены карты:
	  - сканирует lua/autorun/sb_jmod*.lua, lua/autorun/server/sb_jmod_*.lua,
	    lua/autorun/client/sb_jmod_*.lua и lua/sb_jmod/*.lua;
	  - заново инициализирует изменённые и добавленные файлы;
	  - автоматически перезагружает клиентскую часть у всех игроков по сети.
	Команда: sbjmod_reload (админ).
	Файл кладётся в lua/autorun/sb_jmod_hotreload.lua (общий для сервера и клиента).

	Важно: код мода написан как SB_JMOD.Links = SB_JMOD.Links or {}, поэтому
	повторное выполнение файлов сохраняет активные связи и настройки —
	перезагрузка «на живую» безопасна.
]]

SB_JMOD = SB_JMOD or {}

local NET_RELOAD = "SBJMOD_ReloadCL"

--------------------------------------------------------------------
-- СЕРВЕР
--------------------------------------------------------------------
if SERVER then
	util.AddNetworkString(NET_RELOAD)
	AddCSLuaFile() -- отправляем этот файл клиентам, чтобы net.Receive заработал

	local function LoadFile(rel, out)
		local ok, err = pcall(include, rel)
		if ok then
			table.insert(out, "OK: " .. rel)
		else
			table.insert(out, "ОШИБКА: " .. rel .. " — " .. tostring(err))
		end
	end

	local function SortedGlob(pattern)
		local files = file.Find(pattern, "LUA") or {}
		table.sort(files)
		return files
	end

	--- Полная горячая перезагрузка мода. Возвращает список строк-отчёта.
	function SB_JMOD.HotReload()
		local out = { "[SBJMOD] Горячая перезагрузка — " .. os.date("%H:%M:%S") }
		local loaded = 0

		-- 1. Ядро (общее: тул, связи, команды)
		LoadFile("autorun/sb_jmod_link.lua", out); loaded = loaded + 1

		-- 2. Серверные автораны мода: sb_jmod_*.lua (батарея и будущие модули)
		for _, f in ipairs(SortedGlob("autorun/server/sb_jmod_*.lua")) do
			LoadFile("autorun/server/" .. f, out); loaded = loaded + 1
		end

		-- 3. Модули из папки sb_jmod: transfer, rope, caf, autolink и новые
		for _, f in ipairs(SortedGlob("sb_jmod/*.lua")) do
			LoadFile("sb_jmod/" .. f, out); loaded = loaded + 1
		end

		-- 4. Применяем определение тула заново
		if isfunction(SB_JMOD.ReloadTool) then
			local okT, errT = SB_JMOD.ReloadTool()
			table.insert(out, okT and "OK: тул перезагружен"
				or "ОШИБКА тула: " .. tostring(errT))
		end

		-- 5. Клиенты перезагружаются сами по сети
		net.Start(NET_RELOAD)
		net.Broadcast()

		table.insert(out, ("Готово: перезагружено файлов: %d. Клиенты обновятся автоматически."):format(loaded))
		return out
	end

	-- Заменяем старую команду sbjmod_reload на умную
	concommand.Add("sbjmod_reload", function(ply)
		if IsValid(ply) and not ply:IsAdmin() then
			ply:ChatPrint("[SBJMOD] Нужны права админа.")
			return
		end
		local lines = SB_JMOD.HotReload()
		for _, s in ipairs(lines) do
			if IsValid(ply) then ply:ChatPrint(s) else print(s) end
		end
	end)

	print("[SBJMOD] Hot Reload v1.0 загружен (server). Команда: sbjmod_reload")
end

--------------------------------------------------------------------
-- КЛИЕНТ
--------------------------------------------------------------------
if CLIENT then
	net.Receive(NET_RELOAD, function()
		-- 1. Ядро
		local ok, err = pcall(include, "autorun/sb_jmod_link.lua")
		if not ok then
			print("[SBJMOD] Клиент: ядро ОШИБКА: " .. tostring(err))
		end

		-- 2. Клиентские файлы мода: sb_jmod_*.lua
		local n = 0
		local cl = file.Find("autorun/client/sb_jmod_*.lua", "LUA") or {}
		table.sort(cl)
		for _, f in ipairs(cl) do
			local ok2, err2 = pcall(include, "autorun/client/" .. f)
			if ok2 then n = n + 1
			else print("[SBJMOD] Клиент: " .. f .. " ОШИБКА: " .. tostring(err2)) end
		end

		-- 3. Тул
		if isfunction(SB_JMOD.ReloadTool) then
			local ok3, err3 = SB_JMOD.ReloadTool()
			print(ok3
				and ("[SBJMOD] Клиент перезагружен: ядро + " .. n .. " файл(ов). Закройте меню спавна и возьмите тулган заново.")
				or "[SBJMOD] Клиент: тул ОШИБКА: " .. tostring(err3))
		end
	end)

	print("[SBJMOD] Hot Reload v1.0 загружен (client)")
end
