-- ============================================================================
-- cardrun-combat · session.lua - 武器行动制战斗内核（纯逻辑，回合驱动，零引擎依赖）
-- 结构：我方回合 = 3 把上场武器各三选一出击 + 人物魔法 0~1 次（可跳过）；
--       终结技吃本武器 0~3 充能（普攻+1）；六属性=武器自带；
--       改装卡（C1-C4）：mods = { [槽名]=卡id }，4 槽固定、类别绑定校验、
--       主伤害永远按武器自带属性（C4），卡元素=附加效果词缀（燃烧/结霜/感电/圣光/附毒）；
--       混乱打满→崩溃（其下回合定身+期间受伤×1.5，随后混乱清零）；
--       护甲语义沿用 R3（下次我方回合开始清零）。Update 仅衰减打击反馈。
-- ============================================================================

local Data = require("combat.data")
local Progress = require("combat.progress")
local EnemyFormula = require("combat.enemy_formula")
local Modifiers = require("combat.modifiers")

---@class Session
---@field weapons table[]
---@field enemies table[]
---@field player table
---@field magic table
---@field mods ModifierSet
---@field items table[]
---@field fx table[]
---@field log table[]
---@field shots table[]
---@field timers table[]
---@field opts table?
---@field game table?
---@field progress table
---@field encounter table
---@field preset table
local Session = {}
Session.__index = Session

-- ============================================================================
-- 工具
-- ============================================================================

--- 0.5 防御行动：本回合承受的【非弱点伤害】减免（不产生护盾，与 block 独立叠加）
local DEFEND_REDUCTION = 0.20

--- 元素主色（引用 Data.ELEMENT_COLORS 单一事实源；伤害飘字按元素着色=颜色通道）
local ELEM_COLOR = Data.ELEMENT_COLORS

--- 克制/抵抗统一概念（T3 语义可视化规范，详见主文档"三点五之二·克制与抵抗概念规范"）：
---   ① 触发对象=敌人对该元素伤害的**有效抗性**（与伤害公式同源，非词缀非崩溃加成）；
---   ② 判定阈值=死区模型：resist ≤ -15 克制（增伤≥17%） / ≥ +15 抵抗（减伤≥13%） / 其余中性不打扰
---      （-15 覆盖全部弱点档，+15 恰好排除 +10/+12 级轻抗避免满屏反馈）；
---   ③ 双时机=**行动卡预测（出击前 ▲/▼）+ 命中飘字反馈（克制金→绿/抵抗蓝）**，同一判定单一函数；
---   ④ 颜色=克制绿 {110,235,150} 朝上箭头（增益语义） / 抵抗蓝 {110,190,255} 朝下箭头（减损语义），
---      全局唯一（指示器与飘字共用 FEEDBACK_COLORS）。
local FEEDBACK_SUPPRESS_COLOR = { 110, 235, 150 }   -- 克制=绿（▲）
local FEEDBACK_RESIST_COLOR = { 110, 190, 255 }     -- 抵抗=蓝（▼）
Session.FEEDBACK_COLORS = {
    ["克制"] = FEEDBACK_SUPPRESS_COLOR,
    ["抵抗"] = FEEDBACK_RESIST_COLOR,
}

---@param element string
---@param enemy table
---@return string? fb "克制"/"抵抗"/nil（中性）
local function ResistFeedback(element, enemy)
    local r = enemy.resist[element] or 0
    if r <= -15 then return "克制" end
    if r >= 15 then return "抵抗" end
    return nil
end
Session.ResistFeedback = ResistFeedback

--- 行动卡预测：该武器槽下一次普通出击将命中的目标 + 克制/抵抗档位（单一判定复用）。
--- 目标语义与 ResolveTargets 完全一致（显式>指定>自动首位），保证"预测即所得"。
---@param wIdx number 武器槽位
---@return table? { weapon, element, target, feedback } target 死亡/全灭=nil；中性 feedback=nil
function Session:GetWeaponPreview(wIdx)
    local wt = self.weapons[wIdx]
    if not wt then return nil end
    local tgt = nil
    if self.targetIdx then
        local spec = self.enemies[self.targetIdx]
        if spec and spec.hp > 0 then tgt = spec end
    end
    if not tgt then
        for _, e in ipairs(self.enemies) do if e.hp > 0 then tgt = e break end end
    end
    if not tgt then return nil end
    return {
        weapon = wt, element = wt.element, target = tgt,
        feedback = ResistFeedback(wt.element, tgt),
    }
end

--- T3 六属性伤害公式（无弹级乘区）：effResist = clamp(resist, -100, 95)
---@param base number 技能基础伤害
---@param element string
---@param enemy table
---@return number dmg
---@return number effResist 钳制后有效抗性（克制词缀结算按此减免）
local function ComputeDamage(base, element, enemy)
    local resist = enemy.resist[element] or 0
    local effResist = math.max(-100, math.min(95, resist))
    local dmg = base * (100 - effResist) / 100
    if enemy.collapsed then
        dmg = dmg * Data.COLLAPSE_DMG_MULT
    end
    return math.max(1, math.floor(dmg + 0.5)), effResist
end

--- C4 词缀附加效果常量（原型阶段用最简规则，正式期再进状态系统）
local EXTRA_BURN_DMG = 3    -- 火：每次出击结算后追加 3 点火伤（可被火抗减免）
local EXTRA_POISON_DMG = 2  -- 草：追加 2 点草伤（可被草抗减免）
local FROST_WEAKEN = 0.10   -- 冰：命中目标下次攻击 -10%
local SHOCK_STAGGER = 2     -- 电：每次命中额外混乱 +2
local HOLY_DMG_MULT = 0.10  -- 光：本次伤害 +10%

local VERBOSE = false

local function Log(state, msg)
    table.insert(state.log, { t = state.turn, msg = msg })
    if #state.log > 120 then table.remove(state.log, 1) end
    if VERBOSE then print(string.format("[combat][回合%d] %s", state.turn, msg)) end
end

--- 状态变更通知宿主落库（可选钩子）。内核自身不写任何存档，
--- 只在"会影响持久态的操作"成功后调用 opts.onSave(opts)。
---@param state table 会话
local function NotifySave(state)
    local opts = state.opts
    if opts and type(opts.onSave) == "function" then
        pcall(opts.onSave, opts)
    end
end

--- 六轮五·指挥手势信号（用户定案"一个手势就是发起进攻=走你"）：
--- 任何枪开火/施法/投掷/全场充能 = 人物挥臂一次（player.castT 置起，Renderer 切 cast 帧，
--- Update 衰减归零回 idle）。纯表现层戳，结算零依赖。
---@param state table 会话
local function Gesture(state)
    state.player.castT = math.max(state.player.castT or 0, 0.3)
end

--- 该武器的有效充能需求（基础 chargeMax + 配件/敌人修正）
--- 放在 TriggerPassive 之前：Lua 局部函数不能前向引用。
---@param state table 会话
---@param w table 武器运行时
---@return integer
local function ChargeReq(state, w)
    local def = Data.WEAPONS[w.defIndex]
    return Data.GetChargeRequirement(def, w, state.mods)
end

--- M5 统一被动触发器：武器与人物共用（trigger: on_hurt | on_collapse）
--- chargeSelf=仅该武器+n（武器专属被动）；chargeAll=全场武器+n（角色/团体被动）
---@param state table 会话
---@param trigger string
local function TriggerPassive(state, trigger)
    for _, w in ipairs(state.weapons) do
        local def = Data.WEAPONS[w.defIndex]
        local pv = Data.GetPassive(def.passive)
        if pv and pv.trigger == trigger then
            if pv.chargeSelf then
                w.charge = math.min(ChargeReq(state, w), w.charge + pv.chargeSelf)
                Log(state, string.format("🧬 %s 被动[%s]：本枪充能 +%d", def.name, pv.name, pv.chargeSelf))
            end
            if pv.chargeAll then
                for _, w2 in ipairs(state.weapons) do
                    w2.charge = math.min(ChargeReq(state, w2), w2.charge + pv.chargeAll)
                end
                Log(state, string.format("🧬 %s 被动[%s]：全场充能 +%d", def.name, pv.name, pv.chargeAll))
            end
        end
    end
    local cpv = Data.GetPassive(state.playerPassive)
    if cpv and cpv.trigger == trigger and cpv.chargeAll then
        for _, w2 in ipairs(state.weapons) do
            w2.charge = math.min(ChargeReq(state, w2), w2.charge + cpv.chargeAll)
        end
        Gesture(state)   -- 角色被动号令全场=挥臂指挥（武器自身被动不上身，动作语义只给"号令"）
        Log(state, string.format("🧬 %s 被动[%s]：全场充能 +%d", state.player.name, cpv.name, cpv.chargeAll))
    end
end

-- ============================================================================
-- 0.5 第三波：弱点命中附带效果（按元素分化）
--   dot      → 玩家持续伤害（复用 poisonDmg/poisonTurns 通道）
--   suppress → 全场武器充能需求 +N（Modifiers chargeReqAdd，限时）
--   healcut  → 治疗/护盾获取削减（player.healCutPct，回合结束递减）
-- 抵消配件生效（weaknessActive=false）时本函数不会被调用。
-- ============================================================================
---@param state table 会话
---@param element string 弱点元素
local function ApplyWeaknessDebuff(state, element)
    local d = Data.WEAKNESS_DEBUFF[element]
    if not d then return end
    local p = state.player
    if d.kind == "dot" then
        p.poisonDmg = (p.poisonDmg or 0) + d.value
        p.poisonTurns = math.max(p.poisonTurns or 0, d.turns)
        Log(state, string.format("🔥 弱点·%s → 每回合 -%d（%d 回合）", d.name, d.value, d.turns))
    elseif d.kind == "suppress" then
        state.mods:Add({
            scope = "weapon", stat = "chargeReqAdd",
            value = d.value, dur = d.turns, source = "weakness:" .. element,
        })
        Log(state, string.format("❄ 弱点·%s → 全场武器充能需求 +%d（%d 回合）", d.name, d.value, d.turns))
    elseif d.kind == "healcut" then
        p.healCutPct = math.max(p.healCutPct or 0, d.value)
        p.healCutTurns = math.max(p.healCutTurns or 0, d.turns)
        Log(state, string.format("✳ 弱点·%s → 治疗/护盾 -%d%%（%d 回合）",
            d.name, math.floor(d.value * 100 + 0.5), d.turns))
    end
    state:AddFloatText("弱点·" .. d.name, 0.5, 0.28, { 255, 130, 100 }, false, 0.24)
end

--- 治疗/护盾获取削弱后的实际值（healCutPct=0 时原样返回）
---@param state table
---@param value number
---@return integer
local function ApplyHealCut(state, value)
    local cut = state.player.healCutPct or 0
    if cut <= 0 then return math.floor(value + 0.5) end
    return math.max(0, math.floor(value * (1 - cut) + 0.5))
end

-- ============================================================================
-- 0.5 命中判定 / 防御 / 修正器消费
-- ============================================================================

--- 武器战技的修正器表（改造现有 6 个 tech，不新增技能位；见第一波文档 §5.5.5）
--- scope="enemy" 作用于命中目标；scope="weapon" 作用于本枪
local TECH_MODS = {
    cryo   = { { stat = "evadeAdd",     value = -0.10, dur = 2, scope = "enemy" } },
    flare  = { { stat = "hitAdd",       value = -0.15, dur = 2, scope = "enemy" } },
    emp    = { { stat = "blockGainMul", value = 0.70,  dur = 2, scope = "enemy" } },
    burner = { { stat = "defMul",       value = 1.15,  dur = 2, scope = "enemy" } },
    rifle  = { { stat = "hitAdd",       value = 0.10,  dur = 1, scope = "weapon" } },
    toxic  = { { stat = "extraHit",     value = 1,     dur = 0, scope = "weapon" } },
}

--- 单次命中判定（0.5）：单骰 + 保底 + 修正器。
--- 未命中不结算伤害/词缀/混乱，但仍产充能（否则是双重惩罚，见文档 §2.7）。
---@param state table 会话
---@param weaponState table 武器状态
---@param weaponDef table 武器定义
---@param enemy table 目标
---@param opts table?  可选：{ aoe=boolean, forcedRate=number }
---@return boolean hit
---@return number chance 本次判定使用的命中率
local function RollHit(state, weaponState, weaponDef, enemy, opts)
    opts = opts or {}
    -- 保底：连续未命中达到阈值 → 本次必中（逐武器独立计数）
    if EnemyFormula.ShouldPityHit(weaponState.missStreak) then
        weaponState.missStreak = 0
        return true, 1.0
    end
    local chance = opts.forcedRate
    if not chance then
        chance = EnemyFormula.GetHitChance({
            baseHit = EnemyFormula.GetWeaponBaseHit(weaponDef.id),
            modHit = state.mods:Query("hitAdd", "weapon", weaponState) + state.mods:Query("hitAdd", "player"),
            collapsed = enemy.collapsed,
            aoe = opts.aoe,
            targetEvade = (enemy.evade or 0) + state.mods:Query("evadeAdd", "enemy", enemy),
        })
    end
    local hit = math.random() < chance
    if hit then
        weaponState.missStreak = 0
    else
        weaponState.missStreak = (weaponState.missStreak or 0) + 1
    end
    return hit, chance
end

--- 战技修正器施加（命中后）
---@param state table
---@param weaponState table
---@param weaponDef table
---@param targets table[]
local function ApplyTechMods(state, weaponState, weaponDef, targets)
    local list = TECH_MODS[weaponDef.id]
    if not list then return end
    for _, m in ipairs(list) do
        if m.scope == "weapon" then
            state.mods:Add({
                scope = "weapon", target = weaponState, stat = m.stat,
                value = m.value, dur = m.dur, source = "tech:" .. weaponDef.id,
            })
        else
            for _, e in ipairs(targets) do
                state.mods:Add({
                    scope = "enemy", target = e, stat = m.stat,
                    value = m.value, dur = m.dur, source = "tech:" .. weaponDef.id,
                })
            end
        end
    end
    Log(state, string.format("✳ %s·战技 附加效果生效", weaponDef.name))
end

--- 测试接缝：命中率纯计算（无随机），供冒烟断言修正器链路
---@param weaponState table
---@param weaponDef table
---@param enemy table
---@param aoe boolean?
---@return number
function Session:_TestHitChance(weaponState, weaponDef, enemy, aoe)
    return EnemyFormula.GetHitChance({
        baseHit = EnemyFormula.GetWeaponBaseHit(weaponDef.id),
        modHit = self.mods:Query("hitAdd", "weapon", weaponState) + self.mods:Query("hitAdd", "player"),
        collapsed = enemy.collapsed,
        aoe = aoe,
        targetEvade = (enemy.evade or 0) + self.mods:Query("evadeAdd", "enemy", enemy),
    })
end

-- ============================================================================
-- 生命周期
-- ============================================================================

---@param encounterIdx number
---@param presetIdx number? 改装构筑索引（Data.PRESETS），nil=预置1（全裸基准）
---@param mana number? W2/W4 出征链传入的残余法力；nil=新出征，回满
---@param progress table? 角色养成永久态（combat.progress）；nil=自建 Lv1（兼容演示/旧调用）
---@param opts table? 可选扩展，纯数据 + 注入钩子：
---   loadout: 数组，每项 { weapon=武器id|下标, mods={slot->modId}, instanceId=任意标识, charge=起始充能 }。
---            不传则使用 Encounter 自带的预设编队（原型演示模式）。
---   itemLists: 数组的数组（消耗品来源，每项一个物品列表）。
---   game: 任意宿主对象；与 storageLists(game) 搭配用于取消耗品列表及（若存在）game.inventory。
---   storageLists: function(game) -> list[]，返回物品列表数组。
---   onEquipMod: function(opts, instanceId, slot, modId) -> ok, why, newMods，改装卡持久化钩子。
---   onItemConsumed: function(opts, itemRef, list)，物品被消耗后的回调钩子。
---   applyArmor: function(opts, dmg, element, intent) -> finalDmg, reduced，护甲/耐久减伤钩子。
---   onSave: function(opts)，状态变更后由宿主自行落库的钩子。
---   nextLoadout: 出征链下一战使用的新编队（Advance 时透传为 loadout）。
function Session.New(encounterIdx, presetIdx, mana, progress, opts)
    local self = setmetatable({}, Session)
    ---@type table[]
    local encounters = Data.ENCOUNTERS
    ---@type table[]
    local presets = Data.PRESETS
    self.encounter = encounters[encounterIdx]
    self.preset = presets[presetIdx or 1]
    -- 双保险：从持久化（如 JSON 存档）读回的是无元表裸表，下方 GetMaxHp 等方法会崩；
    -- Wrap 幂等重挂元表，已是实例时复用同一引用（调用方持有的 Progress 保持同一）。
    self.progress = Progress.Wrap(progress or Progress.New())
    self.opts = opts
    self.game = opts and opts.game or nil
    -- 地图战斗标记。true=战斗由外部地图/副本驱动，UI 可据此豁免出征链决策层
    -- （无"继续前进/撤离回营"），改走离场回调回地图。
    self.mapMode = false
    self.turn = 1
    self.phase = "player"      -- player | enemy（纯回合驱动，无时间流）
    self.state = "running"     -- running | victory | defeat
    self.log = {}
    self.fx = {}
    self.realTime = 0          -- 仅驱动飘字/震屏衰减
    self.shakeT = 0
    self.shakeMag = 0
    -- 表现层状态（纯数据，供 Renderer 插值；逻辑零依赖）
    self.shots = {}            -- 弹道：{ from="w1"|"player", x,y(归一化终点), t0, dur, element, thick, kind }
    self.timers = {}           -- 表现层延迟回调（仅视觉：命中震屏等）
    self.flashT = 0            -- 全屏闪光（终结技/大招）
    self.flashColor = nil
    self.pulse = nil           -- 施法脉冲：{ kind=heal|block|charge|magic, t0, dur }
    self.banner = nil          -- 回合横幅：{ text, t0, color }
    self.resultT = nil         -- 胜负揭示计时（state 非 running 时累计）
    -- 目标指定（复用 V2 "点战场敌人=设对位目标"交互；nil=自动取首个存活目标，行为不变）
    self.targetIdx = nil
    self.aim = nil             -- 瞄准提示（点击选中目标 1.5s）：{ idx, t0 }
    -- 六轮·焦点行动盘（崩铁式操作关系，用户定稿）：一屏只服务一个聚焦单位。
    -- 1..3=武器位（右簇显示该枪普攻/战技），4=人物（打开魔法书页）。纯 UI 态，结算零依赖。
    self.focusIdx = 1
    self.pendingMagic = nil    -- 书页已选未释放的魔法槽位（允许撤回；释放/取消清空）
    -- 0.5 统一修正器：武器战技 / 敌人 debuff / （第二波）配件 全部走这一张表
    self.mods = Modifiers.New()

    local maxHp = self.progress:GetMaxHp()        -- G2 体质支系加成
    local charDef = Data.GetCharacter(self.progress.characterId)  -- V8 6.5：出战角色定义
    self.player = {
        name = charDef.name,
        -- 出征链：opts.hp=上一战残余血量带伤进下一战（W2 同框架的出征级资源；nil=新出征满血）
        hp = (opts and opts.hp) and math.max(1, math.min(maxHp, opts.hp)) or maxHp,
        maxHp = maxHp,
        block = 0,             -- R3 护甲：下次我方回合开始清零
        flashT = 0,
        castT = 0,             -- 六轮五：指挥手势计时（>0=cast 帧，Renderer 表现层专用）
        defending = false,     -- 0.5 防御：本回合非弱点伤害 -20%（不产生护盾）
        -- 0.5 第三波：角色弱点（A 类元素暴露）。weakness=弱点元素字符串，供结算比对；
        -- weaknessData=完整定义（id/element/amp/desc）；weaknessActive=是否生效（抵消配件置 false）
        weakness = charDef.weakness and charDef.weakness.element or nil,
        weaknessData = charDef.weakness,
        weaknessActive = charDef.weakness ~= nil,
        healCutPct = 0,        -- 弱点 debuff：治疗/护盾获取削减比例（0~1）
        healCutTurns = 0,      -- 剩余回合
    }
    -- G1 链内待入账：每胜一场累计战利品折算贡献，撤离才入账、败北全没收（原型模拟值）
    self.pendingGains = (opts and opts.pendingGains) or 0
    self.lostGains = nil       -- 败北没收额（供 UI 播报一次）
    self.playerPassive = charDef.passive   -- M5 角色被动 id（V8 6.5：随出战角色）
    -- W2 出征级法力：跨战斗不恢复；nil=新出征回满，传入=出征链带残余进入下一战
    -- G2 法力支系：上限随加点成长
    local manaMax = self.progress:GetManaMax()
    self.mana = mana ~= nil and math.max(0, math.min(manaMax, mana)) or manaMax

    -- 武器状态机（T1/T2 × C1-C4）：每回合 used=false；charge 跨回合保留；
    -- mods = { [槽名]=卡id }（装载时已过 CanEquip 校验）
    -- ★ 独立内核版：上场编队=纯数据描述，由调用方自由决定——
    --   opts.loadout = { { weapon = "rifle", mods = {barrel="ext_barrel"}, instanceId = "...", charge = 0 },
    --                    { weapon = 3 }... }   -- weapon 可为武器 id 或 Data.WEAPONS 下标
    --   mods 为该枪已装改装卡（slot->modId）；instanceId 仅作调用方自己的标识（战斗内核不读存档）。
    --   不传 opts.loadout 时回退到遭遇自带 loadout（Data.ENCOUNTERS[i].loadout，演示/冒烟用）。
    self.weapons = {}
    local slotSrc = {}   -- 每个武器位 { defIndex, instanceId, modsRef }
    if opts and opts.loadout then
        for i = 1, Data.WEAPONS_PER_TEAM do
            local ld = opts.loadout[i]
            if ld then
                local widx = nil
                if type(ld.weapon) == "number" then
                    widx = Data.WEAPONS[ld.weapon] and ld.weapon or nil
                else
                    for k, w in ipairs(Data.WEAPONS) do if w.id == ld.weapon then widx = k break end end
                end
                if widx then
                    slotSrc[i] = { defIndex = widx, instanceId = ld.instanceId, modsRef = ld.mods, charge = ld.charge }
                end
            end
        end
    else
        for i, widx in ipairs(self.encounter.loadout) do
            slotSrc[i] = { defIndex = widx, instanceId = nil, modsRef = nil }
        end
    end
    for i = 1, Data.WEAPONS_PER_TEAM do
        local src = slotSrc[i]
        if src then
            local widx = src.defIndex
            local def = Data.WEAPONS[widx]
            -- 改装卡来源：调用方给定（opts.loadout[i].mods）优先，否则取原型 PRESETS 同槽构筑。
            -- 统一走 C2 类别绑定校验（不匹配静默跳过），两种来源零分叉。
            local mods, startCharge = {}, 0
            for slot, mid in pairs(src.modsRef or self.preset.mods[i] or {}) do
                if Data.CanEquip(mid, def) then
                    mods[slot] = mid
                    local mod = Data.GetMod(mid)
                    if mod and mod.startCharge then startCharge = startCharge + mod.startCharge end
                end
            end
            self.weapons[i] = {
                defIndex = widx, name = def.name, element = def.element,
                instanceId = src.instanceId,   -- 仅调用方标识（战斗内核不读存档/资产）
                mods = mods,
                charge = math.min(def.chargeMax or Data.CHARGE_MAX, src.charge or startCharge), used = false,
                -- 备弹制武器（smg 冲锋枪）：进入对战即填满备弹；之后不随回合补满，
                -- 需用「填充备弹」行动回弹。无该字段的武器为 nil（旧逻辑零影响）
                reserve = def.reserveMax, reserveMax = def.reserveMax,
                smgFired = false,    -- 本回合是否已射过备弹（射过则本回合不能填充备弹）
                missStreak = 0,      -- 0.5 命中保底计数（连续未命中，逐武器独立）
                frozenUntil = 0,     -- 0.5 终结技冻结到第 N 回合（boss 偷充能的温和版）
            }
        end
    end

    -- 0.5 第二波：配件 modifiers 注入（整场生效，dur=nil；与战技的临时修正器共用同一张表）
    self:RefreshModModifiers()

    -- 人物魔法池（T4 × G4：仅上场 4 槽参战，读 progress 有效技能=研习等级+法力减耗）
    -- cd>0 不可用；我方回合开始 cd-1；acted=本回合是否已用/跳过
    self.magic = {}
    local loadout = self.progress:GetLoadout()
    for i = 1, Data.MAGIC_SLOTS do
        local sk = loadout[i]
        self.magic[i] = sk and { def = sk, cd = 0 } or nil   -- 空槽=nil；有槽开局全亮
    end
    self.playerActed = false

    -- 敌人（T7 崩溃状态机沿用 collapseSkipPending 语义）
    self.enemies = {}
    for i, tmplId in ipairs(self.encounter.enemies) do
        local t = nil
        for _, tmpl in ipairs(Data.ENEMY_TEMPLATES) do if tmpl.id == tmplId then t = tmpl end end
        self.enemies[i] = {
            id = t.id, name = t.name, elite = t.elite, sprite = t.sprite,
            hp = t.hp, maxHp = t.hp, block = 0,
            maxStagger = t.maxStagger, stagger = 0,
            collapsed = false, collapseSkipPending = false,
            weakenPct = 0,
            resist = t.resist, intents = t.intents,
            intentIdx = math.random(#t.intents),
            -- 0.5：定位与闪避（原型模板未声明时 = nil/0，行为与旧版一致）
            archetype = t.archetype, evade = t.evade or 0,
            debuffCount = 0,
            flashT = 0, lungeT = 0,
            x = 0, y = 0, size = 0, px = 0, py = 0,
        }
    end

    -- 战斗道具（六轮四·E5）：真实模式=建战时从存储快照消耗品卡（引用持有，消耗即从实物删除）；
    -- 演示模式=DEMO_ITEMS 深拷贝（每战重发=模拟补给，冒烟/演示零风险）。
    self.items = Session.CollectItems(opts)
    self.pendingItem = nil     -- 已选未投放的道具位（与 pendingMagic 互斥的同类"待释放"态，可撤回）

    Log(self, "战斗开始：" .. self.encounter.name .. "（3 武器各 1 动 + 人物魔法 1 动）")
    return self
end

--- 0.5 第二波：重建配件 modifiers（整场生效项，dur=nil）。
--- New 时调用；军械库战内装/卸卡后也调用（配件 = 永久修正器，与战技临时修正器共用同表）。
function Session:RefreshModModifiers()
    self.mods:RemoveBySource("mod:")

    -- 0.5 第三波：弱点抵消配件扫描（counter = 弱点 id + 元素，两者都对上才生效）
    local wk = self.player.weaknessData
    local countered = false

    for _, w in ipairs(self.weapons) do
        for _, mid in pairs(w.mods or {}) do
            local mod = Data.GetMod(mid)
            if mod then
                if mod.modifiers then
                    for _, m in ipairs(mod.modifiers) do
                        local scope = m.scope or "weapon"
                        self.mods:Add({
                            scope = scope,
                            target = (scope == "weapon") and w or nil,
                            stat = m.stat,
                            value = m.value,
                            dur = nil,
                            source = "mod:" .. mid,
                        })
                    end
                end
                if wk and mod.counter == wk.id and mod.counterElement == wk.element then
                    countered = true
                end
            end
        end
    end

    if wk then
        local wasActive = self.player.weaknessActive
        self.player.weaknessActive = not countered
        if wasActive ~= self.player.weaknessActive then
            if self.player.weaknessActive then
                Log(self, string.format("⚠ 弱点「%s」重新生效", wk.name or wk.element))
            else
                Log(self, string.format("🛡 配件抵消弱点「%s」→ 该元素伤害回归正常", wk.name or wk.element))
            end
        end
    end
end

function Session:AddFloatText(text, x, y, color, big, delay, small)
    -- 横向漂移：同一位置连续跳多个数字（伤害/词缀/克制）时按条目序号错开，避免叠成一坨
    local seq = #self.fx + 1
    local dx = (((seq * 37) % 9) - 4) * 0.006
    table.insert(self.fx, { text = text, x = x or 0.5, y = y or 0.4, t0 = self.realTime + (delay or 0), dur = (big and 1.4) or (small and 0.7 or 0.9), color = color or { 255, 255, 255 }, big = big or false, small = small or false, dx = dx })
    if #self.fx > 24 then table.remove(self.fx, 1) end
end

--- 弹道事件（表现层）：从 from 武器位飞向敌人 e。delay=多段攻击错开；kind 决定粗细/色。
---@param from string "w1"|"w2"|"w3"|"player"
function Session:AddShot(from, e, kind, delay)
    local element
    if from ~= "player" then
        local wi = tonumber(string.sub(from, 2))
        local w = wi and self.weapons[wi]
        if w then element = w.element end
    end
    table.insert(self.shots, {
        from = from, x = e.x or 0.5, y = e.y or 0.4,
        t0 = self.realTime + (delay or 0), dur = 0.22, kind = kind or "normal", element = element or "none",
    })
    if #self.shots > 16 then table.remove(self.shots, 1) end
end

--- 表现层延迟回调（仅视觉：震屏/闪光等；严禁改战斗数值）。fn 只执行一次。
function Session:DelayFx(delay, fn)
    table.insert(self.timers, { at = self.realTime + delay, fn = fn })
end

-- ============================================================================
-- 主循环（仅反馈衰减；战斗推进全由玩家显式动作触发）
-- ============================================================================

---@param dt number 真实帧时间
function Session:Update(dt)
    self.realTime = self.realTime + dt
    -- 瞄准脉冲衰减（点击锁定后 1.5s 的视觉提示）
    if self.aim and self.realTime - self.aim.t0 > 1.5 then self.aim = nil end
    -- 指定目标倒下时清除，恢复自动选首个存活（避免锁定框悬在尸体上）
    if self.targetIdx then
        local te = self.enemies[self.targetIdx]
        if not te or te.hp <= 0 then self.targetIdx = nil end
    end
    if self.shakeT > 0 then self.shakeT = self.shakeT - dt end
    if self.flashT > 0 then self.flashT = self.flashT - dt end
    if self.resultT ~= nil and self.state ~= "running" then
        self.resultT = self.resultT + dt
    end
    if self.player.flashT > 0 then self.player.flashT = self.player.flashT - dt end
    if self.player.castT and self.player.castT > 0 then self.player.castT = self.player.castT - dt end
    for _, w in ipairs(self.weapons) do
        if w.kickT and w.kickT > 0 then w.kickT = w.kickT - dt end
    end
    for _, e in ipairs(self.enemies) do
        if e.flashT > 0 then e.flashT = e.flashT - dt end
        if e.lungeT > 0 then e.lungeT = e.lungeT - dt end
    end
    -- 弹道清理（起点未命中的旧弹直接丢弃，上限防泄漏）
    local keep = {}
    for _, s in ipairs(self.shots) do
        if self.realTime - s.t0 < s.dur + 0.05 then table.insert(keep, s) end
    end
    self.shots = keep
    -- 表现层延迟回调（命中震屏等）
    if #self.timers > 0 then
        local due = {}
        local rest = {}
        for _, t in ipairs(self.timers) do
            if self.realTime >= t.at then table.insert(due, t.fn) else table.insert(rest, t) end
        end
        self.timers = rest
        for _, fn in ipairs(due) do
            local ok, err = pcall(fn)
            if not ok and VERBOSE then print("[combat] fx timer error: " .. tostring(err)) end
        end
    end
end

-- ============================================================================
-- 军械库：改装卡装卸（C1 槽位 / C2 类别绑定）
-- ============================================================================

--- 装卡：校验类别绑定 + 槽位归属；成功返回 true。不影响回合进行（军械库=战外行为）。
---@param wIdx number 上场武器位 1~3
---@param slot string barrel|grip|muzzle|module
---@param modId string? 传 nil 或 "" = 卸下该槽
---@return boolean ok, string why
function Session:EquipMod(wIdx, slot, modId)
    local w = self.weapons[wIdx]
    if not w then return false, "无此武器位" end
    local def = Data.WEAPONS[w.defIndex]
    -- 可选持久化钩子：把改装卡写回调用方自己的存储（扣/回库存等）。
    -- 仅当武器带 instanceId（调用方实物标识）且 opts.onEquipMod 存在时生效；
    -- 未提供钩子=纯内存改装（独立内核默认，不触碰任何存档）。
    if w.instanceId and self.opts and self.opts.onEquipMod then
        local ok, why, newMods = self.opts.onEquipMod(self.opts, w.instanceId, slot, modId)
        if not ok then return false, why or "改装失败" end
        if newMods then w.mods = newMods end
        self:RefreshModModifiers()
        NotifySave(self)
        return true, why
    end
    if modId == nil or modId == "" then
        w.mods[slot] = nil
        self:RefreshModModifiers()
        NotifySave(self)
        return true, "卸下"
    end
    local mod = Data.GetMod(modId)
    if not mod then return false, "无此卡" end
    if mod.slot ~= slot then return false, string.format("%s 是%s卡，装不进%s槽", mod.name, Data.SLOT_NAMES[mod.slot], Data.SLOT_NAMES[slot]) end
    if not Data.CanEquip(modId, def) then
        return false, string.format("❌ %s 不适配 %s（%s专属）", mod.name, def.name, table.concat((function()
            local names = {}
            for cat in pairs(mod.cats) do table.insert(names, Data.CATEGORY_NAMES[cat]) end
            table.sort(names)
            return names
        end)(), "/"))
    end
    w.mods[slot] = modId
    self:RefreshModModifiers()
    NotifySave(self)
    return true, string.format("%s → %s[%s]", mod.name, def.name, Data.SLOT_NAMES[slot])
end

-- ============================================================================
-- 改装卡合成（M1 × C3/C4）：基础技能 × 已装卡 → 有效技能
-- ============================================================================

--- 把武器基础技能与该武器已装的改装卡合并成实际生效的技能表
---@param weaponState table 武器运行时（含 defIndex/mods）
---@param kind string "normal" | "tech" | "ult"
---@return table eff 有效技能 { dmg, stagger, hits, aoe, weaken, chargeAdd, collapsedBonus, extras, name }
function Session:ResolveSkill(weaponState, kind)
    local def = Data.WEAPONS[weaponState.defIndex]
    local base = def[kind]
    local eff = {
        name = base.name, dmg = base.dmg or 0, stagger = base.stagger or 0,
        hits = base.hits, aoe = base.aoe, weaken = base.weaken,
        chargeAdd = 0, collapsedBonus = 0, extras = {},
    }
    for slot, mid in pairs(weaponState.mods or {}) do
        local mod = Data.GetMod(mid)
        if mod then
            local a = mod.apply
            local applies = (a == kind) or (a == "all") or (type(a) == "table" and a[kind])
            if applies then
                if mod.dmgMult then eff.dmg = eff.dmg * (1 + mod.dmgMult) end
                if mod.dmgAdd then eff.dmg = eff.dmg + mod.dmgAdd end
                if mod.staggerMult then eff.stagger = eff.stagger * (1 + mod.staggerMult) end
                if mod.hitsAdd then eff.hits = (eff.hits or 1) + mod.hitsAdd end
                if mod.aoeForce then eff.aoe = true end
                if mod.aoeOff then eff.aoe = nil end          -- 独头弹/破门收束：AoE 转单体
                if mod.chargeAdd then eff.chargeAdd = eff.chargeAdd + mod.chargeAdd end
                if mod.collapsedBonus then eff.collapsedBonus = eff.collapsedBonus + mod.collapsedBonus end
                -- C3/C4：卡元素=效果词缀，收集到 extras（主伤害仍按武器属性算，不相乘）
                if mod.element and mod.element ~= "none" then
                    eff.extras[mod.element] = true
                end
            end
            -- 词缀也作用于开局被动（过载电池的感电不在此，startCharge 在 New 已处理）
        end
    end
    eff.dmg = math.floor(eff.dmg + 0.5)
    eff.stagger = math.floor(eff.stagger + 0.5)
    return eff
end

-- ============================================================================
-- 玩家行动
-- ============================================================================

--- 武器出击（T1 三选一，出击后本回合耗尽；T2 充能规则；M1/C1-C4 改装合成与词缀结算）
---@param wIdx number 上场武器索引 1~3
---@param skillKind string "normal" | "tech" | "ult"
---@param targetIdx number?
function Session:PlayWeapon(wIdx, skillKind, targetIdx)
    if self.state ~= "running" then return false, "战斗已结束" end
    if self.phase ~= "player" then return false, "现在是敌方回合" end
    local w = self.weapons[wIdx]
    if not w then return false, "无此武器位" end
    if w.used then return false, w.name .. " 本回合已出击" end
    if skillKind ~= "normal" and skillKind ~= "tech" and skillKind ~= "ult" then
        return false, "无此技能"
    end
    local req = ChargeReq(self, w)
    local def = Data.WEAPONS[w.defIndex]
    -- 无该技能段的武器（备弹制冲锋枪：无战技/终结技）：必须先于充能检查拒绝，
    -- 否则 0 充能会被 GetChargeRequirement 的下限 2 钳成"充能不足（0/2）"这种误导提示。
    -- 其余武器三段技能齐全，此分支对它们永不触发（零行为变化）。
    if def[skillKind] == nil then
        return false, string.format("%s 没有%s", w.name, skillKind == "tech" and "战技" or "终结技")
    end
    if skillKind == "ult" and w.charge < req then
        return false, string.format("%s 充能不足（%d/%d）", w.name, w.charge, req)
    end
    -- 0.5 终结技冻结（boss 偷充能的温和版：充能不消失，只是本回合开不出）
    if skillKind == "ult" and self.turn <= (w.frozenUntil or 0) then
        return false, string.format("%s 终结技被冻结（至第 %d 回合）", w.name, w.frozenUntil)
    end

    local skill = self:ResolveSkill(w, skillKind)
    local targets = self:ResolveTargets(skill, targetIdx)
    if #targets == 0 then return false, "没有存活目标" end

    -- C4 圣光词缀：本次所有伤害 +10%
    local holyMult = skill.extras.light and (1 + HOLY_DMG_MULT) or 1
    -- C4 感电词缀：每次命中额外混乱 +2
    local shockBonus = skill.extras.electric and SHOCK_STAGGER or 0

    -- 表现层：武器后坐 + 每目标每段错峰的弹道（终结技=金色粗弹+屏幕闪光）
    w.kickT = 0.24
    Gesture(self)   -- 六轮五：开枪=一个"走你"挥臂手势（用户定案）
    local shotKind = skillKind
    if skillKind == "ult" then
        self.flashT, self.flashColor = 0.14, { 255, 200, 90 }
    end

    -- 结算（M5：本回合新产生的崩溃延迟到行动后统一触发，防同次攻击内滚雪球）
    local anyCollapsed = false
    local anyHit = false
    -- 0.5 修正器：武器输出乘区（atkMul）；目标受伤乘区（defMul）逐目标读取
    local atkMul = self.mods:Query("atkMul", "weapon", w)
    -- AOE 一次掷骰对全体生效（闪避按存活目标平均值，避免单体高闪避拖累整个 AOE）
    local aoeHit = nil
    if skill.aoe then
        local sumEvade, nTargets = 0, 0
        for _, e in ipairs(targets) do
            sumEvade = sumEvade + (e.evade or 0) + self.mods:Query("evadeAdd", "enemy", e)
            nTargets = nTargets + 1
        end
        local avgEvade = nTargets > 0 and (sumEvade / nTargets) or 0
        if EnemyFormula.ShouldPityHit(w.missStreak) then
            aoeHit = true
            w.missStreak = 0
        else
            local chance = EnemyFormula.GetHitChance({
                baseHit = EnemyFormula.GetWeaponBaseHit(def.id),
                modHit = self.mods:Query("hitAdd", "weapon", w) + self.mods:Query("hitAdd", "player"),
                aoe = true,
                targetEvade = avgEvade,
            })
            aoeHit = math.random() < chance
            w.missStreak = aoeHit and 0 or ((w.missStreak or 0) + 1)
        end
    end

    for ti, e in ipairs(targets) do
        local dmg = 0
        local hits = skill.hits or 1
        local tDelay = (ti - 1) * 0.12
        local defMul = self.mods:Query("defMul", "enemy", e)
        -- 0.5 第二波：AOE 单体衰减——只打到 1 个目标时伤害 ×0.85，
        -- 否则"覆盖型"武器打单体反而强于专精枪，定位与数值矛盾。
        local aoeSoloMul = (skill.aoe and #targets == 1) and 0.85 or 1
        local hitCount = 0
        for hi = 1, hits do
            -- 0.5 命中判定：单骰 + 保底；未命中不结算伤害/词缀/混乱（充能仍由外层统一发放）
            local hit = skill.aoe and aoeHit or RollHit(self, w, def, e, { aoe = false })
            if hit then
                hitCount = hitCount + 1
                local one = ComputeDamage(skill.dmg * atkMul * aoeSoloMul, def.element, e)
                if defMul ~= 1 then one = math.floor(one * defMul + 0.5) end
                if holyMult > 1 then one = math.floor(one * holyMult + 0.5) end
                -- M1 破溃增幅：崩溃增伤作为额外乘区（ComputeDamage 内已含 ×1.5）
                if e.collapsed and skill.collapsedBonus > 0 then
                    one = math.floor(one * (1 + skill.collapsedBonus) + 0.5)
                end
                dmg = dmg + one
            else
                self:AddFloatText("闪避", e.x or 0.5, (e.y or 0.4) - 0.16,
                    { 190, 200, 215 }, false, tDelay + (hi - 1) * 0.09, true)
            end
            -- 弹道按"段"错峰（终结技多发更壮观）；命中结算仍即时（伤害数字与血条同步）
            self:AddShot("w" .. wIdx, e, shotKind, tDelay + (hi - 1) * 0.09)
        end
        if hitCount == 0 then
            Log(self, string.format("%s·%s → %s 闪避（未命中）", def.name, skill.name, e.name))
        end
        if hitCount > 0 then
        anyHit = true
        local hitAt = 0.10 + tDelay + (hits - 1) * 0.09
        -- 0.5 extraHit：本枪命中后追加一段（一次性修正器，消费即失效）
        if self.mods:Query("extraHit", "weapon", w) > 0 then
            self.mods:Consume("extraHit", "weapon", w)
            local extra = ComputeDamage(skill.dmg * atkMul, def.element, e)
            if defMul ~= 1 then extra = math.floor(extra * defMul + 0.5) end
            dmg = dmg + extra
            self:AddShot("w" .. wIdx, e, shotKind, tDelay + 0.09)
            self:AddFloatText(string.format("追加%d", extra), e.x or 0.5, (e.y or 0.4) - 0.22,
                ELEM_COLOR[def.element] or { 255, 255, 255 }, false, hitAt + 0.09, true)
            Log(self, string.format("✳ %s 追加一段 -%d", def.name, extra))
        end
        local blocked = math.min(e.block, dmg)
        e.block = e.block - blocked
        dmg = dmg - blocked
        e.hp = math.max(0, e.hp - dmg)
        e.flashT = 0.15 + hitAt   -- 前段为弹道飞行时间（Renderer 只在 <=0.15 时画闪白）
        -- 打击感：弹道到达那一刻给一次短促震屏（伤害越高越明显，封顶防晕；纯表现）
        if dmg > 0 then
            local mag = math.min(6.5, 2.0 + dmg * 0.09)
            self:DelayFx(hitAt, function()
                if mag >= (self.shakeMag or 0) then
                    self.shakeT = math.max(self.shakeT or 0, 0.16)
                    self.shakeMag = mag
                end
            end)
        end
        if e.hp <= 0 then
            e.deathT = self.realTime + hitAt   -- 死亡溶解起点（弹道到达后开始）
        end
        self:AddFloatText(string.format("-%d", dmg), e.x or 0.5, (e.y or 0.4) - 0.1,
            ELEM_COLOR[def.element] or ELEM_COLOR.none, false, hitAt)
        -- 克制/抵抗反馈（与行动卡预测同一判定；颜色统一=克制绿/抵抗蓝）
        local fb = ResistFeedback(def.element, e)
        if fb then
            self:AddFloatText(fb, (e.x or 0.5) + 0.04, (e.y or 0.4) - 0.16,
                Session.FEEDBACK_COLORS[fb], false, hitAt, true)
        end
        if blocked > 0 then
            self:AddFloatText(string.format("甲-%d", blocked), (e.x or 0.5) + 0.05, (e.y or 0.4) - 0.03, { 160, 180, 210 }, false, hitAt)
        end
        if skill.weaken and dmg > 0 then
            e.weakenPct = skill.weaken
        end
        -- C4 结霜词缀：命中减攻（与技能自带 weaken 取较大值，不叠乘）
        if skill.extras.ice and dmg > 0 and e.weakenPct < FROST_WEAKEN then
            e.weakenPct = FROST_WEAKEN
        end
        -- 0.5 混乱累积乘区（staggerMul）
        local staggerMul = self.mods:Query("staggerMul", "enemy", e)
        local staggerGain = math.floor(skill.stagger * staggerMul + 0.5) + shockBonus
        if not e.collapsed and staggerGain > 0 then
            e.stagger = e.stagger + staggerGain
            if e.stagger >= e.maxStagger then
                e.collapsed = true
                e.collapseSkipPending = true
                e.stagger = e.maxStagger
                anyCollapsed = true
                self.shakeT, self.shakeMag = 0.35, 6
                self:AddFloatText("混乱崩溃！", e.x or 0.5, e.y or 0.4, { 200, 120, 255 }, true)
                Log(self, string.format("💥 %s 混乱崩溃！它下回合定身跳过，期间对它受伤 ×%s", e.name, Data.COLLAPSE_DMG_MULT))
            end
        end
        -- C4 词缀附加伤害（燃烧/附毒）：本次实际掉血才追加，按敌人对应抗性结算
        local extraTxt = ""
        if dmg > 0 and (skill.extras.fire or skill.extras.nature) then
            local extraDmg = 0
            local extraElem
            if skill.extras.fire then
                local d = ComputeDamage(EXTRA_BURN_DMG, "fire", e)
                extraDmg = extraDmg + d
                extraElem = "fire"
            end
            if skill.extras.nature then
                local d = ComputeDamage(EXTRA_POISON_DMG, "nature", e)
                extraDmg = extraDmg + d
                extraElem = extraElem or "nature"   -- 双词缀时以火为主色（结算仍是合并值）
            end
            local eblocked = math.min(e.block, extraDmg)
            e.block = e.block - eblocked
            extraDmg = extraDmg - eblocked
            e.hp = math.max(0, e.hp - extraDmg)
            if extraDmg > 0 then
                self:AddFloatText(string.format("词%d", extraDmg), e.x or 0.5, (e.y or 0.4) - 0.16,
                    ELEM_COLOR[extraElem] or { 255, 160, 60 }, false)
                extraTxt = string.format(" +%d词伤", extraDmg)
            end
        end
        local extrasTxt = {}
        for elem in pairs(skill.extras) do table.insert(extrasTxt, Data.ELEMENT_NAMES[elem]) end
        table.sort(extrasTxt)
        Log(self, string.format("%s·%s(%s)%s%s → %s -%d 伤害，混乱 %d/%d%s%s%s",
            def.name, skill.name, Data.ELEMENT_NAMES[def.element],
            (skill.hits and skill.hits > 1) and ("×" .. skill.hits) or (skill.aoe and "[全体]" or ""),
            #extrasTxt > 0 and ("[" .. table.concat(extrasTxt, "") .. "词]") or "",
            e.name, dmg, e.stagger, e.maxStagger,
            blocked > 0 and string.format("（挡%d）", blocked) or "",
            extraTxt,
            e.collapsed and " 【崩溃】" or ""))
        if e.hp <= 0 then
            Log(self, "☠ " .. e.name .. " 被击杀")
        end
        end -- if hitCount > 0
    end

    -- T2 充能流转：普攻 +1（+改装 chargeAdd），终结技清空，战技不动
    -- 0.5 chargeDelta：充能压制/增益（负值同样拖慢普攻）
    local chargeDelta = math.floor(self.mods:Query("chargeDelta", "weapon", w))
    if skillKind == "normal" then
        w.charge = math.max(0, math.min(ChargeReq(self, w),
            w.charge + Data.CHARGE_ON_NORMAL + skill.chargeAdd + chargeDelta))
    elseif skillKind == "ult" then
        w.charge = 0
    end
    w.used = true

    -- 0.5 战技修正器（改造现有 tech，不新增技能位）：命中后施加到目标/本枪
    if skillKind == "tech" and anyHit then
        ApplyTechMods(self, w, def, targets)
    end

    -- M5：本次行动新产生崩溃 → 触发 on_collapse 被动（角色"崩溃号令"全场+1）
    if anyCollapsed then
        TriggerPassive(self, "on_collapse")
    end

    self:CheckEnd()
    self:AutoEndIfAllActed()
    -- 焦点盘：聚焦单位提交行动后自动跳下一未行动者（非聚焦单位经队伍条行动不抢焦点）
    if self.state == "running" and self.phase == "player" and self.focusIdx == wIdx then
        self:AdvanceFocus(wIdx)
    end
    return true, skill.name
end

--- 备弹制武器开一枪（0.5 测试枪·雷霆冲锋枪）：每次消耗 1 备弹，不结束该武器回合。
--- 只有备弹射空才落 used（点击打空 / 长按打空同一收口）；不改充能（该枪无终结技）。
---@param wIdx number 武器位
---@param targetIdx number? 显式目标（nil=全队指定/自动首位）
---@return boolean ok
---@return string? msg 技能名或拒绝原因
function Session:FireSmg(wIdx, targetIdx)
    if self.state ~= "running" then return false, "战斗已结束" end
    if self.phase ~= "player" then return false, "现在是敌方回合" end
    local w = self.weapons[wIdx]
    if not w then return false, "无此武器位" end
    if w.used then return false, w.name .. " 本回合已出击" end
    if not w.reserveMax then return false, "该武器不是备弹制" end
    if (w.reserve or 0) <= 0 then return false, w.name .. " 备弹已空" end

    local def = Data.WEAPONS[w.defIndex]
    local skill = self:ResolveSkill(w, "normal")
    local targets = self:ResolveTargets(skill, targetIdx)
    if #targets == 0 then return false, "没有存活目标" end
    local e = targets[1]

    w.reserve = w.reserve - 1
    w.smgFired = true      -- 本回合已射过→本回合不能再填充备弹（用户约束：射过就不能补）
    w.kickT = 0.24
    Gesture(self)

    local hitAt = 0.10
    local hit = RollHit(self, w, def, e, { aoe = false })
    self:AddShot("w" .. wIdx, e, "normal", 0)

    if hit then
        local holyMult = skill.extras.light and (1 + HOLY_DMG_MULT) or 1
        local shockBonus = skill.extras.electric and SHOCK_STAGGER or 0
        local defMul = self.mods:Query("defMul", "enemy", e)
        local atkMul = self.mods:Query("atkMul", "weapon", w)
        local dmg = ComputeDamage(skill.dmg * atkMul, def.element, e)
        if defMul ~= 1 then dmg = math.floor(dmg * defMul + 0.5) end
        if holyMult > 1 then dmg = math.floor(dmg * holyMult + 0.5) end
        if e.collapsed and skill.collapsedBonus > 0 then
            dmg = math.floor(dmg * (1 + skill.collapsedBonus) + 0.5)
        end
        local blocked = math.min(e.block, dmg)
        e.block = e.block - blocked
        dmg = dmg - blocked
        e.hp = math.max(0, e.hp - dmg)
        e.flashT = 0.15 + hitAt
        if dmg > 0 then
            local mag = math.min(6.5, 2.0 + dmg * 0.09)
            self:DelayFx(hitAt, function()
                if mag >= (self.shakeMag or 0) then
                    self.shakeT = math.max(self.shakeT or 0, 0.16)
                    self.shakeMag = mag
                end
            end)
        end
        if e.hp <= 0 then e.deathT = self.realTime + hitAt end
        self:AddFloatText(string.format("-%d", dmg), e.x or 0.5, (e.y or 0.4) - 0.1,
            ELEM_COLOR[def.element] or ELEM_COLOR.none, false, hitAt)
        local fb = ResistFeedback(def.element, e)
        if fb then
            self:AddFloatText(fb, (e.x or 0.5) + 0.04, (e.y or 0.4) - 0.16,
                Session.FEEDBACK_COLORS[fb], false, hitAt, true)
        end
        if blocked > 0 then
            self:AddFloatText(string.format("甲-%d", blocked), (e.x or 0.5) + 0.05, (e.y or 0.4) - 0.03,
                { 160, 180, 210 }, false, hitAt)
        end
        local staggerMul = self.mods:Query("staggerMul", "enemy", e)
        local staggerGain = math.floor(skill.stagger * staggerMul + 0.5) + shockBonus
        local anyCollapsed = false
        if not e.collapsed and staggerGain > 0 then
            e.stagger = e.stagger + staggerGain
            if e.stagger >= e.maxStagger then
                e.collapsed = true
                e.collapseSkipPending = true
                e.stagger = e.maxStagger
                anyCollapsed = true
                self.shakeT, self.shakeMag = 0.35, 6
                self:AddFloatText("混乱崩溃！", e.x or 0.5, e.y or 0.4, { 200, 120, 255 }, true)
                Log(self, string.format("💥 %s 混乱崩溃！它下回合定身跳过，期间对它受伤 ×%s",
                    e.name, Data.COLLAPSE_DMG_MULT))
            end
        end
        Log(self, string.format("%s·%s(%s) → %s -%d 伤害，混乱 %d/%d（备弹 %d/%d）",
            def.name, skill.name, Data.ELEMENT_NAMES[def.element], e.name, dmg,
            e.stagger, e.maxStagger, w.reserve, w.reserveMax))
        if e.hp <= 0 then Log(self, "☠ " .. e.name .. " 被击杀") end
        if anyCollapsed then TriggerPassive(self, "on_collapse") end
    else
        Log(self, string.format("%s·%s → %s 闪避（未命中）（备弹 %d/%d）",
            def.name, skill.name, e.name, w.reserve, w.reserveMax))
    end

    self:CheckEnd()

    -- 只有备弹射空才结束该武器本回合行动；未射空保持未出击、焦点留在此枪
    if self.state == "running" and (w.reserve or 0) <= 0 then
        w.used = true
        self:AutoEndIfAllActed()
        if self.phase == "player" and self.focusIdx == wIdx then
            self:AdvanceFocus(wIdx)
        end
        return true, skill.name .. "（备弹已空）"
    end
    return true, skill.name
end

--- 填充备弹（0.5 备弹枪战术位）：把当前备弹补满到 reserveMax，占该武器一次行动（used=true）。
--- 每回合不再自动补满，玩家需用这一行动决定"补弹还是继续射击"。
--- 约束：本回合只要射击过就不能填充（smgFired），满弹时也不能填充。
---@param wIdx number 武器位
---@return boolean ok
---@return string? msg
function Session:FillReserve(wIdx)
    if self.state ~= "running" then return false, "战斗已结束" end
    if self.phase ~= "player" then return false, "现在是敌方回合" end
    local w = self.weapons[wIdx]
    if not w then return false, "无此武器位" end
    if w.used then return false, w.name .. " 本回合已出击" end
    if not w.reserveMax then return false, "该武器不是备弹制" end
    if w.smgFired then return false, "本回合已射击，需下回合才能填充备弹" end
    if (w.reserve or 0) >= w.reserveMax then return false, w.name .. " 备弹已满" end

    w.reserve = w.reserveMax
    w.used = true     -- 填充占该武器本回合行动
    Log(self, string.format("🔄 %s 填充备弹 → %d/%d（本回合该武器不再射击）",
        w.name, w.reserve, w.reserveMax))

    self:AutoEndIfAllActed()
    if self.state == "running" and self.phase == "player" and self.focusIdx == wIdx then
        self:AdvanceFocus(wIdx)
    end
    return true, w.name .. " 填充备弹"
end

--- 点击战场敌人指定目标（复用 V2 "点敌人=设对位目标"交互语义：全队共享当前指定目标）。
--- 传 nil 或非法/死亡索引 = 清除指定，恢复自动选首个存活目标。
---@param enemyIdx number?
---@return boolean ok, string why
function Session:SetTarget(enemyIdx)
    if not enemyIdx then
        self.targetIdx = nil
        return true, "已清除指定目标（自动攻击首个敌人）"
    end
    local e = self.enemies[enemyIdx]
    if not e or e.hp <= 0 then return false, "目标不存在或已倒下" end
    self.targetIdx = enemyIdx
    self.aim = { idx = enemyIdx, t0 = self.realTime }
    return true, "锁定目标：" .. e.name
end

-- ============================================================================
-- 六轮·焦点行动盘（崩铁式"一屏一聚焦"+魔法书页，用户定案）
-- 纯 UI 状态：focusIdx/pendingMagic 不进任何伤害/结算判定，冒烟逻辑零依赖
-- ============================================================================

--- 单位是否已行动（1..3=武器位，4=人物）。空武器位视为已耗尽（不阻塞焦点推进）。
---@param u number
function Session:IsUnitActed(u)
    if u >= 1 and u <= 3 then
        local w = self.weapons[u]
        return (not w) or w.used
    end
    return self.playerActed
end

--- 切换聚焦单位。已行动单位也可聚焦（供查看，右簇按钮全灰）；敌方回合禁切。
--- 离开人物聚焦清除待释放魔法（防书页半开态）。
---@param idx number 1..4
---@return boolean ok
function Session:SetFocus(idx)
    if type(idx) ~= "number" or idx < 1 or idx > 4 then return false end
    if self.phase ~= "player" then return false end
    self.focusIdx = idx
    if idx ~= 4 then self.pendingMagic = nil end
    self.pendingItem = nil
    return true
end

--- 行动提交后焦点自动跳下一未行动单位（从 fromIdx 起顺时针 枪1→枪2→枪3→人物，跳过已行动）。
---@param fromIdx number? 默认当前 focusIdx
---@return number? 新焦点（全部已行动返回 nil）
function Session:AdvanceFocus(fromIdx)
    fromIdx = fromIdx or self.focusIdx
    for step = 1, 4 do
        local nxt = ((fromIdx - 1 + step) % 4) + 1
        if not self:IsUnitActed(nxt) then
            self.focusIdx = nxt
            self.pendingMagic = nil
            self.pendingItem = nil
            return nxt
        end
    end
    return nil
end

--- 魔法书页：选中魔法（校验通过记为待释放，不扣资源；未释放前可撤回）
---@param mIdx number
---@return boolean ok, string why, boolean needsTarget
function Session:PickMagic(mIdx)
    if self.state ~= "running" then return false, "战斗已结束", false end
    if self.phase ~= "player" then return false, "现在是敌方回合", false end
    if self.playerActed then return false, "本回合人物已行动", false end
    local m = self.magic[mIdx]
    if not m then return false, "无此技能", false end
    if m.cd > 0 then return false, string.format("%s 冷却中（%d回合）", m.def.name, m.cd), false end
    local cost = m.def.mp or 0
    if cost > self.mana then
        return false, string.format("法力不足（%d/%d，需要%d）", self.mana, Data.MANA_MAX, cost), false
    end
    self.pendingMagic = mIdx
    self.pendingItem = nil     -- 与 PickItem 互斥对称（待选态同时只有一个）
    return true, m.def.name, m.def.kind == "damage"
end

--- 释放待施魔法（目标技传入点击的敌人位；非目标技 enemyIdx=nil）。失败保留选中态便于重选。
function Session:CastPending(enemyIdx)
    if not self.pendingMagic then return false, "未选择魔法" end
    local m = self.magic[self.pendingMagic]
    if m and m.def.kind == "damage" then
        local e = enemyIdx and self.enemies[enemyIdx]
        if not e or e.hp <= 0 then return false, "请点击战场上的存活敌人施放" end
    end
    local ok, why = self:CastMagic(self.pendingMagic, enemyIdx)
    if ok then self.pendingMagic = nil end
    return ok, why
end

function Session:CancelPending()
    self.pendingMagic = nil
    return true
end

-- ============================================================================
-- 战斗道具（六轮四·E5：占人物一次行动；AB-038 同构收口）
-- ============================================================================

--- 收集可用消耗品（调用方传入物品来源）。
--- 判据=消耗品物件（cardType=="consumable" 且带 heal/damage/applyEffects 任一）；
--- 只读引用不复制（消耗时从该物件所在列表删除=数量守恒）。
--- 存储列表来源二选一：opts.itemLists（数组的数组，调用方给定）或 opts.game + opts.storageLists(game)。
--- 两者都无=DEMO_ITEMS 深拷贝回退（演示/冒烟）。
---@param opts table|nil
---@return table 数组，元素 { kind, value, aoe, name, icon, uses, id, ref?=实物引用, list?=所在容器 }
function Session.CollectItems(opts)
    local out = {}
    local lists = nil
    if opts then
        if type(opts.itemLists) == "table" then
            lists = opts.itemLists
        elseif opts.game and type(opts.storageLists) == "function" then
            local ok, res = pcall(opts.storageLists, opts.game)
            if ok and type(res) == "table" then lists = res end
        end
    end
    if not lists then
        for _, d in ipairs(Data.DEMO_ITEMS) do
            local it = {}
            for k, v in pairs(d) do it[k] = v end
            out[#out + 1] = it
        end
        return out
    end

    -- 局内背包（{items=..., slots=...} 对象）优先读其 items；调用方也可用 itemLists 直接给列表。
    -- 战斗内道具=随身携带；其余列表作为后备。
    local inv = nil
    if opts and opts.game and type(opts.game.inventory) == "table" then
        inv = opts.game.inventory
    end
    if inv and type(inv.items) == "table" then
        for _, it in ipairs(inv.items or {}) do
            if it and it.cardType == "consumable" and (it.heal or it.damage or it.applyEffects) then
                local uses = it._remainingUses or it.uses or it.maxUses or 1
                if uses > 0 then
                    local entry
                    if (it.heal or 0) > 0 then
                        entry = { kind = "heal", value = it.heal }
                    elseif (it.damage or 0) > 0 then
                        entry = { kind = "damage", value = it.damage, aoe = it.target == "aoe" }
                    else
                        local eff
                        for _, ae in ipairs(it.applyEffects or {}) do
                            if ae.effect == "weaken" then
                                eff = { value = (ae.percent or 0) / 100, aoe = ae.target ~= "enemy" }
                            end
                        end
                        if not eff then eff = { value = 0.25, aoe = true } end
                        entry = { kind = "debuff", value = eff.value, aoe = eff.aoe }
                    end
                    entry.id = it.id
                    entry.name = it.name or it.id
                    entry.icon = it.icon or "🎒"
                    entry.uses = uses
                    entry.ref = it
                    entry.list = inv   -- 标记来源=局内背包（消耗时从 items 删）
                    out[#out + 1] = entry
                end
            end
        end
    end

    for _, list in ipairs(lists) do
        if list ~= inv then   -- 局内背包已处理，跳过
            for _, it in ipairs(list or {}) do
                if it and it.cardType == "consumable" and (it.heal or it.damage or it.applyEffects) then
                    local uses = it._remainingUses or it.uses or it.maxUses or 1
                    if uses > 0 then
                        local entry
                        if (it.heal or 0) > 0 then
                            entry = { kind = "heal", value = it.heal }
                        elseif (it.damage or 0) > 0 then
                            entry = { kind = "damage", value = it.damage, aoe = it.target == "aoe" }
                        else
                            local eff
                            for _, ae in ipairs(it.applyEffects or {}) do
                                if ae.effect == "weaken" then
                                    eff = { value = (ae.percent or 0) / 100, aoe = ae.target ~= "enemy" }
                                end
                            end
                            if not eff then eff = { value = 0.25, aoe = true } end   -- 未知控制效果保守按弱减益
                            entry = { kind = "debuff", value = eff.value, aoe = eff.aoe }
                        end
                        entry.id = it.id
                        entry.name = it.name or it.id
                        entry.icon = it.icon or "🎒"
                        entry.uses = uses
                        entry.ref = it
                        entry.list = list
                        out[#out + 1] = entry
                    end
                end
            end
        end
    end
    return out
end

--- 道具页清单（供 UI 渲染；含已耗尽位显示灰）
---@return table 数组（self.items 引用，UI 只读）
function Session:GetItemList()
    return self.items or {}
end

--- 选择道具（校验+记待投放不占行动；AoE/自身=needsTarget=false 直接可投放，
--- 单体伤害类需点敌人；与 PickMagic 同构，未投放可撤回）
---@param iIdx number
---@return boolean ok, string why, boolean needsTarget
function Session:PickItem(iIdx)
    if self.state ~= "running" then return false, "战斗已结束", false end
    if self.phase ~= "player" then return false, "现在是敌方回合", false end
    if self.playerActed then return false, "本回合人物已行动", false end
    local it = self.items and self.items[iIdx]
    if not it then return false, "无此道具", false end
    if (it.uses or 0) <= 0 then return false, it.name .. " 已用完", false end
    self.pendingMagic = nil
    self.pendingItem = iIdx
    return true, it.name, (it.kind == "damage" and not it.aoe)
end

function Session:CancelPendingItem()
    self.pendingItem = nil
    return true
end

--- 投放待选道具（单体伤害传点击的敌人位）。消耗=uses-1、真实模式从实物容器删除+落库；
--- 收尾与 WaitPlayer/CastMagic 同构（AB-038）：占人物行动+CheckEnd+AutoEnd+焦点回跳。
---@param enemyIdx number|nil
---@return boolean ok, string why
function Session:UsePendingItem(enemyIdx)
    if not self.pendingItem then return false, "未选择道具" end
    local it = self.items[self.pendingItem]
    if not it or (it.uses or 0) <= 0 then
        self.pendingItem = nil
        return false, "道具已不可用"
    end
    if it.kind == "damage" and not it.aoe then
        local e = enemyIdx and self.enemies[enemyIdx]
        if not e or e.hp <= 0 then return false, "请点击战场上的存活敌人投掷" end
    end

    local name = it.name
    Gesture(self)   -- 六轮五：使用道具=挥臂投掷/施展
    if it.kind == "heal" then
        local before = self.player.hp
        self.player.hp = math.min(self.player.maxHp, self.player.hp + ApplyHealCut(self, it.value))
        self:AddFloatText(string.format("+%d", self.player.hp - before), 0.18, 0.5, { 120, 240, 150 }, false)
        self.pulse = { kind = "heal", t0 = self.realTime, dur = 0.7 }
        Log(self, string.format("🩹 道具·%s → 回复 %d HP", name, self.player.hp - before))
    elseif it.kind == "damage" then
        local targets = self:ResolveTargets({ dmg = it.value, aoe = it.aoe }, enemyIdx)
        if #targets == 0 then return false, "没有存活目标" end
        self.pulse = { kind = "magic", t0 = self.realTime, dur = 0.35 }
        self.flashT, self.flashColor = 0.12, { 255, 150, 70 }   -- 爆炸微闪光（复用终结技闪光通道，色偏橙）
        for ti, e in ipairs(targets) do
            local tDelay = (ti - 1) * 0.1
            local dmg = ComputeDamage(it.value, "none", e)
            local blocked = math.min(e.block, dmg)
            e.block = e.block - blocked
            dmg = dmg - blocked
            e.hp = math.max(0, e.hp - dmg)
            e.flashT = 0.15 + tDelay + 0.12
            if e.hp <= 0 then e.deathT = self.realTime + tDelay + 0.12 end
            self:AddFloatText(string.format("-%d", dmg), e.x or 0.5, (e.y or 0.4) - 0.1, { 255, 170, 90 }, false, tDelay + 0.12)
            table.insert(self.shots, {
                from = "player", x = e.x or 0.5, y = e.y or 0.4,
                t0 = self.realTime + tDelay, dur = 0.26, kind = "magic", element = "fire",
            })
            Log(self, string.format("💥 道具·%s → %s -%d", name, e.name, dmg))
            if e.hp <= 0 then Log(self, "☠ " .. e.name .. " 被击杀") end
        end
    else   -- debuff（烟雾）：全体/指定活敌减攻（复用 e.weakenPct 下次攻击一次性生效）
        local targets = self:ResolveTargets({ dmg = 0, aoe = it.aoe }, enemyIdx)
        if #targets == 0 then return false, "没有存活目标" end
        for _, e in ipairs(targets) do
            if e.weakenPct < it.value then e.weakenPct = it.value end
            self:AddFloatText("致盲", e.x or 0.5, (e.y or 0.4) - 0.14, { 170, 175, 190 }, false, 0.05, true)
        end
        Log(self, string.format("💨 道具·%s → 敌方攻击 -%d%%", name, math.floor(it.value * 100 + 0.5)))
    end

    -- 消耗与真实库存（数量守恒：耐久跨场保留——回写实物 _remainingUses/uses，
    -- 出征链续战 CollectItems 重读即剩余值；归零才删实物，防 AB-028 静默回满）
    it.uses = it.uses - 1
    if it.ref then
        it.ref._remainingUses = it.uses
        it.ref.uses = it.uses
    end
    if (it.uses or 0) <= 0 then
        if it.ref and it.list then
            -- ★ V7 E5：局内背包对象（{items,...}）从 items 数组删；数组容器直接删
            local targetList = (type(it.list) == "table" and type(it.list.items) == "table") and it.list.items or it.list
            for li, stored in ipairs(targetList) do
                if stored == it.ref then table.remove(targetList, li) break end
            end
        end
        table.remove(self.items, self.pendingItem)
    end
    if it.ref and self.opts and type(self.opts.onItemConsumed) == "function" then
        pcall(self.opts.onItemConsumed, self.opts, it.ref, it.list)
    end
    NotifySave(self)
    self.pendingItem = nil

    self.playerActed = true
    self:CheckEnd()
    self:AutoEndIfAllActed()
    if self.state == "running" and self.phase == "player" and self.focusIdx == 4 then
        self:AdvanceFocus(4)
    end
    return true, name
end

--- 人物防御（0.5 用户裁定：替代原「跳过回合」）：
--- 本回合承受的**非弱点伤害 -20%**，不提供护盾（与 block 独立叠加，先盾后防）。
--- 与 PlayWeapon/CastMagic 同构的"提交行动"，焦点同样自动跳回未行动单位。
---@return boolean ok, string why
function Session:DefendPlayer()
    if self.state ~= "running" then return false, "战斗已结束" end
    if self.phase ~= "player" then return false, "现在是敌方回合" end
    if self.playerActed then return false, "本回合人物已行动" end
    self.pendingMagic = nil
    self.pendingItem = nil
    self.playerActed = true
    self.player.defending = true
    Log(self, string.format("🛡 人物·防御 → 本回合非弱点伤害 -%d%%（不产生护盾）",
        math.floor(DEFEND_REDUCTION * 100 + 0.5)))
    self:AutoEndIfAllActed()
    if self.state == "running" and self.phase == "player" and self.focusIdx == 4 then
        self:AdvanceFocus(4)
    end
    return true, "防御"
end

--- 兼容别名：旧调用点（UI / 冒烟）语义不变，行为已是防御
function Session:WaitPlayer()
    return self:DefendPlayer()
end

function Session:ResolveTargets(skill, targetIdx)
    local targets = {}
    if skill.aoe then
        for _, e in ipairs(self.enemies) do if e.hp > 0 then table.insert(targets, e) end end
    else
        local tgt = nil
        if targetIdx and self.enemies[targetIdx] and self.enemies[targetIdx].hp > 0 then
            tgt = self.enemies[targetIdx]
        end
        -- 无显式目标时优先用全队指定目标（点击战场敌人设定），仍存活才生效
        if not tgt and self.targetIdx then
            local spec = self.enemies[self.targetIdx]
            if spec and spec.hp > 0 then tgt = spec end
        end
        if not tgt then
            for _, e in ipairs(self.enemies) do if e.hp > 0 then tgt = e break end end
        end
        if tgt then table.insert(targets, tgt) end
    end
    return targets
end

--- 人物魔法（T4：每回合 0~1 次，独立 CD；W1：施法另吃法力=出征预算）
---@param mIdx number 技能池索引
---@param targetIdx number? 仅伤害技需要
function Session:CastMagic(mIdx, targetIdx)
    if self.state ~= "running" then return false, "战斗已结束" end
    if self.phase ~= "player" then return false, "现在是敌方回合" end
    if self.playerActed then return false, "本回合人物已行动" end
    local m = self.magic[mIdx]
    if not m then return false, "无此技能" end
    if m.cd > 0 then return false, string.format("%s 冷却中（%d回合）", m.def.name, m.cd) end
    local sk = m.def
    local cost = sk.mp or 0
    if cost > self.mana then
        return false, string.format("法力不足（%d/%d，需要%d）", self.mana, Data.MANA_MAX, cost)
    end
    self.mana = self.mana - cost
    Gesture(self)   -- 六轮五：施法=挥臂指挥

    if sk.kind == "heal" then
        local before = self.player.hp
        self.player.hp = math.min(self.player.maxHp, self.player.hp + ApplyHealCut(self, sk.value))
        self:AddFloatText(string.format("+%d", self.player.hp - before), 0.18, 0.5, { 120, 240, 150 }, false)
        self.pulse = { kind = "heal", t0 = self.realTime, dur = 0.7 }
        Log(self, string.format("✨ 人物·%s → 回复 %d HP", sk.name, self.player.hp - before))
    elseif sk.kind == "block" then
        local gain = ApplyHealCut(self, sk.value)
        self.player.block = self.player.block + gain
        self:AddFloatText(string.format("+%d 护甲", gain), 0.18, 0.5, { 150, 200, 245 }, false)
        self.pulse = { kind = "block", t0 = self.realTime, dur = 0.7 }
        Log(self, string.format("🛡 人物·%s → 护甲 +%d（下次我方回合开始清零）", sk.name, gain))
    elseif sk.kind == "charge" then
        for _, w in ipairs(self.weapons) do
            if not w.used then w.charge = math.min(ChargeReq(self, w), w.charge + sk.value) end
        end
        self:AddFloatText("全场武器充能+1", 0.18, 0.5, { 255, 220, 120 }, true)
        self.pulse = { kind = "charge", t0 = self.realTime, dur = 0.8 }
        Log(self, "⚡ 人物·" .. sk.name .. " → 未出击武器充能 +" .. sk.value)
    elseif sk.kind == "damage" then
        local targets = self:ResolveTargets({ dmg = sk.value, aoe = sk.aoe }, targetIdx)
        if #targets == 0 then return false, "没有存活目标" end
        self.pulse = { kind = "magic", t0 = self.realTime, dur = 0.35 }
        for ti, e in ipairs(targets) do
            local tDelay = (ti - 1) * 0.12
            local dmg = ComputeDamage(sk.value, sk.element, e)
            local blocked = math.min(e.block, dmg)
            e.block = e.block - blocked
            dmg = dmg - blocked
            e.hp = math.max(0, e.hp - dmg)
            local hitAt = 0.12 + tDelay
            e.flashT = 0.15 + hitAt
            if e.hp <= 0 then e.deathT = self.realTime + hitAt end
            self:AddFloatText(string.format("-%d", dmg), e.x or 0.5, (e.y or 0.4) - 0.1,
                ELEM_COLOR[sk.element] or { 250, 200, 255 }, false, hitAt)
            local mfb = ResistFeedback(sk.element, e)
            if mfb then
                self:AddFloatText(mfb, (e.x or 0.5) + 0.04, (e.y or 0.4) - 0.16,
                    Session.FEEDBACK_COLORS[mfb], false, hitAt, true)
            end
            table.insert(self.shots, {
                from = "player", x = e.x or 0.5, y = e.y or 0.4,
                t0 = self.realTime + tDelay, dur = 0.26, kind = "magic", element = sk.element,
            })
            Log(self, string.format("🔮 人物·%s(%s) → %s -%d", sk.name, Data.ELEMENT_NAMES[sk.element], e.name, dmg))
            if e.hp <= 0 then Log(self, "☠ " .. e.name .. " 被击杀") end
        end
    end

    m.cd = sk.cd + 1   -- +1 因为本回合开始的递减已过，下回合开始 -1 后正好剩 sk.cd 个"等待回合"
    self.playerActed = true
    self:CheckEnd()
    self:AutoEndIfAllActed()
    -- 焦点盘：人物施法后焦点离开书页（跳下一未行动武器/全行动完则 nil 等结束回合）
    if self.state == "running" and self.phase == "player" then
        self.pendingMagic = nil
        self.pendingItem = nil
        if self.focusIdx == 4 then self:AdvanceFocus(4) end
    end
    return true, sk.name
end

--- 是否所有行动体已耗尽（3 武器全出击 + 人物已行动/跳过）→ 自动交出回合
function Session:AllActed()
    for _, w in ipairs(self.weapons) do
        if not w.used then return false end
    end
    return self.playerActed
end

function Session:AutoEndIfAllActed()
    if self.state == "running" and self.phase == "player" and self:AllActed() then
        Log(self, "（所有行动体已出击，自动交出回合）")
        self:EndTurn()
    end
end

function Session:EndTurn()
    if self.state ~= "running" then return false end
    if self.phase ~= "player" then return false, "已经是敌方回合" end
    self.phase = "enemy"
    local left = 0
    for _, w in ipairs(self.weapons) do if not w.used then left = left + 1 end end
    if left > 0 or not self.playerActed then
        Log(self, string.format("—— 我方主动结束（未用出击：%d 武器%s）——", left, self.playerActed and "" or "，人物未行动"))
    end
    self:EnemyPhase()
    return true
end

-- ============================================================================
-- 敌方回合
-- ============================================================================

function Session:EnemyPhase()
    if self.state ~= "running" then return end
    self.banner = { text = "◆ 敌方回合", t0 = self.realTime, color = { 255, 110, 100 } }
    local seq = 0
    for _, e in ipairs(self.enemies) do
        if e.hp > 0 then
            if e.collapsed then
                if e.collapseSkipPending then
                    e.collapseSkipPending = false
                    Log(self, "💫 " .. e.name .. " 崩溃定身，跳过行动")
                end
                e.collapsed = false
                e.stagger = 0
                Log(self, e.name .. " 崩溃结束，混乱清零")
            else
                seq = seq + 1
                self:ExecuteEnemyIntent(e, (seq - 1) * 0.55)
                if self.state ~= "running" then return end
            end
        end
    end
    self:BeginPlayerTurn()
end

--- @param d number 表现错峰延迟（逻辑结算仍即时；仅 lunge/闪红/震屏/飘字按 d 演出）
function Session:ExecuteEnemyIntent(e, d)
    d = d or 0
    local intent = e.intents[e.intentIdx]
    e.intentIdx = math.random(#e.intents)
    if intent.dmg > 0 then
        local dmg = intent.dmg
        if e.weakenPct > 0 then
            dmg = math.floor(dmg * (1 - e.weakenPct) + 0.5)
            e.weakenPct = 0
        end
        -- 0.5 第三波：弱点元素伤害 ×(1+amp)。抵消配件生效（weaknessActive=false）时整段跳过，
        -- 即"弱抗性 → 中抗性"：伤害回归正常，也不再附加 debuff。
        local isWeak = self.player.weaknessActive and self.player.weakness ~= nil
            and intent.element == self.player.weakness
        local weakBonus = 0
        if isWeak and dmg > 0 then
            local amp = (self.player.weaknessData and self.player.weaknessData.amp) or Data.WEAKNESS_AMP
            weakBonus = math.floor(dmg * amp + 0.5)
            dmg = dmg + weakBonus
        end
        -- 0.5 防御行动：本回合非弱点伤害 -20%（弱点属性不受减免；不产生护盾）
        local defendCut = 0
        if self.player.defending and dmg > 0 then
            if not isWeak then
                defendCut = math.floor(dmg * DEFEND_REDUCTION + 0.5)
                dmg = dmg - defendCut
            end
        end
        -- 0.5 易伤：玩家受伤乘区（在防御减伤之后、护盾之前）
        local playerDefMul = self.mods:Query("defMul", "player")
        if playerDefMul ~= 1 and dmg > 0 then
            dmg = math.floor(dmg * playerDefMul + 0.5)
        end
        local blocked = math.min(self.player.block, dmg)
        self.player.block = self.player.block - blocked
        dmg = dmg - blocked
        -- 可选护甲钩子：调用方在扣血前自行做耐久减伤，返回最终伤害与减免量
        local armorReduced = 0
        if dmg > 0 and self.opts and type(self.opts.applyArmor) == "function" then
            local finalDmg, reduced = self.opts.applyArmor(self.opts, dmg, intent.element, intent)
            if type(finalDmg) == "number" then dmg = finalDmg end
            armorReduced = reduced or 0
        end
        self.player.hp = math.max(0, self.player.hp - dmg)
        -- 敌人攻击飘字按意图元素着色（火手雷=橙/酸液=绿）；无属性回退危险红，保留"我受伤"警告语义
        local eCol = (intent.element and intent.element ~= "none")
            and (ELEM_COLOR[intent.element] or { 255, 80, 70 }) or { 255, 80, 70 }
        self:AddFloatText(string.format("-%d", dmg), 0.18, 0.55, eCol, false, d + 0.32)
        if blocked > 0 then
            self:AddFloatText("挡" .. blocked, 0.23, 0.5, { 150, 190, 230 }, false, d + 0.32)
        end
        if armorReduced > 0 then
            self:AddFloatText("甲-" .. armorReduced, 0.13, 0.48, { 180, 210, 160 }, false, d + 0.32)
        end
        if defendCut > 0 then
            self:AddFloatText("防-" .. defendCut, 0.23, 0.44, { 150, 210, 190 }, false, d + 0.32)
        end
        if weakBonus > 0 then
            self:AddFloatText("弱点+" .. weakBonus, 0.23, 0.4, { 255, 120, 90 }, false, d + 0.32)
        end
        -- 0.5 第三波：弱点命中附加 debuff（按元素分化；抵消后不触发）
        if isWeak then ApplyWeaknessDebuff(self, intent.element) end
        -- 演出错峰：突进 → 命中（玩家红闪+震屏+受击被动）
        self:DelayFx(d, function() e.lungeT = 0.35 end)
        self:DelayFx(d + 0.3, function()
            self.player.flashT = 0.2
            if dmg > 0 then self.shakeT, self.shakeMag = 0.25, 4 end
        end)
        if dmg > 0 then
            -- M5：受击（实际掉血）→ 触发 on_hurt 被动（不再是全局规则，谁带谁享有）
            TriggerPassive(self, "on_hurt")
            Log(self, string.format("%s %s → 玩家 -%d%s", e.name, intent.name, dmg,
                blocked > 0 and string.format("（护甲挡%d）", blocked) or ""))
        else
            Log(self, string.format("%s %s → 被护甲完全挡下", e.name, intent.name))
        end
    else
        e.block = e.block + (intent.block or 0)
        self:DelayFx(d + 0.1, function() e.lungeT = 0.2 end)
        self:AddFloatText("+" .. (intent.block or 0) .. " 护甲", e.x or 0.5, (e.y or 0.4) - 0.12, { 150, 200, 245 }, false, d + 0.1)
        Log(self, e.name .. " " .. intent.name .. "（护甲 +" .. (intent.block or 0) .. "）")
    end

    -- 0.5 意图状态效果（中毒/易伤/虚弱）：与命中绑定，不受伤害格挡影响
    if intent.effects then
        for _, ef in ipairs(intent.effects) do
            local name = ef.effect
            local dur = math.max(1, ef.duration or 1)
            if name == "poison" then
                self.player.poisonDmg = (self.player.poisonDmg or 0) + (ef.stacks or 1)
                self.player.poisonTurns = math.max(self.player.poisonTurns or 0, dur)
                self:AddFloatText("中毒" .. (ef.stacks or 1), 0.18, 0.44, { 140, 210, 120 }, false, d + 0.34, true)
                Log(self, string.format("☠ %s 中毒 +%d（%d 回合）", e.name, ef.stacks or 1, dur))
            elseif name == "vulnerable" or name == "magic_vulnerable" then
                local pct = (ef.percent or 20) * (ef.stacks or 1)
                self.mods:Add({
                    scope = "player", stat = "defMul", value = 1 + pct / 100, dur = dur,
                    source = "enemy:debuff",
                })
                Log(self, string.format("💢 %s 易伤 → 玩家受伤 +%d%%（%d 回合）", e.name, pct, dur))
            elseif name == "weaken" then
                local pct = 10 * (ef.stacks or 1)
                self.mods:Add({
                    scope = "weapon", stat = "atkMul", value = 1 - pct / 100, dur = dur,
                    source = "enemy:debuff",
                })
                Log(self, string.format("🌫 %s 虚弱 → 我方武器伤害 -%d%%（%d 回合）", e.name, pct, dur))
            end
        end
    end

    -- 0.5 敌人招牌减益：按定位分配，不是所有怪都有的通用税
    if intent.dmg > 0 then
        -- controller：干扰瞄准（玩家命中 -15%，2 回合），每敌每场最多 2 次
        if e.archetype == "controller" and (e.debuffCount or 0) < 2 and math.random() < 0.35 then
            if math.random() < 0.5 then
                self.mods:Add({
                    scope = "player", stat = "hitAdd", value = -0.15, dur = 2,
                    source = "enemy:" .. tostring(e.id),
                })
                e.debuffCount = (e.debuffCount or 0) + 1
                self:AddFloatText("干扰瞄准", 0.24, 0.42, { 180, 200, 255 }, false, d + 0.34, true)
                Log(self, string.format("🌫 %s 干扰瞄准 → 命中 -15%%（2 回合）", e.name))
            else
                -- 0.5 第二波：充能压制（所有武器终结技需求 +1，封顶 +1）
                self.mods:Add({
                    scope = "weapon", stat = "chargeReqAdd", value = 1, dur = 3,
                    source = "enemy:charge_req",
                })
                e.debuffCount = (e.debuffCount or 0) + 1
                self:AddFloatText("充能压制", 0.24, 0.42, { 255, 210, 120 }, false, d + 0.34, true)
                Log(self, string.format("⚡ %s 充能压制 → 全部武器终结技需求 +1（3 回合）", e.name))
            end
        end
        -- boss：窃取充能（冻结一把武器到下一回合），每 2 回合、每场最多 2 次
        if e.archetype == "boss" and (self._bossFreezeCount or 0) < 2
            and self.turn % 2 == 0 then
            local candidates = {}
            for _, w in ipairs(self.weapons) do
                if self.turn > (w.frozenUntil or 0) then table.insert(candidates, w) end
            end
            if #candidates > 0 then
                local target = candidates[math.random(#candidates)]
                target.frozenUntil = self.turn + 1
                self._bossFreezeCount = (self._bossFreezeCount or 0) + 1
                self:AddFloatText("⚡终结技被冻结", 0.5, 0.28, { 255, 215, 120 }, true, d + 0.3)
                Log(self, string.format("⚡ %s 窃取充能 → %s 下回合无法使用终结技", e.name, target.name))
            end
        end
    end

    self:CheckEnd()
end

function Session:BeginPlayerTurn()
    if self.state ~= "running" then return end
    self.turn = self.turn + 1
    self.phase = "player"
    self.player.block = 0                         -- R3 护甲清零
    self.player.defending = false                 -- 0.5 防御只覆盖刚结束的那个敌方回合
    self.playerActed = false
    self.focusIdx = 1                             -- 六轮：回合切换重置焦点=枪1（崩铁式）
    self.pendingMagic = nil
    self.pendingItem = nil
    for _, w in ipairs(self.weapons) do
        -- T1 行动权重置（充能保留）。备弹制武器：备弹不随回合自动补满，只保留到打空，
        -- 需玩家用「填充备弹」行动回弹（填充占该武器一次行动，见 Session:FillReserve）。
        w.used = false
        w.smgFired = false   -- 新回合：允许（未射过时）填充备弹
    end
    self.mods:TickTurn()                          -- 0.5 修正器时长推进（归零自动移除）
    -- 0.5 第三波：弱点治疗削弱计时（与 mods 独立，因为作用在治疗/护盾乘区）
    if (self.player.healCutTurns or 0) > 0 then
        self.player.healCutTurns = self.player.healCutTurns - 1
        if self.player.healCutTurns <= 0 then
            self.player.healCutTurns = 0
            self.player.healCutPct = 0
        end
    end
    -- G4 空槽=nil，禁 ipairs（会截断），必须显式 1..MAGIC_SLOTS
    for i = 1, Data.MAGIC_SLOTS do
        local m = self.magic[i]
        if m and m.cd > 0 then m.cd = m.cd - 1 end
    end
    local ready = {}
    for i, w in ipairs(self.weapons) do if w.charge >= ChargeReq(self, w) then table.insert(ready, w.name) end end
    self.banner = { text = "▶ 我方回合 " .. self.turn, t0 = self.realTime, color = { 90, 220, 150 } }
    Log(self, string.format("—— 我方回合 %d（3 武器可出击%s）——", self.turn,
        #ready > 0 and "；终结技就绪：" .. table.concat(ready, "、") or ""))

    -- 0.5 中毒 DoT：新回合开始结算（易伤/虚弱走 mods 的 TickTurn，毒是独立计数）
    if (self.player.poisonDmg or 0) > 0 then
        local pd = self.player.poisonDmg
        self.player.hp = math.max(0, self.player.hp - pd)
        self:AddFloatText("-" .. pd .. " 毒伤", 0.18, 0.5, { 140, 210, 120 }, false)
        self.player.poisonTurns = (self.player.poisonTurns or 1) - 1
        Log(self, string.format("☠ 中毒发作 → 玩家 -%d（剩余 %d 回合）", pd, math.max(0, self.player.poisonTurns)))
        if self.player.poisonTurns <= 0 then
            self.player.poisonDmg, self.player.poisonTurns = 0, 0
        end
        self:CheckEnd()
    end
end

function Session:CheckEnd()
    if self.state ~= "running" then return end
    local allDead = true
    for _, e in ipairs(self.enemies) do if e.hp > 0 then allDead = false break end end
    if allDead then
        self.state = "victory"
        self.resultT = 0   -- 胜负揭示计时（Renderer 消费）
        -- G1 链内待入账：本场战利品折算贡献（原型模拟；正式=真实物品价值 V7）
        self.pendingGains = self.pendingGains + Data.CHAIN_CONTRIBUTE
        Log(self, "🏆 胜利！共 " .. self.turn .. " 个回合")
    elseif self.player.hp <= 0 then
        self.state = "defeat"
        self.resultT = 0
        self.shakeT, self.shakeMag = 0.5, 7
        -- G1 狠收益：败北时链内累计的待上缴贡献全没收（随身枪卡损失另由 UI 侧 C6 结算）
        self.lostGains = self.pendingGains
        self.pendingGains = 0
        Log(self, "💀 战败…")
    end
end

--- G4 换装/研习后重建参战法池（军需官即时生效，仿军械库）。
--- 槽位技能未变则保留其 CD，变了则重置为 0（换上新技能视为可用）。
function Session:RebuildMagic()
    local loadout = self.progress:GetLoadout()
    local old = self.magic
    self.magic = {}
    for i = 1, Data.MAGIC_SLOTS do
        local sk = loadout[i]
        if sk then
            local keepCd = 0
            local prev = old[i]
            if prev and prev.def.id == sk.id then keepCd = prev.cd end
            self.magic[i] = { def = sk, cd = keepCd }
        else
            self.magic[i] = nil
        end
    end
end

--- 场上充能总和（冒烟/调试用）
function Session:GetTotalCharge()
    local sum = 0
    for _, w in ipairs(self.weapons) do sum = sum + w.charge end
    return sum
end

-- ============================================================================
-- W4 出征链（原型）：胜利后"继续前进=带残余法力进下一战 / 撤离回营=回满结束"
-- 正式接入时对应真实节点地图与撤离结算；原型用遭遇 1→2→3 线性链演示。
-- ============================================================================

--- 继续前进：返回下一场会话（携带本战残余法力+残余血量+待入账贡献；链尾则 nil）
---@return table? nextSession
function Session:Advance()
    if self.state ~= "victory" then return nil end
    local ei = nil
    for i, enc in ipairs(Data.ENCOUNTERS) do
        if enc == self.encounter then ei = i break end
    end
    if not ei or ei >= #Data.ENCOUNTERS then return nil end
    local pi = 1
    for i, p in ipairs(Data.PRESETS) do if p == self.preset then pi = i break end end
    -- G：养成永久态跨出征保留；编队由调用方通过 nextLoadout 钩子/字段重新提供
    local chainOpts = { hp = self.player.hp, pendingGains = self.pendingGains }
    if self.opts then
        chainOpts.game = self.opts.game
        chainOpts.itemLists = self.opts.itemLists
        chainOpts.storageLists = self.opts.storageLists
        chainOpts.onEquipMod = self.opts.onEquipMod
        chainOpts.onItemConsumed = self.opts.onItemConsumed
        chainOpts.applyArmor = self.opts.applyArmor
        chainOpts.onSave = self.opts.onSave
        chainOpts.loadout = self.opts.nextLoadout
    end
    NotifySave(self)
    return Session.New(ei + 1, pi, self.mana, self.progress, chainOpts)
end

--- 撤离回营（原型：结束出征链，法力回满+待入账贡献上缴入账；正式版走撤离结算+回营恢复）
---@return boolean ok, number gains 本次入账的链内累计贡献
function Session:Evacuate()
    if self.state ~= "victory" then return false end
    self.mana = Data.MANA_MAX
    self.evacuated = true          -- 出征封口：UI 不再弹决策层；重开/换构筑=新出征满血满蓝
    local gains = self.pendingGains
    self.pendingGains = 0
    if gains > 0 then
        self.progress:Contribute(gains)   -- G1：链内累计战利品折算此刻入账
    end
    Log(self, string.format("🏕 撤离回营：法力回满，上缴贡献 +%d 已入账（正式接入=真实撤离结算+据点恢复）", gains))
    return true, gains
end

return Session
