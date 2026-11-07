--[[--------------------------------------------------------------------
	SB <-> JMod Link :: Rope (v5)
	Полностью отключён физический трос.
	Связь — чисто логическая: энергия передаётся без кабелей,
	устройства свободно перемещаются.
	Функции оставлены для совместимости с ядром.
--------------------------------------------------------------------]]

-- Полностью убирает любые следы физического троса (на случай старых связей)
function SB_JMOD.RopeRemove(l)
	if IsValid(l.cons) then l.cons:Remove() end
	if IsValid(l.ropeVis) then l.ropeVis:Remove() end
	l.cons, l.ropeVis, l.ropeLen, l.ropeLenBase, l.lastRopeRebuild = nil, nil, nil, nil, nil
end

-- Создаёт «пустую» связь: физика не нужна, ничего не спавним.
-- Оставляем функцию, чтобы ядро вызывало её без ошибок.
function SB_JMOD.RopeCreate(l)
	if not IsValid(l.a) or not IsValid(l.b) then return end
	SB_JMOD.RopeRemove(l)      -- страховка: убрать старое, если было
	l.norope = true            -- ядро знает: связи не нужен физический трос
end

-- Ничего не делаем: физического троса нет, подгонять нечего.
function SB_JMOD.RopeEnsure(l)
	-- Пустая функция для совместимости вызовов ядра
end

-- При загрузке модуля чистим старые верёвки, оставшиеся от прошлых версий.
if SB_JMOD.Links then
	for _, l in ipairs(SB_JMOD.Links) do
		SB_JMOD.RopeRemove(l)
	end
end

print("[SBJMOD] Модуль rope v5 загружен: физический трос полностью отключён, связь беспроводная")
