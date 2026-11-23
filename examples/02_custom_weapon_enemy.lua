-- examples/02_custom_weapon_enemy.lua
--
-- 扩展演示：不改任何逻辑代码，只往数据表里追加，
-- 得到一把自定义武器、一个自定义敌人、一张自定义改装卡，并打一场。
--
-- 运行（在包根目录）：
--   lua5.4 examples/02_custom_weapon_enemy.lua

local scriptPath = (arg and arg[0]) or "examples/02_custom_weapon_enemy.lua"
local root = scriptPath:match("^(.*)[/\\]examples[/\\][^/\\]*$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Session = require("combat.session")
local Data = require("combat.data")

-- ── 1) 加一把自定义武器：电磁磁轨炮（发射器系，终结技需 4 充能）───────────
--    武器 = 场上行动单位。normal 产充能，tech 高价值不产充能，ult 消耗充能。
table.insert(Data.WEAPONS, {
    id = "railgun", name = "磁轨炮", element = "electric", category = "launcher",
    chargeMax = 4,                                -- 终结技充能需求
    normal = { name = "穿甲弹",   dmg = 10, stagger = 5, desc = "单体高伤,充能+1" },
    tech   = { name = "过载炮击", dmg = 16, stagger = 8, aoe = true, desc = "全体,不产充能" },
    ult    = { name = "⭐湮灭射线", dmg = 34, stagger = 12, desc = "全体毁灭" },
})

-- ── 2) 加一张只适配发射器系的改装卡：磁轨枪管 ─────────────────────────────
--    cats 是适配白名单（C2 类别绑定）；dmgPct 只影响 apply 指定的技能段。
table.insert(Data.MODS, {
    id = "rail_barrel", slot = "barrel", cats = { launcher = true }, element = "none",
    name = "磁轨枪管", desc = "发射器系普攻与战技伤害 +25%",
    apply = { normal = true, tech = true }, dmgPct = 0.25,
})

-- ── 3) 加一个自定义敌人：遗迹狙击手 ───────────────────────────────────────
--    resist 为六元素抗性（-100~100，负数=弱点）；intents 是攻击意图循环。
table.insert(Data.ENEMY_TEMPLATES, {
    id = "sniper", name = "遗迹狙击手", hp = 96, maxStagger = 28,
    sprite = "enemy_sniper",                       -- 纯字符串，宿主自己映射立绘
    resist = { none = 10, fire = 0, ice = 0, electric = -25, light = 0, nature = 0 },
    intents = {
        { name = "瞄准射击", dmg = 13, element = "none" },
        { name = "燃烧弹",   dmg = 10, element = "fire" },
    },
})

-- ── 4) 加一场使用它们的遭遇 ───────────────────────────────────────────────
table.insert(Data.ENCOUNTERS, {
    name = "自定义遭遇：遗迹狙击阵地",
    enemies = { "sniper", "sniper" },
    loadout = { 1, 2, 3 },                         -- 占位，下面会用 opts.loadout 覆盖
})
local ENC = #Data.ENCOUNTERS

-- ── 5) 用纯数据编队开战：自定义枪 + 已装的自定义改装卡 ─────────────────────
--    loadout 每项 { weapon = id 或下标, mods = { slot -> modId }, instanceId = 宿主标识 }
local s = Session.New(ENC, nil, nil, nil, {
    loadout = {
        { weapon = "railgun", mods = { barrel = "rail_barrel" }, instanceId = "my_railgun" },
        { weapon = "emp" },
        { weapon = "burner" },
    },
})

print("遭遇：" .. s.encounter.name)
print("\n我方编队：")
for i, w in ipairs(s.weapons) do
    local def = Data.WEAPONS[w.defIndex]
    local modDef = w.mods.barrel and Data.GetMod(w.mods.barrel)
    local modName = modDef and modDef.name or "（无卡）"
    print(string.format("  %d. %-8s [%s]  终结技需求 %d 充能  枪管槽：%s",
        i, w.name, w.element, def.chargeMax or Data.CHARGE_MAX, modName))
end

print("\n敌军：")
for _, e in ipairs(s.enemies) do
    local weak = {}
    for elem, r in pairs(e.resist or {}) do
        if r < 0 then weak[#weak + 1] = elem end
    end
    print(string.format("  %s  HP %d/%d  混乱阈值 %d  弱点元素：%s",
        e.name, e.hp, e.maxHp, e.maxStagger,
        #weak > 0 and table.concat(weak, "/") or "无"))
end

-- ── 6) 打一场：磁轨炮先普攻攒充能，攒满后再放终结技 ───────────────────────
local function HasCharged(session, idx)
    local w = session.weapons[idx]
    if not w then return false end
    return w.charge >= (Data.WEAPONS[w.defIndex].chargeMax or Data.CHARGE_MAX)
end

local function PlayTurn(session)
    for i = 1, #session.weapons do
        if session.state ~= "running" then return end
        local w = session.weapons[i]
        if w and not w.used then
            -- 充能满 → 终结技；否则普攻攒充能
            if HasCharged(session, i) then
                session:PlayWeapon(i, "ult", nil)
            else
                session:PlayWeapon(i, "normal", nil)
            end
        end
    end
    if session.state == "running" and not session.playerActed then
        session:WaitPlayer()
    end
end

print("\n开始战斗……")
local guard = 0
while s.state == "running" and guard < 40 do
    guard = guard + 1
    local before = s.weapons[1].charge
    PlayTurn(s)
    if s.weapons[1].charge > before then
        print(string.format("  第%d回合：磁轨炮充能 %d → %d", s.turn - 1, before, s.weapons[1].charge))
    end
end

print(string.format("\n战斗结果：%s（共 %d 回合）", s.state, s.turn))
