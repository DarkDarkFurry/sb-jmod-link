--[[
	SB <-> JMod Link — файл тула для загрузчика тулгана.
	ВАЖНО: имя файла должно совпадать с TOOL.Mode (sb_jmodlink.lua).
	Вся логика — в SB_JMOD.ToolDef (lua/autorun/sb_jmod_link.lua).
]]

AddCSLuaFile()

TOOL.Mode = "sb_jmodlink"
TOOL.Category = "Construction"
TOOL.Name = "SB <-> JMod Link"
TOOL.Command = nil
TOOL.ConfigName = ""

if CLIENT then
	language.Add("tool.sb_jmodlink.name", "SB <-> JMod Link")
	language.Add("tool.sb_jmodlink.desc", "Двусторонняя перекачка энергии: Spacebuild <-> JMod")
	language.Add("tool.sb_jmodlink.left", "ЛКМ: быстрый режим — 1-й клик выбор, 2-й клик связь")
	language.Add("tool.sb_jmodlink.right", "ПКМ: пошагово — цель 1, цель 2, ещё клик — связь")
	language.Add("tool.sb_jmodlink.reload", "R: сбросить выбор")
	language.Add("tool.sb_jmodlink.0", "ЛКМ/ПКМ: выберите первое устройство (JMod, SB или CAF)")
	language.Add("tool.sb_jmodlink.1", "Теперь выберите второе устройство (ЛКМ свяжет сразу, ПКМ закрепит цель)")
	language.Add("tool.sb_jmodlink.2", "Ещё один ЛКМ/ПКМ — создать связь. R — сброс")
end

if SB_JMOD and SB_JMOD.ToolDef then
	for k, v in pairs(SB_JMOD.ToolDef) do
		TOOL[k] = v
	end
end
