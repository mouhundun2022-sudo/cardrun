-- tests/run.lua —— 纯 Lua 5.4 冒烟测试，零引擎依赖
--
-- 用法（在包根目录执行）：
--   lua5.4 tests/run.lua
--
-- 覆盖：模块加载 / 数据完整性 / 建战 / 行动权 / 充能 / 回合往返 /
--       多场收敛 / 纯数据编队 / 全部集成钩子 / Progress 存档往返

-- 解析包根：优先用 arg[0] 推导，其次退回当前工作目录
local scriptPath = (arg and arg[0]) or "tests/run.lua"
local root = scriptPath:match("^(.*)[/\\]tests[/\\][^/\\]*$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Data = require("combat.data")
local Session = require("combat.session")
local Progress = require("combat.progress")

local pass, fail = 0, 0
local function Check(name, cond, detail)
    if cond then pass = pass + 1 else fail = fail + 1 end
    print(string.format("%-44s %s  %s", name, cond and "PASS" or "FAIL", detail or ""))
end

math.randomseed(7)

--- 自动打完一场：按顺序用未出击武器普攻，全出击后人物防御
---@param enc integer
---@return table session
local function AutoFight(enc)
    local s = Session.New(enc)
    local guard = 0
    while s.state == "running" and guard < 800 do
        guard = guard + 1
        if s.phase ~= "player" then break end
        local acted = false
        for i = 1, #s.weapons do
            if not s.weapons[i].used then
                if s:PlayWeapon(i, "normal", nil) then acted = true end
                break
            end
        end
        if not s.playerActed and (not acted or math.random() < 0.4) then
            local casted = false
            if s.mana >= 6 then
                local mi = math.random(#s.magic)
                local m = s.magic[mi]
                if m and m.cd == 0 and (m.def.mp or 0) <= s.mana then
                    casted = s:CastMagic(mi, nil)
                end
            end
            if not casted then s.playerActed = true end
            s:AutoEndIfAllActed()
        end
        if s.state == "running" and s.phase == "player" and not s:AllActed() and math.random() < 0.15 then
            s:EndTurn()
        end
    end
    return s
end

-- ── A 数据与加载 ───────────────────────────────────────────────────────────
Check("A1 武器数量 = 7", #Data.WEAPONS == 7, tostring(#Data.WEAPONS))
Check("A2 敌人模板存在", type(Data.ENEMY_TEMPLATES) == "table" and #Data.ENEMY_TEMPLATES > 0,
    tostring(Data.ENEMY_TEMPLATES and #Data.ENEMY_TEMPLATES))
Check("A3 改装卡表非空", #Data.MODS > 0, tostring(#Data.MODS))
Check("A4 武器类别 = 5", #Data.CATEGORIES == 5, tostring(#Data.CATEGORIES))
Check("A5 六元素齐全", Data.ELEMENTS and #Data.ELEMENTS == 6, tostring(Data.ELEMENTS and #Data.ELEMENTS))
Check("A6 遭遇表非空", #Data.ENCOUNTERS > 0, tostring(#Data.ENCOUNTERS))

-- ── B 建战 ─────────────────────────────────────────────────────────────────
do
    local s = Session.New(1)
    Check("B1 建战进入玩家回合", s.state == "running" and s.phase == "player")
    Check("B2 三把武器就位", #s.weapons == 3, tostring(#s.weapons))
    Check("B3 敌军就位", #s.enemies >= 1, tostring(#s.enemies))
    Check("B4 法力回满", s.mana == Data.MANA_MAX, tostring(s.mana))
    Check("B5 HP 与养成一致", s.player.hp == s.player.maxHp,
        string.format("%d/%d", s.player.hp, s.player.maxHp))
end

-- ── C 行动权与充能 ─────────────────────────────────────────────────────────
do
    local s = Session.New(1)
    Check("C1 同武器本回合二次出击被拒",
        s:PlayWeapon(1, "normal", nil) and not s:PlayWeapon(1, "normal", nil))
    Check("C2 普攻充能 +1", s.weapons[1].charge == 1, tostring(s.weapons[1].charge))
end

-- ── D 回合往返 ─────────────────────────────────────────────────────────────
do
    local s = Session.New(1)
    local t0 = s.turn
    s:PlayWeapon(1, "normal", nil)
    s:PlayWeapon(2, "normal", nil)
    s:PlayWeapon(3, "normal", nil)
    Check("D1 武器全出击后仍在玩家回合", s.phase == "player", s.phase)
    s:DefendPlayer()
    Check("D2 人物行动后进入新回合", s.turn == t0 + 1 and s.phase == "player",
        string.format("turn=%d phase=%s", s.turn, s.phase))
    Check("D3 新回合行动权重置", not s.weapons[1].used and not s.weapons[2].used and not s.weapons[3].used)
    Check("D4 新回合护甲清零", s.player.block == 0, tostring(s.player.block))
end

-- ── E 多场收敛 ─────────────────────────────────────────────────────────────
do
    local converged = true
    for enc = 1, 3 do
        local s = AutoFight(enc)
        print(string.format("   遭遇 %d [%s] → %s（%d 回合）", enc, s.encounter.name, s.state, s.turn))
        if s.state ~= "victory" and s.state ~= "defeat" then converged = false end
    end
    Check("E1 三场自动战斗收敛", converged)
end

-- ── F 崩溃机制（混乱满 → 当回合受伤×1.5 → 下回合定身）─────────────────────
do
    local s = Session.New(1)
    local e = s.enemies[1]
    Check("F1 敌人有混乱条", e.stagger ~= nil and e.maxStagger ~= nil,
        string.format("%s/%s", tostring(e.stagger), tostring(e.maxStagger)))
end

-- ── G 纯数据编队 opts.loadout ─────────────────────────────────────────────
do
    local s = Session.New(1, nil, nil, nil, {
        loadout = {
            { weapon = "emp" },                                  -- 字符串 id
            { weapon = 5 },                                      -- 数字下标
            { weapon = "toxic", mods = { barrel = "cryo_nozzle" } },
        },
    })
    Check("G1 字符串 id 生效", s.weapons[1].element == "electric", s.weapons[1].name)
    Check("G2 数字下标生效", s.weapons[2].name ~= nil, s.weapons[2].name)
    Check("G3 编队只取 3 把", #s.weapons == 3, tostring(#s.weapons))
    Check("G4 编队内装卡生效", s.weapons[3].mods and s.weapons[3].mods.barrel == "cryo_nozzle")
end

-- ── H 集成钩子 ─────────────────────────────────────────────────────────────
do
    local hits = { equip = 0, item = 0, armor = 0, save = 0 }
    local hooks = {
        onEquipMod = function(_, instanceId, slot, modId)
            hits.equip = hits.equip + 1
            return true, "ok", nil
        end,
        onItemConsumed = function() hits.item = hits.item + 1 end,
        applyArmor = function(_, dmg) hits.armor = hits.armor + 1; return dmg, 0 end,
        onSave = function() hits.save = hits.save + 1 end,
        loadout = {
            { weapon = "rifle", instanceId = "instA" },
            { weapon = "burner", instanceId = "instB" },
        },
        itemLists = { { {
            id = "bandage", name = "绷带", cardType = "consumable",
            heal = 10, uses = 3, _remainingUses = 3,
        } } },
    }
    local s = Session.New(1, nil, nil, nil, hooks)

    Check("H1 onEquipMod 被调用", s:EquipMod(1, "barrel", "insulated_barrel") and hits.equip == 1)
    Check("H2 装卡触发 onSave", hits.save >= 1, tostring(hits.save))

    -- 注意：CollectItems 是静态函数（点调用），不是方法
    local items = Session.CollectItems(hooks)
    Check("H3 itemLists 道具被收集", items and #items == 1, tostring(items and #items))
    if items and #items >= 1 then
        s:PickItem(1)
        Check("H4 用道具触发 onItemConsumed", s:UsePendingItem() and hits.item == 1)
    else
        Check("H4 用道具触发 onItemConsumed", false, "无道具")
    end

    local s2 = Session.New(1, nil, nil, nil, {
        applyArmor = function(_, dmg) hits.armor = hits.armor + 1; return math.floor(dmg * 0.5), 1 end,
    })
    s2:EndTurn()
    Check("H5 applyArmor 被调用", hits.armor >= 1, tostring(hits.armor))
end

-- ── I 长跑稳定性 ───────────────────────────────────────────────────────────
do
    local s = Session.New(1)
    local rounds = 0
    while s.state == "running" and rounds < 5 do
        s:EndTurn()
        if s.state == "running" then rounds = rounds + 1 end
    end
    Check("I1 连续空过 5 轮不崩", s.state ~= "running" or rounds == 5,
        string.format("state=%s rounds=%d", s.state, rounds))
end

-- ── J Progress 存档往返（JSON 丢元表陷阱）──────────────────────────────────
do
    local p = Progress.New()
    Check("J1 Progress.New 可调方法", type(p.GetMaxHp) == "function" and p:GetMaxHp() > 0)

    -- 模拟 JSON 往返：只保留字段，元表丢失
    local bare = {}
    for k, v in pairs(p) do
        if type(v) ~= "function" then bare[k] = v end
    end
    local restored = Progress.Wrap(bare)
    Check("J2 Wrap 重挂元表后可调方法", type(restored.GetMaxHp) == "function",
        tostring(type(restored.GetMaxHp)))
end

print(string.format("\nRESULT: %d/%d PASS, %d FAIL", pass, pass + fail, fail))
os.exit(fail == 0 and 0 or 1)
