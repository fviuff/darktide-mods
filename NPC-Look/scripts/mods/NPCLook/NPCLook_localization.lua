return {
    command_empty = {
        en = "leave a slot explicitly empty: /npclook_empty <slot>",
        ru = "оставьте слот явно пустым: /npclook_empty <слот>",
        ["zh-cn"] = "将指定槽位置空：/npclook_empty <槽位>",
    },
    command_export = {
        en = "export the current visual look",
        ru = "экспортировать текущий визуальный образ",
        ["zh-cn"] = "导出当前外观配置",
    },
    command_find = {
        en = "search items: /npclook_find <filter> [slot_filter]",
        ru = "поиск предметов: /npclook_find <фильтр> [фильтр_слота]",
        ["zh-cn"] = "搜索物品：/npclook_find <关键词> [槽位筛选]",
    },
    command_fullhide = {
        en = "hide entire character",
        ru = "скрыть всего персонажа",
        ["zh-cn"] = "隐藏整个人物模型",
    },
    command_hide = {
        en = "hide slot: /npclook_hide <slot>",
        ru = "скрыть слот: /npclook_hide <слот>",
        ["zh-cn"] = "隐藏槽位：/npclook_hide <槽位>",
    },
    command_inspect = {
        en = "inspect item: /npclook_inspect <item>",
        ru = "осмотреть предмет: /npclook_inspect <предмет>",
        ["zh-cn"] = "检视物品：/npclook_inspect <物品>",
    },
    command_load = {
        en = "wear an exported look: /npclook_load <code>",
        ru = "надеть экспортированный образ: /npclook_load <код>",
        ["zh-cn"] = "载入导出外观：/npclook_load <代码>",
    },
    command_load_alias = {
        en = "alias for /npclook_load",
        ru = "псевдоним для /npclook_load",
        ["zh-cn"] = "/npclook_load 的别名指令",
    },
    command_open = {
        en = "open NPC Look",
        ru = "открыть окно NPC Look",
        ["zh-cn"] = "打开NPC外观编辑器",
    },
    command_outfit = {
        en = "preset or filter: /npclook_outfit <name>",
        ru = "пресет или фильтр: /npclook_outfit <имя>",
        ["zh-cn"] = "加载预设外观：/npclook_outfit <名称>",
    },
    command_presets = {
        en = "list presets",
        ru = "список пресетов",
        ["zh-cn"] = "列出所有预设",
    },
    command_refresh = {
        en = "reapply the current look",
        ru = "применить текущий образ заново",
        ["zh-cn"] = "重新应用当前外观",
    },
    command_replace = {
        en = "full model replace: /npclook_replace <name>",
        ru = "полная замена модели: /npclook_replace <имя>",
        ["zh-cn"] = "完整替换模型：/npclook_replace <模型名>",
    },
    command_reset = {
        en = "restore the original look",
        ru = "восстановить исходный образ",
        ["zh-cn"] = "恢复原始外观",
    },
    command_show = {
        en = "restore slot: /npclook_show <slot>",
        ru = "восстановить слот: /npclook_show <слот>",
        ["zh-cn"] = "恢复槽位显示：/npclook_show <槽位>",
    },
    command_status = {
        en = "mod state",
        ru = "состояние мода",
        ["zh-cn"] = "查看模组运行状态",
    },
    command_wear = {
        en = "wear item: /npclook_wear <slot> <item>",
        ru = "надеть предмет: /npclook_wear <слот> <предмет>",
        ["zh-cn"] = "穿戴物品：/npclook_wear <槽位> <物品>",
    },
    command_wear_alias = {
        en = "alias for /npclook_wear <slot> <item>",
        ru = "псевдоним для /npclook_wear <слот> <предмет>",
        ["zh-cn"] = "/npclook_wear 的别名指令",
    },
    echo_applied_slots = {
        en = "Applied %d slot(s)",
        ru = "Применено %d слотов",
        ["zh-cn"] = "已应用 %d 个槽位",
    },
    echo_apply_failed = {
        en = "Look apply failed: %s",
        ru = "Ошибка применения образа: %s",
        ["zh-cn"] = "外观应用失败：%s",
    },
    echo_auto_slot = {
        en = " -> %s%s",
        ru = " -> %s%s",
        ["zh-cn"] = " -> %s%s",
    },
    echo_auto_slot_from = {
        en = " (from %s)",
        ru = " (из %s)",
        ["zh-cn"] = "（源自 %s）",
    },
    echo_bad_slot = {
        en = "Bad slot: %s",
        ru = "Неверный слот: %s",
        ["zh-cn"] = "无效槽位：%s",
    },
    echo_character_hidden = {
        en = "Character hidden",
        ru = "Персонаж скрыт",
        ["zh-cn"] = "人物已隐藏",
    },
    echo_code = {
        en = "NPC Look code:",
        ru = "Код NPC Look:",
        ["zh-cn"] = "NPC外观代码：",
    },
    echo_code_copied = {
        en = "NPC Look code copied to the clipboard:",
        ru = "Код NPC Look скопирован в буфер обмена:",
        ["zh-cn"] = "NPC外观代码已复制至剪贴板：",
    },
    echo_code_failed = {
        en = "NPC Look code failed: %s",
        ru = "Ошибка кода NPC Look: %s",
        ["zh-cn"] = "外观代码处理失败：%s",
    },
    echo_code_loaded = {
        en = "Loaded NPC Look code: %d entries",
        ru = "Загружен код NPC Look: %d записей",
        ["zh-cn"] = "外观代码载入完成，共 %d 项配置",
    },
    echo_empty = {
        en = "Empty: %s",
        ru = "Пусто: %s",
        ["zh-cn"] = "置空：%s",
    },
    echo_empty_failed = {
        en = "Empty failed: %s",
        ru = "Ошибка очистки: %s",
        ["zh-cn"] = "置空操作失败：%s",
    },
    echo_empty_list = {
        en = "Empty: %s",
        ru = "Пусто: %s",
        ["zh-cn"] = "置空：%s",
    },
    echo_equip_failed = {
        en = "NPC Look equip failed: %s",
        ru = "Ошибка экипировки NPC Look: %s",
        ["zh-cn"] = "物品穿戴失败：%s",
    },
    echo_export_failed = {
        en = "Could not export NPC Look: %s",
        ru = "Не удалось экспортировать NPC Look: %s",
        ["zh-cn"] = "无法导出外观配置：%s",
    },
    echo_full_hide_failed = {
        en = "Full hide failed: %s",
        ru = "Ошибка полного скрытия: %s",
        ["zh-cn"] = "整体隐藏失败：%s",
    },
    echo_hidden = {
        en = "Hidden: %s",
        ru = "Скрыто: %s",
        ["zh-cn"] = "已隐藏：%s",
    },
    echo_hidden_list = {
        en = "Hidden: %s",
        ru = "Скрыто: %s",
        ["zh-cn"] = "已隐藏：%s",
    },
    echo_hide_failed = {
        en = "Hide failed: %s",
        ru = "Ошибка скрытия: %s",
        ["zh-cn"] = "隐藏操作失败：%s",
    },
    echo_inspect_field = {
        en = " %s: %s",
        ru = " %s: %s",
        ["zh-cn"] = " %s：%s",
    },
    echo_item = {
        en = "Item: %s",
        ru = "Предмет: %s",
        ["zh-cn"] = "物品：%s",
    },
    echo_match_count = {
        en = "%d matches for '%s':",
        ru = "%d совпадений для '%s':",
        ["zh-cn"] = "关键词「%s」匹配到 %d 条结果：",
    },
    echo_match_row = {
        en = " %s [%s]",
        ru = " %s [%s]",
        ["zh-cn"] = " %s [%s]",
    },
    echo_missing = {
        en = "Missing: %s",
        ru = "Отсутствует: %s",
        ["zh-cn"] = "缺失：%s",
    },
    echo_no_auto_slot = {
        en = " -> no auto-slot for '%s'; use /npclook_wear <slot> <item>",
        ru = " -> нет автоматического слота для '%s'; используйте /npclook_wear <слот> <предмет>",
        ["zh-cn"] = " ->「%s」无自动匹配槽位，请使用 /npclook_wear <槽位> <物品>",
    },
    echo_no_changes = {
        en = "No changes",
        ru = "Нет изменений",
        ["zh-cn"] = "未产生任何改动",
    },
    echo_no_destination = {
        en = "No destination was supplied and the item has no usable slot hint",
        ru = "Не указан слот назначения, и у предмета нет подсказки по слоту",
        ["zh-cn"] = "未指定目标槽位，且该物品无可用槽位信息",
    },
    echo_no_match = {
        en = "No match for '%s'",
        ru = "Нет совпадений для '%s'",
        ["zh-cn"] = "未找到匹配「%s」的内容",
    },
    echo_no_matches = {
        en = "No matches",
        ru = "Нет совпадений",
        ["zh-cn"] = "无匹配结果",
    },
    echo_nothing_reset = {
        en = "Nothing to reset",
        ru = "Нечего сбрасывать",
        ["zh-cn"] = "没有需要重置的内容",
    },
    echo_outfit = {
        en = "Outfit",
        ru = "Наряд",
        ["zh-cn"] = "外观套装",
    },
    echo_outfit_applied = {
        en = "%s applied: %d slot(s)",
        ru = "%s применён: %d слотов",
        ["zh-cn"] = "套装「%s」已应用，共 %d 个槽位",
    },
    echo_outfit_failed = {
        en = "Outfit failed: %s",
        ru = "Ошибка наряда: %s",
        ["zh-cn"] = "套装加载失败：%s",
    },
    echo_override_row = {
        en = " %s -> %s",
        ru = " %s -> %s",
        ["zh-cn"] = " %s -> %s",
    },
    echo_overrides = {
        en = "Overrides:",
        ru = "Переопределения:",
        ["zh-cn"] = "覆盖配置：",
    },
    echo_preset = {
        en = "Preset",
        ru = "Пресет",
        ["zh-cn"] = "预设",
    },
    echo_presets = {
        en = "Presets: %s",
        ru = "Пресеты: %s",
        ["zh-cn"] = "可用预设：%s",
    },
    echo_refine = {
        en = "refine or use nexusmods.com/warhammer40kdarktide/mods/822 to export master_items.",
        ru = " ...уточните или используйте мод Sigismund для экспорта master_items",
        ["zh-cn"] = " …优化搜索条件，或使用nexusmods.com/warhammer40kdarktide/mods/822导出 master_items",
    },
    echo_refresh_failed = {
        en = "Refresh failed: %s",
        ru = "Ошибка обновления: %s",
        ["zh-cn"] = "刷新失败：%s",
    },
    echo_refreshed = {
        en = "Refreshed",
        ru = "Обновлено",
        ["zh-cn"] = "刷新完成",
    },
    echo_replace_failed = {
        en = "Replace failed: %s",
        ru = "Ошибка замены: %s",
        ["zh-cn"] = "模型替换失败：%s",
    },
    echo_replaced = {
        en = "Replaced: %d equipped",
        ru = "Заменено: %d экипировано",
        ["zh-cn"] = "替换完成，已载入 %d 件物品",
    },
    echo_reset = {
        en = "Reset",
        ru = "Сброшено",
        ["zh-cn"] = "已重置",
    },
    echo_restore_failed = {
        en = "Restore failed: %s",
        ru = "Ошибка восстановления: %s",
        ["zh-cn"] = "恢复操作失败：%s",
    },
    echo_restored = {
        en = "Restored: %s",
        ru = "Восстановлено: %s",
        ["zh-cn"] = "已恢复：%s",
    },
    echo_showing = {
        en = "Showing %d of %d for '%s':",
        ru = "Показано %d из %d для '%s':",
        ["zh-cn"] = "关键词「%s」，展示 %d / %d 条结果：",
    },
    echo_usage_empty = {
        en = "Usage: /npclook_empty <slot>",
        ru = "Использование: /npclook_empty <слот>",
        ["zh-cn"] = "用法：/npclook_empty <槽位>",
    },
    echo_usage_find = {
        en = "Usage: /npclook_find <filter> [slot_filter]",
        ru = "Использование: /npclook_find <фильтр> [фильтр_слота]",
        ["zh-cn"] = "用法：/npclook_find <关键词> [槽位筛选]",
    },
    echo_usage_hide = {
        en = "Usage: /npclook_hide <slot>",
        ru = "Использование: /npclook_hide <слот>",
        ["zh-cn"] = "用法：/npclook_hide <槽位>",
    },
    echo_usage_inspect = {
        en = "Usage: /npclook_inspect <item>",
        ru = "Использование: /npclook_inspect <предмет>",
        ["zh-cn"] = "用法：/npclook_inspect <物品>",
    },
    echo_usage_load = {
        en = "Usage: /npclook_load <NPCL look code>",
        ru = "Использование: /npclook_load <код NPC Look>",
        ["zh-cn"] = "用法：/npclook_load <外观代码>",
    },
    echo_usage_outfit = {
        en = "Usage: /npclook_outfit <name>",
        ru = "Использование: /npclook_outfit <имя>",
        ["zh-cn"] = "用法：/npclook_outfit <套装名称>",
    },
    echo_usage_replace = {
        en = "Usage: /npclook_replace <name>",
        ru = "Использование: /npclook_replace <имя>",
        ["zh-cn"] = "用法：/npclook_replace <模型名称>",
    },
    echo_usage_show = {
        en = "Usage: /npclook_show <slot>",
        ru = "Использование: /npclook_show <слот>",
        ["zh-cn"] = "用法：/npclook_show <槽位>",
    },
    echo_usage_wear = {
        en = "Usage: /npclook_wear <slot> <item> or /npclook_wear <item>",
        ru = "Использование: /npclook_wear <слот> <предмет> или /npclook_wear <предмет>",
        ["zh-cn"] = "用法：/npclook_wear <槽位> <物品> 或 /npclook_wear <物品>",
    },
    echo_wearing = {
        en = "Wearing %s in %s",
        ru = "Надето %s в %s",
        ["zh-cn"] = "槽位「%s」穿戴物品：%s",
    },
    error_bridge_not_ready = {
        en = "NPC Look is not ready.",
        ru = "NPC Look не готов.",
        ["zh-cn"] = "NPC外观编辑器尚未就绪",
    },
    error_code_duplicate = {
        en = "duplicate slot in look code: %s",
        ru = "дублирующийся слот в коде образа: %s",
        ["zh-cn"] = "外观代码存在重复槽位：%s",
    },
    error_code_empty = {
        en = "look code is empty",
        ru = "код образа пуст",
        ["zh-cn"] = "外观代码为空",
    },
    error_code_invalid_encoding = {
        en = "invalid encoding",
        ru = "неверная кодировка",
        ["zh-cn"] = "编码格式无效",
    },
    error_code_item_entry = {
        en = "malformed item entry",
        ru = "неверная запись предмета",
        ["zh-cn"] = "物品条目格式错误",
    },
    error_code_malformed = {
        en = "malformed look code",
        ru = "неверный код образа",
        ["zh-cn"] = "外观代码格式损坏",
    },
    error_code_metadata = {
        en = "malformed metadata entry",
        ru = "неверная запись метаданных",
        ["zh-cn"] = "元数据条目格式错误",
    },
    error_code_metadata_invalid = {
        en = "invalid metadata entry",
        ru = "неверная запись метаданных",
        ["zh-cn"] = "无效元数据条目",
    },
    error_code_missing_item = {
        en = "missing item in look code: %s",
        ru = "отсутствует предмет в коде образа: %s",
        ["zh-cn"] = "外观代码内缺失物品：%s",
    },
    error_code_slot = {
        en = "invalid slot in look code",
        ru = "неверный слот в коде образа",
        ["zh-cn"] = "外观代码包含无效槽位",
    },
    error_code_too_many = {
        en = "look code contains too many slot entries",
        ru = "код образа содержит слишком много записей слотов",
        ["zh-cn"] = "外观代码槽位条目超出上限",
    },
    error_code_unknown_entry = {
        en = "unknown look code entry",
        ru = "неизвестная запись кода образа",
        ["zh-cn"] = "外观代码存在未知条目",
    },
    error_code_version = {
        en = "not an NPCL look code",
        ru = "не является кодом NPCL Look",
        ["zh-cn"] = "该文本并非合法NPC外观代码",
    },
    error_expected_item = {
        en = "%s expected %s",
        ru = "%s ожидается %s",
        ["zh-cn"] = "%s 需要指定物品：%s",
    },
    error_invalid_empty_slot = {
        en = "invalid empty slot: %s",
        ru = "неверный пустой слот: %s",
        ["zh-cn"] = "无法置空无效槽位：%s",
    },
    error_invalid_hidden_slot = {
        en = "invalid hidden slot: %s",
        ru = "неверный скрытый слот: %s",
        ["zh-cn"] = "无法隐藏无效槽位：%s",
    },
    error_invalid_slot = {
        en = "invalid slot",
        ru = "неверный слот",
        ["zh-cn"] = "无效槽位",
    },
    error_invalid_slot_value = {
        en = "invalid slot: %s",
        ru = "неверный слот: %s",
        ["zh-cn"] = "无效槽位：%s",
    },
    error_item_nil = {
        en = "item instance is nil",
        ru = "экземпляр предмета равен nil",
        ["zh-cn"] = "物品实例为空",
    },
    error_item_not_found = {
        en = "item not found",
        ru = "предмет не найден",
        ["zh-cn"] = "未找到目标物品",
    },
    error_live_package_acquire = {
        en = "could not retain live cosmetic package %s: %s",
        ru = "не удалось удержать живой косметический пакет %s: %s",
        ["zh-cn"] = "无法占用资源包 %s：%s",
    },
    error_live_package_manager = {
        en = "live cosmetic package manager is unavailable",
        ru = "менеджер живых косметических пакетов недоступен",
        ["zh-cn"] = "资源包管理器不可用",
    },
    error_live_package_not_ready = {
        en = "cosmetic package is still loading: %s",
        ru = "косметический пакет всё ещё загружается: %s",
        ["zh-cn"] = "外观资源包正在加载：%s",
    },
    error_local_player_not_ready = {
        en = "local player is not ready",
        ru = "локальный игрок не готов",
        ["zh-cn"] = "本地玩家实体未就绪",
    },
    error_local_visual_not_ready = {
        en = "local visual loadout is not ready",
        ru = "локальный визуальный набор не готов",
        ["zh-cn"] = "本地外观配置系统未就绪",
    },
    error_master_cache_not_ready = {
        en = "master item cache is not ready",
        ru = "кэш мастер-предметов не готов",
        ["zh-cn"] = "物品数据库缓存未加载完成",
    },
    error_package_dependencies = {
        en = "Could not resolve generated item package dependencies: %s",
        ru = "Не удалось разрешить зависимости сгенерированного пакета предметов: %s",
        ["zh-cn"] = "无法解析物品资源依赖项：%s",
    },
    error_missing_item = {
        en = "missing item: %s",
        ru = "отсутствует предмет: %s",
        ["zh-cn"] = "缺失物品：%s",
    },
    error_missing_item_slot = {
        en = "%s: missing item %s",
        ru = "%s: отсутствует предмет %s",
        ["zh-cn"] = "槽位%s：缺少物品 %s",
    },
    error_missing_outfit = {
        en = "missing outfit name",
        ru = "отсутствует имя наряда",
        ["zh-cn"] = "未填写套装名称",
    },
    error_no_local_player = {
        en = "No local player",
        ru = "Нет локального игрока",
        ["zh-cn"] = "不存在本地玩家实体",
    },
    error_no_valid_slots = {
        en = "no valid slots",
        ru = "нет допустимых слотов",
        ["zh-cn"] = "无可用有效槽位",
    },
    error_nothing_matched = {
        en = "nothing matched",
        ru = "ничего не найдено",
        ["zh-cn"] = "未匹配任何内容",
    },
    error_outfit_no_pieces = {
        en = "outfit has no usable pieces",
        ru = "в наряде нет полезных частей",
        ["zh-cn"] = "该套装不含可用部件",
    },
    error_see_console = {
        en = "NPC Look could not %s. Check the console log for details.",
        ru = "NPC Look не удалось %s. Проверьте журнал консоли для подробностей.",
        ["zh-cn"] = "NPC外观编辑器无法%s，详情查看控制台日志。",
    },
    error_restore_removed = {
        en = "could not restore removed slots",
        ru = "не удалось восстановить удалённые слоты",
        ["zh-cn"] = "无法恢复已移除的槽位",
    },
    error_should_empty = {
        en = "%s should be empty",
        ru = "%s должен быть пустым",
        ["zh-cn"] = "槽位%s应当置空",
    },
    error_slot_restore = {
        en = "slot restore failed",
        ru = "ошибка восстановления слота",
        ["zh-cn"] = "槽位恢复失败",
    },
    error_snapshot_bridge = {
        en = "snapshot bridge unavailable",
        ru = "мост снимков недоступен",
        ["zh-cn"] = "快照功能接口不可用",
    },
    error_visual_apply = {
        en = "visual loadout apply failed: %s",
        ru = "ошибка применения визуального набора: %s",
        ["zh-cn"] = "外观配置应用失败：%s",
    },
    error_visual_extension_missing = {
        en = "no visual loadout extension",
        ru = "нет расширения визуального набора",
        ["zh-cn"] = "缺少外观扩展组件",
    },
    error_visual_slot_unavailable = {
        en = "visual slot is unavailable",
        ru = "визуальный слот недоступен",
        ["zh-cn"] = "该外观槽位暂时无法使用",
    },
    feedback_applied = {
        en = "Look applied",
        ru = "Образ применён",
        ["zh-cn"] = "外观已应用",
    },
    feedback_apply_failed = {
        en = "Apply failed: %s",
        ru = "Ошибка применения: %s",
        ["zh-cn"] = "应用失败：%s",
    },
    feedback_camera_focus = {
        en = "Camera: %s",
        ru = "Камера: %s",
        ["zh-cn"] = "镜头视角：%s",
    },
    feedback_camera_reset = {
        en = "Camera framing reset",
        ru = "Позиция камеры сброшена",
        ["zh-cn"] = "镜头视角已重置",
    },
    feedback_clipboard_unavailable = {
        en = "Clipboard unavailable. Use /npclook_me after applying.",
        ru = "Буфер обмена недоступен. Используйте /npclook_me после применения.",
        ["zh-cn"] = "剪贴板不可用，应用外观后可执行 /npclook_me 获取代码。",
    },
    feedback_empty_slot = {
        en = "Slot left empty",
        ru = "Слот оставлен пустым",
        ["zh-cn"] = "槽位已置空",
    },
    feedback_export_copied = {
        en = "Look code copied",
        ru = "Код образа скопирован",
        ["zh-cn"] = "外观代码已复制",
    },
    feedback_export_failed = {
        en = "Export failed: %s",
        ru = "Ошибка экспорта: %s",
        ["zh-cn"] = "导出失败：%s",
    },
    feedback_full_hide = {
        en = "All slots hidden",
        ru = "Все слоты скрыты",
        ["zh-cn"] = "所有槽位已隐藏",
    },
    feedback_hidden_slot = {
        en = "Slot hidden",
        ru = "Слот скрыт",
        ["zh-cn"] = "槽位已隐藏",
    },
    feedback_import_failed = {
        en = "Import failed: %s",
        ru = "Ошибка импорта: %s",
        ["zh-cn"] = "导入失败：%s",
    },
    feedback_imported = {
        en = "Loaded %d entries from the look code",
        ru = "Загружено %d записей из кода образа",
        ["zh-cn"] = "从外观代码载入 %d 项配置",
    },
    feedback_initial = {
        en = "Choose a slot and a piece, then apply your look.",
        ru = "Выберите слот и деталь, затем примените образ.",
        ["zh-cn"] = "选择槽位与部件，随后应用外观配置。",
    },
    feedback_inspect_off = {
        en = "Back to NPC Look",
        ru = "Назад к NPC Look",
        ["zh-cn"] = "返回外观编辑器",
    },
    feedback_inspect_on = {
        en = "Inspect mode",
        ru = "Режим осмотра",
        ["zh-cn"] = "检视模式",
    },
    feedback_library_mode = {
        en = "Showing %s pieces",
        ru = "Показано %s деталей",
        ["zh-cn"] = "共展示 %s 个部件",
    },
    feedback_units_require_resource_loader = {
        en = "Install ResourceLoader 1.1 or newer to enable the Units library",
        ru = "Установите ResourceLoader 1.1 или новее, чтобы включить библиотеку объектов",
        ["zh-cn"] = "安装 ResourceLoader 1.1 或更高版本以启用单位资源库",
    },
    feedback_no_library_pieces = {
        en = "No pieces are available in this library",
        ru = "В этой библиотеке нет доступных деталей",
        ["zh-cn"] = "部件库内暂无可用内容",
    },
    feedback_previewing_item = {
        en = "Previewing %s",
        ru = "Предпросмотр %s",
        ["zh-cn"] = "正在预览：%s",
    },
    feedback_redo = {
        en = "Redone",
        ru = "Повторено",
        ["zh-cn"] = "重做完成",
    },
    feedback_refresh_failed = {
        en = "Refresh failed: %s",
        ru = "Ошибка обновления: %s",
        ["zh-cn"] = "刷新失败：%s",
    },
    feedback_refreshed = {
        en = "Live look refreshed",
        ru = "Живой образ обновлён",
        ["zh-cn"] = "实时外观已刷新",
    },
    feedback_reset = {
        en = "Original look restored",
        ru = "Исходный образ восстановлен",
        ["zh-cn"] = "原始外观已恢复",
    },
    feedback_reset_failed = {
        en = "Reset failed",
        ru = "Ошибка сброса",
        ["zh-cn"] = "重置失败",
    },
    feedback_restored_slot = {
        en = "Applied slot restored",
        ru = "Исходный слот восстановлен",
        ["zh-cn"] = "槽位原始状态已恢复",
    },
    feedback_reverted = {
        en = "Changes discarded",
        ru = "Изменения отменены",
        ["zh-cn"] = "已舍弃所有修改",
    },
    feedback_search_clear = {
        en = "Piece search cleared",
        ru = "Поиск деталей очищен",
        ["zh-cn"] = "部件搜索条件已清空",
    },
    feedback_searching = {
        en = "Search: %s",
        ru = "Поиск: %s",
        ["zh-cn"] = "搜索关键词：%s",
    },
    feedback_select_destination = {
        en = "Select a destination slot first",
        ru = "Сначала выберите слот назначения",
        ["zh-cn"] = "请先选择目标槽位",
    },
    feedback_select_piece = {
        en = "Select a piece first",
        ru = "Сначала выберите деталь",
        ["zh-cn"] = "请先选择部件",
    },
    feedback_select_source = {
        en = "Select an outfit source first",
        ru = "Сначала выберите источник наряда",
        ["zh-cn"] = "请先选择套装来源",
    },
    feedback_selected_item = {
        en = "Selected %s",
        ru = "Выбрано %s",
        ["zh-cn"] = "已选中：%s",
    },
    feedback_selected_source = {
        en = "Outfit: %s",
        ru = "Наряд: %s",
        ["zh-cn"] = "套装：%s",
    },
    feedback_snapshot_failed = {
        en = "Snapshot failed: %s",
        ru = "Ошибка создания снимка: %s",
        ["zh-cn"] = "生成快照失败：%s",
    },
    feedback_source_layered = {
        en = "Outfit added to the current look",
        ru = "Наряд добавлен к текущему образу",
        ["zh-cn"] = "套装叠加至当前外观",
    },
    feedback_source_preview_add = {
        en = "Previewing the outfit added to the current look",
        ru = "Предпросмотр наряда, добавленного к текущему образу",
        ["zh-cn"] = "预览叠加当前外观后的套装效果",
    },
    feedback_source_preview_clear = {
        en = "Outfit preview cleared",
        ru = "Предпросмотр наряда очищен",
        ["zh-cn"] = "套装预览已清空",
    },
    feedback_source_preview_replace = {
        en = "Previewing the outfit on its own",
        ru = "Предпросмотр только наряда",
        ["zh-cn"] = "单独预览该套装",
    },
    feedback_source_replaced = {
        en = "Outfit loaded",
        ru = "Наряд загружен",
        ["zh-cn"] = "套装载入完成",
    },
    feedback_undo = {
        en = "Undone",
        ru = "Отменено",
        ["zh-cn"] = "撤销完成",
    },
    feedback_wore_piece = {
        en = "Added to %s",
        ru = "Добавлено в %s",
        ["zh-cn"] = "部件添加至槽位：%s",
    },
    generic_empty = {
        en = "EMPTY",
        ru = "ПУСТО",
        ["zh-cn"] = "空",
    },
    generic_hidden = {
        en = "HIDDEN",
        ru = "СКРЫТО",
        ["zh-cn"] = "隐藏",
    },
    generic_item = {
        en = "ITEM",
        ru = "ПРЕДМЕТ",
        ["zh-cn"] = "物品",
    },
    generic_none = {
        en = "NONE",
        ru = "НЕТ",
        ["zh-cn"] = "无",
    },
    generic_slot = {
        en = "SLOT",
        ru = "СЛОТ",
        ["zh-cn"] = "槽位",
    },
    generic_source = {
        en = "OUTFIT",
        ru = "НАРЯД",
        ["zh-cn"] = "套装",
    },
    generic_unknown = {
        en = "unknown",
        ru = "неизвестно",
        ["zh-cn"] = "未知",
    },
    generic_unknown_error = {
        en = "unknown error",
        ru = "неизвестная ошибка",
        ["zh-cn"] = "未知错误",
    },
    inspect_attachments = {
        en = "attachments",
        ru = "вложения",
        ["zh-cn"] = "附属组件",
    },
    inspect_attach_node = {
        en = "attach node",
        ru = "узел крепления",
        ["zh-cn"] = "挂载节点",
    },
    inspect_base_unit = {
        en = "base unit",
        ru = "базовая единица",
        ["zh-cn"] = "基础模型",
    },
    inspect_children = {
        en = "children",
        ru = "дочерние",
        ["zh-cn"] = "子组件",
    },
    inspect_hide_slots = {
        en = "hide slots",
        ru = "скрытые слоты",
        ["zh-cn"] = "隐藏槽位",
    },
    inspect_material_overrides = {
        en = "material overrides",
        ru = "переопределения материалов",
        ["zh-cn"] = "材质覆盖",
    },
    inspect_slots = {
        en = "slots",
        ru = "слоты",
        ["zh-cn"] = "槽位列表",
    },
    mod_description = {
        en = "Equip and search for any item. Preview NPC outfits, mix individual pieces, hide or replace slots, and share presets with importable codes. Use /npclook_ui to open ui.",
        ru = "NPC Look - Экипируйте и ищите любые предметы. Просматривайте наряды НИП, смешивайте отдельные части, скрывайте или заменяйте слоты, делитесь пресетами через импортируемые коды. Используйте /npclook_ui для открытия интерфейса.",
        ["zh-cn"] = "穿戴、搜索任意物品，预览NPC外观，自由搭配部件，隐藏或替换槽位，使用可导入代码分享外观预设。输入 /npclook_ui 打开界面。",
    },
    mod_name = {
        en = "NPC Look",
        ru = "Образ НИП",
        ["zh-cn"] = "NPC外观编辑器",
    },
    open_studio_keybind = {
        en = "Open NPC Look",
        ru = "Открыть NPC Look",
        ["zh-cn"] = "打开NPC外观编辑器",
    },
    slot_arms = {
        en = "ARMS",
        ru = "РУКИ",
        ["zh-cn"] = "手臂",
    },
    slot_body_aux = {
        en = "BODY AUX",
        ru = "ВСПОМОГАТЕЛЬНОЕ ТЕЛО",
        ["zh-cn"] = "身体附属件",
    },
    slot_eyes = {
        en = "EYES",
        ru = "ГЛАЗА",
        ["zh-cn"] = "眼部",
    },
    slot_face = {
        en = "FACE",
        ru = "ЛИЦО",
        ["zh-cn"] = "面部",
    },
    slot_face_scar = {
        en = "FACE SCAR",
        ru = "ШРАМ ЛИЦА",
        ["zh-cn"] = "面部伤疤",
    },
    slot_face_tattoo = {
        en = "FACE TATTOO",
        ru = "ТАТУИРОВКА ЛИЦА",
        ["zh-cn"] = "面部纹身",
    },
    slot_facial_hair = {
        en = "FACIAL HAIR",
        ru = "РАСТИТЕЛЬНОСТЬ ЛИЦА",
        ["zh-cn"] = "胡须",
    },
    slot_facial_hair_color = {
        en = "FACIAL HAIR COLOR",
        ru = "ЦВЕТ РАСТИТЕЛЬНОСТИ ЛИЦА",
        ["zh-cn"] = "胡须颜色",
    },
    slot_gear_aux = {
        en = "GEAR AUX",
        ru = "ВСПОМОГАТЕЛЬНОЕ СНАРЯЖЕНИЕ",
        ["zh-cn"] = "装备附属件",
    },
    slot_hair = {
        en = "HAIR",
        ru = "ВОЛОСЫ",
        ["zh-cn"] = "发型",
    },
    slot_hair_color = {
        en = "HAIR COLOR",
        ru = "ЦВЕТ ВОЛОС",
        ["zh-cn"] = "发色",
    },
    slot_head = {
        en = "HEAD",
        ru = "ГОЛОВА",
        ["zh-cn"] = "头部",
    },
    slot_legs_base = {
        en = "LEGS BASE",
        ru = "БАЗА НОГ",
        ["zh-cn"] = "腿部基底",
    },
    slot_lowerbody = {
        en = "LOWERBODY",
        ru = "НИЖНЯЯ ЧАСТЬ",
        ["zh-cn"] = "下半身",
    },
    slot_makeup = {
        en = "MAKEUP",
        ru = "МАКИЯЖ",
        ["zh-cn"] = "妆容",
    },
    slot_material_decal = {
        en = "MATERIAL DECAL",
        ru = "ДЕКАЛЬ МАТЕРИАЛА",
        ["zh-cn"] = "材质贴花",
    },
    slot_secondary_eyes = {
        en = "SECONDARY EYES",
        ru = "ВТОРИЧНЫЕ ГЛАЗА",
        ["zh-cn"] = "次级眼部",
    },
    slot_secondary_skin = {
        en = "SECONDARY SKIN",
        ru = "ВТОРИЧНАЯ КОЖА",
        ["zh-cn"] = "次级皮肤",
    },
    slot_skin = {
        en = "SKIN",
        ru = "КОЖА",
        ["zh-cn"] = "皮肤",
    },
    slot_skin_detail = {
        en = "SKIN DETAIL",
        ru = "ДЕТАЛЬ КОЖИ",
        ["zh-cn"] = "皮肤细节",
    },
    slot_torso_base = {
        en = "TORSO BASE",
        ru = "БАЗА ТОРСА",
        ["zh-cn"] = "躯干基底",
    },
    slot_unmapped = {
        en = "SLOT %s",
        ru = "СЛОТ %s",
        ["zh-cn"] = "槽位 %s",
    },
    slot_upperbody = {
        en = "UPPERBODY",
        ru = "ВЕРХНЯЯ ЧАСТЬ",
        ["zh-cn"] = "上半身",
    },
    ui_apply_player = {
        en = "APPLY",
        ru = "ПРИМЕНИТЬ",
        ["zh-cn"] = "应用",
    },
    ui_camera_full = {
        en = "FULL",
        ru = "ПОЛНЫЙ",
        ["zh-cn"] = "全身",
    },
    ui_camera_head = {
        en = "HEAD",
        ru = "ГОЛОВА",
        ["zh-cn"] = "头部",
    },
    ui_camera_legs = {
        en = "LEGS",
        ru = "НОГИ",
        ["zh-cn"] = "腿部",
    },
    ui_camera_torso = {
        en = "TORSO",
        ru = "ТОРС",
        ["zh-cn"] = "躯干",
    },
    ui_close = {
        en = "X",
        ru = "X",
        ["zh-cn"] = "X",
    },
    ui_copy_stage = {
        en = "COPY CODE",
        ru = "СКОПИРОВАТЬ КОД",
        ["zh-cn"] = "复制代码",
    },
    ui_destination = {
        en = "Destination: %s",
        ru = "Назначение: %s",
        ["zh-cn"] = "目标槽位：%s",
    },
    ui_details_authored_slots = {
        en = "Authored slot hints: %s",
        ru = "Авторские подсказки слотов: %s",
        ["zh-cn"] = "原生推荐槽位：%s",
    },
    ui_details_base_unit = {
        en = "Base unit: %s",
        ru = "Базовая единица: %s",
        ["zh-cn"] = "基础模型：%s",
    },
    ui_details_hide_ignored = {
        en = "Authored hide rules are ignored by NPCLook",
        ru = "Авторские правила скрытия игнорируются NPCLook",
        ["zh-cn"] = "模组将忽略物品自带的隐藏规则",
    },
    ui_details_select_piece = {
        en = "Select a piece to preview it.",
        ru = "Выберите деталь для предпросмотра.",
        ["zh-cn"] = "选中部件进行预览。",
    },
    ui_empty = {
        en = "EMPTY",
        ru = "ПУСТО",
        ["zh-cn"] = "空",
    },
    ui_empty_slot = {
        en = "EMPTY SLOT",
        ru = "ПУСТОЙ СЛОТ",
        ["zh-cn"] = "空槽位",
    },
    ui_error_hint = {
        en = "Press Esc to close. The error is also written to the console.",
        ru = "Нажмите Esc для закрытия. Ошибка также записана в консоль.",
        ["zh-cn"] = "按Esc关闭窗口，错误信息同时输出至控制台。",
    },
    ui_full_hide = {
        en = "HIDE ALL",
        ru = "СКРЫТЬ ВСЁ",
        ["zh-cn"] = "全部隐藏",
    },
    ui_hide = {
        en = "HIDE",
        ru = "СКРЫТЬ",
        ["zh-cn"] = "隐藏",
    },
    ui_hide_slot = {
        en = "HIDE SLOT",
        ru = "СКРЫТЬ СЛОТ",
        ["zh-cn"] = "隐藏槽位",
    },
    ui_inspect = {
        en = "INSPECT",
        ru = "ОСМОТРЕТЬ",
        ["zh-cn"] = "检视",
    },
    ui_inspect_title = {
        en = "INSPECT",
        ru = "ОСМОТР",
        ["zh-cn"] = "物品检视",
    },
    ui_layer_stage = {
        en = "LAYER",
        ru = "НАЛОЖИТЬ",
        ["zh-cn"] = "叠加预览",
    },
    ui_load_stage = {
        en = "LOAD CODE",
        ru = "ЗАГРУЗИТЬ КОД",
        ["zh-cn"] = "载入代码",
    },
    ui_look_code = {
        en = "LOOK CODE",
        ru = "КОД ОБРАЗА",
        ["zh-cn"] = "外观代码",
    },
    ui_look_code_help = {
        en = "Use /npclook_me after applying",
        ru = "Используйте /npclook_me после применения",
        ["zh-cn"] = "应用外观后可使用 /npclook_me 获取代码",
    },
    ui_look_code_placeholder = {
        en = "PASTE NPCL LOOK CODE",
        ru = "ВСТАВЬТЕ КОД NPC Look",
        ["zh-cn"] = "粘贴NPC外观代码",
    },
    ui_mode_all = {
        en = "ALL",
        ru = "ВСЕ",
        ["zh-cn"] = "全部",
    },
    ui_mode_slot = {
        en = "SLOT",
        ru = "СЛОТ",
        ["zh-cn"] = "槽位",
    },
    ui_next_page = {
        en = ">",
        ru = ">",
        ["zh-cn"] = ">",
    },
    ui_next_piece = {
        en = "NEXT PIECE >",
        ru = "СЛЕДУЮЩАЯ ДЕТАЛЬ >",
        ["zh-cn"] = "下一部件 >",
    },
    ui_no_matching_pieces = {
        en = "NO MATCHING PIECES",
        ru = "НЕТ ПОДХОДЯЩИХ ДЕТАЛЕЙ",
        ["zh-cn"] = "无匹配部件",
    },
    ui_npc_families = {
        en = "NPC OUTFITS",
        ru = "НАРЯДЫ NPC",
        ["zh-cn"] = "NPC套装",
    },
    ui_outfit_sources = {
        en = "OUTFITS",
        ru = "НАРЯДЫ",
        ["zh-cn"] = "套装列表",
    },
    ui_page = {
        en = "%d/%d",
        ru = "%d/%d",
        ["zh-cn"] = "%d/%d",
    },
    ui_piece_library = {
        en = "PIECE LIBRARY",
        ru = "БИБЛИОТЕКА ДЕТАЛЕЙ",
        ["zh-cn"] = "部件库",
    },
    ui_presets = {
        en = "PRESETS",
        ru = "ПРЕСЕТЫ",
        ["zh-cn"] = "预设",
    },
    ui_preview_layer = {
        en = "PREVIEW LAYER",
        ru = "ПРЕДПРОСМОТР СЛОЯ",
        ["zh-cn"] = "叠加预览",
    },
    ui_preview_replace = {
        en = "PREVIEW REPLACE",
        ru = "ПРЕДПРОСМОТР ЗАМЕНЫ",
        ["zh-cn"] = "替换预览",
    },
    ui_previewing = {
        en = "PREVIEWING",
        ru = "ПРЕДПРОСМОТР",
        ["zh-cn"] = "预览中",
    },
    ui_previous_page = {
        en = "<",
        ru = "<",
        ["zh-cn"] = "<",
    },
    ui_previous_piece = {
        en = "< PREVIOUS PIECE",
        ru = "< ПРЕДЫДУЩАЯ ДЕТАЛЬ",
        ["zh-cn"] = "< 上一部件",
    },
    ui_redo = {
        en = "REDO",
        ru = "ПОВТОРИТЬ",
        ["zh-cn"] = "重做",
    },
    ui_refresh_live = {
        en = "REAPPLY",
        ru = "ПРИМЕНИТЬ ЗАНОВО",
        ["zh-cn"] = "重新应用",
    },
    ui_replace_stage = {
        en = "REPLACE",
        ru = "ЗАМЕНИТЬ",
        ["zh-cn"] = "替换",
    },
    ui_reset_camera = {
        en = "RESET CAMERA",
        ru = "СБРОСИТЬ КАМЕРУ",
        ["zh-cn"] = "重置镜头",
    },
    ui_reset_player = {
        en = "RESTORE PLAYER",
        ru = "ВОССТАНОВИТЬ ИГРОКА",
        ["zh-cn"] = "恢复玩家原始外观",
    },
    ui_restore = {
        en = "RESTORE",
        ru = "ВОССТАНОВИТЬ",
        ["zh-cn"] = "恢复",
    },
    ui_results = {
        en = "%d RESULTS",
        ru = "%d РЕЗУЛЬТАТОВ",
        ["zh-cn"] = "共 %d 条结果",
    },
    ui_return = {
        en = "RETURN",
        ru = "НАЗАД",
        ["zh-cn"] = "返回",
    },
    ui_revert_stage = {
        en = "DISCARD CHANGES",
        ru = "ОТМЕНИТЬ ИЗМЕНЕНИЯ",
        ["zh-cn"] = "舍弃修改",
    },
    ui_search_placeholder = {
        en = "SEARCH PIECES",
        ru = "ПОИСК ДЕТАЛЕЙ",
        ["zh-cn"] = "搜索部件",
    },
    ui_search_nodes_placeholder = {
        en = "SEARCH NODES",
        ru = "ПОИСК УЗЛОВ",
        ["zh-cn"] = "搜索节点",
    },
    ui_selected_piece = {
        en = "SELECTED PIECE",
        ru = "ВЫБРАННАЯ ДЕТАЛЬ",
        ["zh-cn"] = "选中部件",
    },
    ui_selected_slot = {
        en = "Slot: %s",
        ru = "Слот: %s",
        ["zh-cn"] = "槽位：%s",
    },
    ui_source_curated = {
        en = "curated outfit",
        ru = "подобранный наряд",
        ["zh-cn"] = "精选套装",
    },
    ui_source_family_summary = {
        en = "%d pieces  %d slots",
        ru = "%d деталей  %d слотов",
        ["zh-cn"] = "%d 个部件 · %d 个槽位",
    },
    ui_source_more_slots = {
        en = "+%d more slots",
        ru = "+%d дополнительных слотов",
        ["zh-cn"] = "+%d 额外槽位",
    },
    ui_source_select = {
        en = "Select a preset or NPC outfit.",
        ru = "Выберите пресет или наряд NPC.",
        ["zh-cn"] = "选择预设或NPC套装。",
    },
    ui_stage_matches = {
        en = "NO UNSAVED CHANGES",
        ru = "НЕТ НЕСОХРАНЁННЫХ ИЗМЕНЕНИЙ",
        ["zh-cn"] = "无未保存修改",
    },
    ui_staged_changes = {
        en = "%d UNSAVED CHANGES",
        ru = "%d НЕСОХРАНЁННЫХ ИЗМЕНЕНИЙ",
        ["zh-cn"] = "%d 项未保存修改",
    },
    ui_character_preview = {
        en = "LOOK PREVIEW",
        ru = "ПРЕДПРОСМОТР ОБРАЗА",
        ["zh-cn"] = "外观预览",
    },
    ui_staged_outfit = {
        en = "CURRENT LOOK",
        ru = "ТЕКУЩИЙ ОБРАЗ",
        ["zh-cn"] = "当前外观",
    },
    ui_undo = {
        en = "UNDO",
        ru = "ОТМЕНИТЬ",
        ["zh-cn"] = "撤销",
    },
    ui_wear = {
        en = "WEAR",
        ru = "НАДЕТЬ",
        ["zh-cn"] = "穿戴",
    },
    ui_studio_error = {
        en = "NPC LOOK ERROR",
        ru = "ОШИБКА NPC LOOK",
        ["zh-cn"] = "NPC外观编辑器错误",
    },
    ui_studio_title = {
        en = "NPC LOOK",
        ru = "NPC Look",
        ["zh-cn"] = "NPC外观编辑器",
    },
    view_preview_name = {
        en = "NPC Look Preview",
        ru = "Предпросмотр NPC Look",
        ["zh-cn"] = "NPC外观预览",
    },
    view_studio_name = {
        en = "NPC Look",
        ru = "NPC Look",
        ["zh-cn"] = "NPC外观编辑器",
    },
    error_preset_directory = {
        en = "could not create the NPCLook preset folder",
        ["zh-cn"] = "无法创建NPCLook预设文件夹",
    },
    error_preset_encode = {
        en = "could not encode preset JSON",
        ["zh-cn"] = "预设JSON编码失败",
    },
    error_preset_path = {
        en = "Roaming AppData is unavailable",
        ["zh-cn"] = "漫游应用数据目录不可访问",
    },
    error_preset_write = {
        en = "could not write presets.json",
        ["zh-cn"] = "无法写入presets.json文件",
    },
    feedback_preset_delete_failed = {
        en = "Could not delete preset: %s",
        ["zh-cn"] = "删除预设失败：%s",
    },
    feedback_preset_deleted = {
        en = "Deleted %s",
        ["zh-cn"] = "已删除预设：%s",
    },
    feedback_preset_loaded = {
        en = "Loaded %s (%d entries)",
        ["zh-cn"] = "载入预设「%s」（共 %d 项配置）",
    },
    feedback_preset_name_required = {
        en = "Enter a preset name first",
        ["zh-cn"] = "请先输入预设名称",
    },
    feedback_preset_save_failed = {
        en = "Could not save preset: %s",
        ["zh-cn"] = "保存预设失败：%s",
    },
    feedback_preset_saved = {
        en = "Saved %s",
        ["zh-cn"] = "已保存预设：%s",
    },
    feedback_preview_attachment_cycle = {
        en = "That combination would create a circular attachment chain",
        ["zh-cn"] = "该组合会形成循环挂载链",
    },
    feedback_select_player_preset = {
        en = "Select one of your presets first",
        ["zh-cn"] = "请先选中一个本地预设",
    },
    ui_delete_player_preset = {
        en = "DELETE PRESET",
        ["zh-cn"] = "删除预设",
    },
    ui_load_player_preset = {
        en = "LOAD PRESET",
        ["zh-cn"] = "载入预设",
    },
    ui_no_player_presets = {
        en = "NO SAVED PRESETS",
        ["zh-cn"] = "暂无已保存预设",
    },
    ui_player_preset_help = {
        en = "Save the staged look, or load one of your local NPCL codes.",
        ["zh-cn"] = "保存当前待应用外观，或载入本地NPCL外观代码。",
    },
    ui_player_presets = {
        en = "MY PRESETS",
        ["zh-cn"] = "我的预设",
    },
    ui_preset_name_placeholder = {
        en = "PRESET NAME",
        ["zh-cn"] = "预设名称",
    },
    ui_save_player_preset = {
        en = "SAVE CURRENT",
        ["zh-cn"] = "保存当前",
    },
    ui_source_player_preset = {
        en = "local NPCL code",
        ["zh-cn"] = "本地NPCL代码",
    },
    feedback_extra_slot_added = {
        en = "Added %s",
        ["zh-cn"] = "已添加槽位：%s",
    },
    feedback_extra_slot_removed = {
        en = "Removed extra slot",
        ["zh-cn"] = "额外槽位已移除",
    },
    feedback_extra_slots_removed = {
        en = "Removed %d extra slots",
        ["zh-cn"] = "已移除 %d 个额外槽位",
    },
    feedback_extra_slot_select = {
        en = "Select an extra slot first",
        ["zh-cn"] = "请先选中一个额外槽位",
    },
    ui_add_extra_slot = {
        en = "ADD SLOT",
        ["zh-cn"] = "添加槽位",
    },
    ui_remove_extra_slot = {
        en = "REMOVE SLOT",
        ["zh-cn"] = "移除槽位",
    },
    ui_remove_all_extra_slots = {
        en = "DELETE ALL",
        ["zh-cn"] = "全部删除",
    },
    feedback_extra_transform_updated = {
        en = "Extra-slot transform updated",
        ["zh-cn"] = "额外槽位变换已更新",
    },
    feedback_extra_transform_reset = {
        en = "Extra-slot transform reset",
        ["zh-cn"] = "额外槽位变换已重置",
    },
    ui_extra_transform = {
        en = "EXTRA SLOT TRANSFORM",
        ["zh-cn"] = "额外槽位变换",
    },
    ui_extra_transform_reset = {
        en = "RESET TRANSFORM",
        ["zh-cn"] = "重置变换",
    },
    ui_extra_transform_deform = {
        en = "DEFORM WITH BODY",
        ["zh-cn"] = "随身体变形",
    },
    ui_extra_xyz_scale = {
        en = "XYZ SCALING",
        ["zh-cn"] = "XYZ 轴缩放",
    },
    error_extra_anchor_node_missing = {
        en = "Anchor slot %s uses an unavailable attachment node: %s",
        ["zh-cn"] = "锚点槽位 %s 使用了不可用的挂载节点：%s",
    },
    ui_mode_materials = {
        en = "MATERIALS",
        ["zh-cn"] = "材质",
    },
    ui_toggle_material = {
        en = "APPLY / REMOVE OVERRIDE",
        ["zh-cn"] = "应用/移除覆盖",
    },
    ui_material_target = {
        en = "TARGET",
        ["zh-cn"] = "目标",
    },
    ui_material_target_all = {
        en = "ALL MATERIALS",
        ["zh-cn"] = "全部材质",
    },
    ui_material_applied = {
        en = "APPLIED • %s",
        ["zh-cn"] = "已应用 • %s",
    },
    ui_clear_materials = {
        en = "CLEAR OVERRIDES",
        ["zh-cn"] = "清除覆盖",
    },
    ui_selected_materials = {
        en = "APPLIED MATERIAL OVERRIDES",
        ["zh-cn"] = "已应用的材质覆盖",
    },
    ui_no_material_overrides = {
        en = "No material overrides applied.",
        ["zh-cn"] = "未应用任何材质覆盖。",
    },
    feedback_selected_material = {
        en = "Selected material override: %s",
        ["zh-cn"] = "已选中材质覆盖：%s",
    },
    feedback_select_material = {
        en = "Select a material override first.",
        ["zh-cn"] = "请先选中一个材质覆盖。",
    },
    feedback_material_applied = {
        en = "Applied material override: %s",
        ["zh-cn"] = "已应用材质覆盖：%s",
    },
    feedback_material_removed = {
        en = "Removed material override: %s",
        ["zh-cn"] = "已移除材质覆盖：%s",
    },
    feedback_materials_cleared = {
        en = "Cleared material overrides.",
        ["zh-cn"] = "材质覆盖已全部清除。",
    },
    feedback_material_target = {
        en = "Material target: %s",
        ["zh-cn"] = "材质目标：%s",
    },
    error_raw_unit_unavailable = {
        en = "Raw unit resource is unavailable in the current context: %s",
        ["zh-cn"] = "当前环境下无法加载原始单位资源：%s",
    },
    ui_details_unit_type = {
        en = "Type: %s",
        ["zh-cn"] = "类型：%s",
    },
    ui_details_package_source = {
        en = "Containing source: %s",
        ["zh-cn"] = "所属源文件：%s",
    },
    ui_details_package = {
        en = "Package: %s",
        ["zh-cn"] = "资源包：%s",
    },
    ui_details_package_count = {
        en = "Known containing packages: %d",
        ["zh-cn"] = "关联资源包总数：%d",
    },
    ui_details_membership_count = {
        en = "Source membership rows: %d",
        ["zh-cn"] = "源关联条目数：%d",
    },
    ui_details_package_members = {
        en = "Known units in package: %d",
        ["zh-cn"] = "包内单位数量：%d",
    },
    ui_details_variant_parse_failure = {
        en = "Variant metadata unavailable: %s",
        ["zh-cn"] = "无法读取变体元数据：%s",
    },
    ui_details_mesh_count = {
        en = "Meshes: %d",
        ["zh-cn"] = "模型网格：%d",
    },
    ui_details_variant_families = {
        en = "Authored variants: %s",
        ["zh-cn"] = "自定义变体组：%s",
    },
    ui_details_variant_combinations = {
        en = "Variant combinations: %d",
        ["zh-cn"] = "变体组合总数：%d",
    },
    ui_details_visibility_groups = {
        en = "Visibility groups: %s",
        ["zh-cn"] = "可见性分组：%s",
    },
    ui_variant_family = {
        en = "FAMILY",
        ["zh-cn"] = "变体组",
    },
    ui_visibility_group = {
        en = "MESH",
        ["zh-cn"] = "网格",
    },
    ui_variant_authored_default = {
        en = "AUTHORED DEFAULT",
        ["zh-cn"] = "默认自定义变体",
    },
    ui_variant_on = {
        en = "ON",
        ["zh-cn"] = "开启",
    },
    ui_variant_off = {
        en = "OFF",
        ["zh-cn"] = "关闭",
    },
    ui_raw_unit_path = {
        en = "RAW UNIT PATH",
        ["zh-cn"] = "原始单位路径",
    },
    ui_mode_units = {
        en = "UNITS",
        ["zh-cn"] = "单位列表",
    },
    feedback_extra_first_person_updated = {
        en = "Extra-slot first-person visibility updated",
        ["zh-cn"] = "附加部位第一人称显示设置已更新",
    },
    ui_extra_first_person = {
        en = "SHOW IN FIRST PERSON",
        ["zh-cn"] = "第一人称显示",
    },
    error_extra_first_person_unavailable = {
        en = "The first-person visual could not be created for this extra slot",
        ["zh-cn"] = "该附加部位无法生成第一人称模型",
    },
    ui_mask_off = {
        en = "OFF",
        ["zh-cn"] = "关闭",
    },
    ui_mask_field_mask_facial_hair_item = {
        en = "FACIAL HAIR",
        ["zh-cn"] = "胡须",
    },
    ui_mask_field_mask_hair_item = {
        en = "HAIR",
        ["zh-cn"] = "头发",
    },
    ui_mask_field_mask_face_item = {
        en = "FACE",
        ["zh-cn"] = "面部",
    },
    ui_mask_field_mask_face_accessory_item = {
        en = "FACE ACCESSORY",
        ["zh-cn"] = "面部饰品",
    },
    ui_mask_field_hide_eyebrows = {
        en = "EYEBROWS",
        ["zh-cn"] = "眉毛",
    },
    ui_mask_field_mask_torso_item = {
        en = "TORSO",
        ["zh-cn"] = "躯干",
    },
    ui_mask_field_mask_arms_item = {
        en = "ARMS",
        ["zh-cn"] = "手臂",
    },
    ui_mask_field_mask_legs_item = {
        en = "LEGS",
        ["zh-cn"] = "腿部",
    },
    ui_preset_confirm_title = {
        en = "ARE YOU SURE?",
        ["zh-cn"] = "是否确认？",
    },
    ui_preset_save_confirm = {
        en = "Save local preset \"%s\"?",
        ["zh-cn"] = "是否保存本地外观预设「%s」？",
    },
    ui_preset_delete_confirm = {
        en = "Delete local preset \"%s\"?",
        ["zh-cn"] = "是否删除本地外观预设「%s」？",
    },
    ui_confirm = {
        en = "CONFIRM",
        ["zh-cn"] = "确认",
    },
    ui_cancel = {
        en = "CANCEL",
        ["zh-cn"] = "取消",
    },
    ui_loadout_preset_button = {
        en = "LOADOUT LOOK",
        ["zh-cn"] = "外观预设",
    },
    ui_loadout_preset_none = {
        en = "NO PIN",
        ["zh-cn"] = "未收藏",
    },
    ui_loadout_preset_default = {
        en = "DEFAULT",
        ["zh-cn"] = "默认",
    },
    feedback_loadout_preset_unavailable = {
        en = "The active character loadout is not available yet",
        ["zh-cn"] = "当前角色配装数据尚未加载完成",		 
    },
    feedback_clone_slot_empty = {
        en = "The selected slot has nothing to clone",
    },
    feedback_node_attached = {
        en = "Attach node set to %s",
    },
    feedback_node_reset = {
        en = "Attach node reset",
    },
    feedback_node_skeleton_off = {
        en = "Node skeleton hidden",
    },
    feedback_node_skeleton_on = {
        en = "Node skeleton shown",
    },
    feedback_nodes_unavailable = {
        en = "Nodes are unavailable for this preview",
    },
    feedback_opacity_set = {
        en = "Opacity set to %d%%",
    },
    feedback_previewing_node = {
        en = "Previewing node: %s",
    },
    feedback_select_node = {
        en = "Select a node first",
    },
    feedback_slot_cloned = {
        en = "Cloned to %s",
    },
    inspect_opacity = {
        en = "Opacity",
    },
    ui_clone_slot = {
        en = "CLONE SLOT",
    },
    ui_mode_nodes = {
        en = "NODES",
    },
    ui_node_default = {
        en = "DEFAULT NODE",
    },
    ui_node_skeleton = {
        en = "SHOW SKELETON",
    },
    ui_opacity_label = {
        en = "OPACITY",
    },
    ui_selected_node = {
        en = "SELECTED NODE",
    },
    ui_use_node = {
        en = "USE NODE",
    },
    feedback_extra_animate_first_person_updated = {
        en = "First-person animation updated",
    },
    ui_extra_animate_first_person = {
        en = "ANIMATE IN FIRST PERSON",
    },

}
