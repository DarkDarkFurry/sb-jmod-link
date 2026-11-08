# SB <-> JMod Link

Беспроводная перекачка энергии между устройствами **JMod** и **SpaceBuild / SpaceBuild 2** в Garry's Mod.

[![Garry's Mod](https://img.shields.io/badge/GMod-1954857229-blue)](https://store.steampowered.com/app/4000/Garrys_Mod/)
[![License](https://img.shields.io/badge/license-All-Rights-Reserved-grey)](#)

## ⚡ Что делает

Связывает устройства разных модов **без кабелей и лучей** — энергия передаётся мгновенно по логической «невидимой» связи. Работает с:

| Мод | Ресурс | Тип устройств |
|---|---|---|
| **JMod** | `Electricity` (число) | Банки, генераторы, потребители |
| **SpaceBuild 3 / CAF** | `energy` (RD3) | `storage_energy`, `resource_node`, генераторы |
| **JMod + SB одновременно** | Оба | Автоматически |

### Fusion Generator

Встроенный модуль для `generator_energy_fusion` (SpaceBuild / SpaceBuild Life Support):

- 🛡️ **Без повреждений** — блокирует урон от перегрева/нехватки воды
- 💧 **Лимит воды** — меняет ёмкость бака конкретного прибора
- ⚡ **Лимит энергии** — ограничивает запас **всей RD-сети** (см. ниже ⚠️)
- ♾️ **Бесконечная вода** — генератор никогда не «сгорает»

## 📦 Установка

1. Скачайте последнюю версию из раздела [Releases](../../releases)
2. Распакуйте содержимое архива в `garrysmod/addons/sb_jmod_link/`
3. Перезапустите сервер / переподключитесь

> **Требования:** SpaceBuild 3 (CAF / Resource Distribution) опционально, но необходимо для работы с устройствами SB. JMod обязателен для работы с JMod-устройствами.

## 🎮 Как пользоваться

### Взятие тула

Откройте Spawn Menu (`Q`) → вкладка **SBJLink** → кнопка **Take Tool: SB <-> JMod Link**.

### Создание связи

| Клавиша | Действие |
|---|---|
| **ЛКМ** | Выбрать первое устройство → второе ЛКМ по партнёру |
| **ПКМ** | То же, но в режиме выбора второй цели |
| **R** | Убрать связи выбранного устройства |

### Вкладка SBJLink

Вкладка **SBJLink** в Spawn Menu содержит:

- Кнопку взятия тула
- Панель **Fusion Generator** с ползунками лимитов
- Кнопки **Refresh values** и **Scan Fusion Generators**

### HUD

Конвар `sb_jmodlink_hud_links` — показывать соединения при наведении (по умолчанию выключен).

## ⚙️ Конвары

| Конвар | По умолчанию | Описание |
|---|---|---|
| `sbjmod_fusion_energy_limit` | `0` | Лимит энергии (0 = как в моде). **Это потолок сетевого запаса** — ограничивает запас *всей* RD-сети, включая банки. |
| `sbjmod_fusion_water_limit` | `0` | Ёмкость бака воды генератора (0 = как в моде). Не трогает сетевое значение. |
| `sbjmod_fusion_infinite_water` | `0` | Бесконечная вода (0/1) |
| `sbjmod_fusion_no_damage` | `1` | Без повреждений (0/1) |
| `sbjmod_fusion_match` | `""` | Доп. подстроки классов для распознавания Fusion (через запятую) |
| `sbjmod_transferlog` | `0` | Лог перекачки в консоль (0/1) |

## 🛠 Консольные команды

| Команда | Описание |
|---|---|
| `sbjmod_fusion_scan` | Показать все Fusion-генераторы с их RD-значениями |
| `sbjmod_fusion_set <E> <W> <inf> <nodmg>` | Установить все параметры Fusion сразу |
| `sbjmod_test_energy` | Диагностика устройства под прицелом |
| `sbjmod_select` | Выбрать устройство под прицелом (альтернативный путь) |
| `sbjmod_link` | Создать связь с выбранным устройством |
| `sbjmod_reset` | Сбросить выбор |
| `sb_jmod_dump` | Показать все связи (админ) |
| `sbjmod_reload` | Перезагрузить все модули (админ) |
| `sbjmod_reload_cl` | Перезагрузить клиентскую часть |

## ⚠️ Важное: лимит энергии и RD-сеть

В Resource Distribution (RD3) «energy» хранится **одно общее значение** на всю сеть (`nettable[netid].resources["energy"].value`). Все приборы в одной сети делят один накопитель.

Поэтому **лимит энергии ограничивает запас ВСЕЙ сети**, включая:

- `storage_energy` банки
- Другие генераторы в той же RD-сети
- Любой прибор, подключённый к этой сети через Link Tool

**Рекомендация:** используйте Link Tool, чтобы создать **отдельную RD-сеть** для каждого Fusion-генератора (клик по генератору → «Create new network»). Тогда кламп энергии затрагивает только его выработку.

> Лимит воды такого эффекта **не имеет** — он меняет только ёмкость бака конкретного прибора, а не сетевое значение.

## 🏗 Архитектура

```
lua/
├── autorun/
│   ├── sb_jmod_link.lua      ← Ядро: тул, сеть, клиент-сервер
│   ├── sb_jmod_hotreload.lua ← Хотрелоад для разработки
│   ├── client/
│   │   └── sb_jmod_tab.lua   ← Вкладка SBJLink (Spawn Menu)
│   └── server/
│       └── sb_jmod_ezbattery.lua.disabled
├── sb_jmod/
│   ├── caf.lua               ← Мост к CAF / Resource Distribution
│   ├── autolink.lua          ← Совместимость с Auto Link Tool
│   ├── transfer.lua          ← Перекачка энергии по связям
│   ├── rope.lua              ← Физический трос (отключён)
│   └── fusion.lua            ← Патч Fusion Generators
└── weapons/gmod_tool/stools/sb_jmodlink.lua
```

### Модули

| Модуль | Роль |
|---|---|
| `transfer.lua` | Насос: перекачка по связям (0.1s интервал), правила генератор→банк/потребитель |
| `caf.lua` | Мост к RD3: получение/запись ресурсов через CAF API |
| `autolink.lua` | Патч Auto Link Tool для работы с JMod-устройствами |
| `fusion.lua` | Fusion Generator: без урона, лимиты воды/энергии, бесконечная вода |
| `rope.lua` | Физический трос — полностью отключён, связь беспроводная |

## 🔧 Совместимость

- ✅ JMod (все версии с API `GetElectricity`/`SetElectricity`)
- ✅ SpaceBuild 3 / SpaceBuild 2 с CAF и Resource Distribution
- ✅ Auto Link Tool (из CAF)
- ✅ Fusion Generator (SpaceBuild / SpaceBuild Life Support)
- ⚠️ Другие моды, использующие RD3 — работают через `caf.lua` и `autolink.lua`
- ❌ Моды с собственным механизмом ресурсов (без RD3/CAF) — не подключаются

## 📝 Совместимость с RD3

Мод написан на основе анализа исходников Spacebuild (файл `resourcedistribution.lua`):

- `RD.GetNetTable` / `RD.GetEntityTable` — используются для доступа к таблицам RD
- `RD.AddResource` — НЕ используется для изменения ёмкости (сбрасывает `value`)
- `RD.SupplyResource` / `RD.ConsumeResource` — основной путь перекачки
- Персональные переопределения методов (`e.AddResource`, `e.SupplyResource`) вместо глобальных хуков

## 📄 Лицензия

Все права защищены. Запрещено распространение без разрешения автора.
