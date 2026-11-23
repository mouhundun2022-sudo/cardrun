-- examples/01_basic_battle.lua
--
-- 最小一场完整战斗：建战 → 三把武器各出手一次 → 人物行动 → 敌方回合结算 → 下一回合
--
-- 运行（在包根目录）：
--   lua5.4 examples/01_basic_battle.lua

local scriptPath = (arg and arg[0]) or "examples/01_basic_battle.lua"
local root = scriptPath:match("^(.*)[/\\]examples[/\\][^/\\]*$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Session = require("combat.session")
local Data = require("combat.data")

local function Dump(s, tag)
    print(string.format(
        "[%s] 第%d回合 阶段=%s | 我方 HP %d/%d 护甲 %d 法力 %d | 存活敌人 %d",
        tag, s.turn, s.phase,
        s.player.hp, s.player.maxHp, s.player.block, s.mana,
        #s.enemies))
end

-- 1) 建战：遭遇 1，默认预置构筑，法力回满，全新 1 级角色
local s = Session.New(1)
print("遭遇：" .. s.encounter.name .. "\n")
Dump(s, "建战")

-- 2) 打印编队（武器状态里的 defIndex 对应 Data.WEAPONS 的静态定义）
print("\n── 我方编队 ──")
for i, w in ipairs(s.weapons) do
    local def = Data.WEAPONS[w.defIndex]
    print(string.format(
        "  %d. %-10s [%s]  普攻「%s」%d伤  战技「%s」  终结技「%s」  充能 %d/%d",
        i, w.name, w.element,
        def.normal.name, def.normal.dmg,
        def.tech.name, def.ult.name,
        w.charge, def.chargeMax or Data.CHARGE_MAX))
end

print("\n── 敌军 ──")
for i, e in ipairs(s.enemies) do
    print(string.format("  %d. %-14s HP %d/%d  混乱 %d/%d",
        i, e.name, e.hp, e.maxHp, e.stagger, e.maxStagger))
end

-- 3) 我方回合：每把武器各有一次行动（普攻 / 战技 / 终结技 三选一）
print("\n── 我方回合 ──")

-- 普攻：造成伤害并给本武器充能 +1
local ok, msg = s:PlayWeapon(1, "normal", 1)
print(string.format("  武器1 普攻 → %s  %s", tostring(ok), msg or ""))

-- 战技：不产充能，但价值更高（AOE / 多段 / 弱化）
ok, msg = s:PlayWeapon(2, "tech", 1)
print(string.format("  武器2 战技 → %s  %s", tostring(ok), msg or ""))

-- 终结技需要充能攒满；刚开局充能为 0，这次会被拒绝
ok, msg = s:PlayWeapon(3, "ult", 1)
print(string.format("  武器3 终结技（充能不足）→ %s  %s", tostring(ok), msg or ""))

-- 换成普攻
ok, msg = s:PlayWeapon(3, "normal", 1)
print(string.format("  武器3 普攻 → %s  %s", tostring(ok), msg or ""))

Dump(s, "武器行动后")

-- 4) 人物行动：施法 / 防御 / 待命，共享这一个行动位。
--    三把武器已全部出手，人物一行动就自动进入敌方回合并结算。
print("\n  人物待命（WaitPlayer = 本回合防御，非弱点伤害 -20%）")
s:WaitPlayer()

Dump(s, "结算后")

-- 5) 自动打完剩下的回合
local guard = 0
while s.state == "running" and guard < 50 do
    guard = guard + 1
    for i = 1, #s.weapons do
        if s.state == "running" and not s.weapons[i].used then
            s:PlayWeapon(i, "normal", nil)
        end
    end
    if s.state == "running" and not s.playerActed then
        s:WaitPlayer()
    end
end

print(string.format("\n战斗结果：%s（共 %d 回合）", s.state, s.turn))
