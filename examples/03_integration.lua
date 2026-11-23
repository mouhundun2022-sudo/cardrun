-- examples/03_integration.lua
--
-- 集成演示：把内核接进一个"假宿主"（模拟你自己的背包 / 仓库 / 装备 / 存档）。
-- 内核不读存档、不碰资源、不写文件；所有外部状态都通过 opts 钩子暴露。
-- 这里用一个内存里的 mockGame 演示 7 个钩子怎么接。
--
-- 运行（在包根目录）：
--   lua5.4 examples/03_integration.lua

local scriptPath = (arg and arg[0]) or "examples/03_integration.lua"
local root = scriptPath:match("^(.*)[/\\]examples[/\\][^/\\]*$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Session = require("combat.session")
local Data = require("combat.data")
local Progress = require("combat.progress")

-- ══════════════════════════════════════════════════════════════════════════
-- 假宿主：模拟你自己的游戏状态（这些都由你实现，内核完全不关心）
-- ══════════════════════════════════════════════════════════════════════════
local function NewMockGame()
    return {
        -- 1) 背包：装着战斗可用消耗品（字段形态按你自家物品系统来）
        inventory = { items = {
            { id = "bandage", name = "急救绷带", cardType = "consumable",
              heal = 12, uses = 2, _remainingUses = 2 },
            { id = "grenade", name = "破片手雷", cardType = "consumable",
              damage = 18, target = "aoe", uses = 1, _remainingUses = 1 },
        } },
        -- 2) 仓库：另一批消耗品（出征时也可以带）
        warehouse = { items = {
            { id = "smoke", name = "烟雾弹", cardType = "consumable",
              applyEffects = { { effect = "weaken", percent = 50, target = "all" } },
              uses = 1, _remainingUses = 1 },
        } },
        -- 3) 武器实例的改装卡持久态：instanceId -> { slot -> modId }
        gunMods = {
            gunA = { grip = "quick_charge" },
            gunB = {},
        },
        -- 4) 装备护甲：一个简单的固定减伤
        armorReduction = 4,
        -- 5) 存档写入计数（真实项目里这里写文件 / 发网络请求）
        saveCount = 0,
    }
end

local game = NewMockGame()

-- ══════════════════════════════════════════════════════════════════════════
-- opts：内核全部集成钩子
-- ══════════════════════════════════════════════════════════════════════════
local opts = {
    -- ① 消耗品来源：给 game + storageLists 即可，内核自动去 inventory 与各存储列表找
    game = game,
    storageLists = function(g)
        return { g.inventory.items, g.warehouse.items }
    end,

    -- ② 编队：纯数据（这里是"从军械库选了 3 把枪"的结果）
    loadout = {
        { weapon = "rifle",   instanceId = "gunA" },
        { weapon = "emp",     instanceId = "gunB" },
        { weapon = "burner",  instanceId = "gunC", charge = 2 },  -- 起始自带 2 层充能
    },

    -- ③ 改装卡持久化：装/卸卡时回调，你负责扣库存 / 写自己的存档结构
    onEquipMod = function(o, instanceId, slot, modId)
        if not instanceId then return false, "该武器没有实物标识，不能改" end
        local mods = game.gunMods[instanceId] or {}
        if modId then
            mods[slot] = modId
        else
            mods[slot] = nil
        end
        game.gunMods[instanceId] = mods
        print(string.format("      [钩子] onEquipMod %s.%s = %s", instanceId, slot, tostring(modId)))
        return true, "已装配", mods
    end,

    -- ④ 道具消耗回调：把用掉的物品从真实背包里删掉
    --    注意内核已自行从原列表移除用尽的实物；此钩子只做「你自己的额外账务」
    --    （如统计、日志、同步服务器）。这里仅打印，不重复删除。
    onItemConsumed = function(o, ref)
        game.consumedCount = (game.consumedCount or 0) + 1
        print(string.format("      [钩子] onItemConsumed %s（累计 %d）", ref.id or "?", game.consumedCount))
    end,

    -- ⑤ 护甲减伤：按你自己的装备系统折算，返回 (最终伤害, 减免量)
    applyArmor = function(o, dmg, element, intent)
        local reduced = math.min(game.armorReduction, dmg)
        return dmg - reduced, reduced
    end,

    -- ⑥ 落库通知：任何影响持久态的操作成功后调用
    onSave = function(o)
        game.saveCount = game.saveCount + 1
        print(string.format("      [钩子] onSave（累计 %d 次）", game.saveCount))
    end,

    -- ⑦ 出征链：撤离后打下一场时用的新编队（不传则沿用当前编队）
    nextLoadout = {
        { weapon = "emp",    instanceId = "gunB" },
        { weapon = "burner", instanceId = "gunC" },
        { weapon = "flare",  instanceId = "gunD" },
    },
}

-- ══════════════════════════════════════════════════════════════════════════
-- 开战
-- ══════════════════════════════════════════════════════════════════════════
local progress = Progress.New()
-- 养成态：上缴贡献点 → 升级拿成长点 → 投一点体质
progress:Contribute(200)
progress:LevelUp()
progress:Invest("phys")                        -- 投一点体质，演示养成态参与建战

local s = Session.New(1, nil, nil, progress, opts)

print("── 建战 ──")
print(string.format("  我方 HP %d/%d 法力 %d", s.player.hp, s.player.maxHp, s.mana))
for i, w in ipairs(s.weapons) do
    local mods = {}
    for slot, mid in pairs(w.mods) do mods[#mods + 1] = slot .. "=" .. mid end
    print(string.format("  %d. %-8s instanceId=%s 已装卡[%s] 充能 %d",
        i, w.name, tostring(w.instanceId), table.concat(mods, ","), w.charge))
end

-- ══════════════════════════════════════════════════════════════════════════
-- 演示 1：装一张改装卡（触发 onEquipMod + onSave）
-- ══════════════════════════════════════════════════════════════════════════
print("\n── 演示 1：给 1 号枪装「高爆弹芯」──")
local ok, why = s:EquipMod(1, "muzzle", "frag_core")
print(string.format("  结果：%s  %s", tostring(ok), why or ""))
print(string.format("  宿主侧记忆：gunA.muzzle = %s", tostring(game.gunMods.gunA.muzzle)))

-- ══════════════════════════════════════════════════════════════════════════
-- 演示 2：收集并使用一个战斗道具（触发 onItemConsumed）
-- ══════════════════════════════════════════════════════════════════════════
print("\n── 演示 2：使用背包里的道具 ──")
local items = Session.CollectItems(opts)   -- 静态函数（点调用）
print(string.format("  收集到 %d 个可用消耗品：", items and #items or 0))
for i, it in ipairs(items or {}) do
    print(string.format("    %d. %s（剩余 %s 次）", i, it.name or it.id,
        tostring(it._remainingUses or it.uses or 1)))
end
if items and #items >= 1 then
    s:PickItem(1)
    local used, umsg = s:UsePendingItem()
    print(string.format("  使用第 1 个 → %s  %s", tostring(used), umsg or ""))
end

-- ══════════════════════════════════════════════════════════════════════════
-- 演示 3：打几回合，让护甲钩子（applyArmor）被敌方攻击触发
-- ══════════════════════════════════════════════════════════════════════════
print("\n── 演示 3：打几回合，观察 applyArmor 钩子 ──")
local guard = 0
while s.state == "running" and guard < 200 do
    guard = guard + 1
    for i = 1, #s.weapons do
        if s.state == "running" and not s.weapons[i].used then
            s:PlayWeapon(i, "normal", nil)
        end
    end
    if s.state == "running" and not s.playerActed then
        s:WaitPlayer()
    end
    if guard == 3 then
        print(string.format("  第3回合：HP %d/%d（护甲钩子已随敌方攻击触发）",
            s.player.hp, s.player.maxHp))
    end
end
print(string.format("  战斗结束：第%d回合 HP %d/%d 状态=%s",
    s.turn, s.player.hp, s.player.maxHp, s.state))

-- ══════════════════════════════════════════════════════════════════════════
-- 演示 4：出征链推进（新一场用 nextLoadout 的编队，血量/法力/养成跨场保留）
-- ══════════════════════════════════════════════════════════════════════════
print("\n── 演示 4：出征链推进到下一场 ──")
local s2 = s:Advance()
if s2 then
    print(string.format("  新一场：%s", s2.encounter.name))
    print(string.format("  血量继承 %d/%d，法力 %d（出征级资源不自动回满）",
        s2.player.hp, s2.player.maxHp, s2.mana))
    for i, w in ipairs(s2.weapons) do
        print(string.format("    %d. %-8s instanceId=%s", i, w.name, tostring(w.instanceId)))
    end
else
    print("  （当前不是胜利状态，无法推进出征链）")
end

print(string.format("\n宿主累计收到 onSave 调用 %d 次", game.saveCount))
