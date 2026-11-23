-- ============================================================================
-- EnemyFormula.lua - 标尺 + 怪物数值公式
--
-- 核心原则：等级只是标签，TTK（击杀回合数）才是唯一自变量；所有怪物数值从标尺反推。
--
-- 本模块是**纯数据 + 纯函数**，无引擎运行时依赖：
--   · 可在 headless 冒烟里直接 require 并断言（不需要 Scene/graphics）
--   · 所有可调参数集中在文件顶部，改一个数全局生效
--
-- 结构：
--   §1 标尺常量（D_REF / TTK / 攻击预算）
--   §2 定位表（archetype 系数）
--   §3 血量 / 攻击 / 混乱阈值 / 先手
--   §4 六抗归一化与预算校验
--   §5 命中率
--   §6 威胁值 TV 与遭遇预算
-- ============================================================================

local EnemyFormula = {}

EnemyFormula.VERSION = "0.5-wave1"

-- ============================================================================
-- §1 标尺（唯一自变量）
-- ============================================================================

--- 玩家 3 把武器、裸装、单目标、每回合期望输出（已含命中期望）
EnemyFormula.D_REF = 34
--- 武器面板单回合总伤害（未含命中），D_REF = D_REF_RAW × HIT_RATE_AVG
EnemyFormula.D_REF_RAW = 37
--- 武器平均命中率（6 把基础命中的均值，取整留白给配件）
EnemyFormula.HIT_RATE_AVG = 0.915
--- 玩家 Lv1 基准血量
EnemyFormula.P_MAXHP_REF = 130
--- 敌方每回合总输出预算（整场）
EnemyFormula.ATK_BUDGET_TURN = 24
--- 玩家期望控场减伤率（防御/护盾/治疗带来的缓和），用于反推攻击预算
EnemyFormula.CONTROL_MITIGATION = 0.25

--- 单只怪的目标击杀回合数（3 把集火）
EnemyFormula.TTK = {
    normal = 2.0,
    elite  = 4.0,
    boss   = 7.0,
}

--- 目标击溃回合数（普通 2.5 / 精英 3.3 / 首领 5 / 召唤物 1.35）
--- 取值使 maxStagger 精确复现现行 22 / 30 / 45 / 12（保持手感零漂移）
EnemyFormula.TTK_COLLAPSE = {
    normal = 2.45,
    elite  = 3.35,
    boss   = 5.0,
    minion = 1.35,
}

--- 每回合期望命中次数（3 把武器各出击 1 次）
EnemyFormula.HITS_PER_TURN = 3
--- 单次命中的平均混乱累积
EnemyFormula.STAGGER_PER_HIT = 3

-- ============================================================================
-- §2 定位表（archetype）
-- ============================================================================

--- 定位系数：
---   k_hp   血量系数（相对 HP_base）
---   k_atk  攻击系数（相对单只基准）
---   evade  闪避率（与 HP 互斥的防御资源）
---   k_init 先手权重
---@type table<string, table>
EnemyFormula.ARCHETYPES = {
    swarm      = { name = "兽群", k_hp = 0.45, k_atk = 0.75, evade = 0.10, k_init = 0.30 },
    bruiser    = { name = "斗士", k_hp = 1.00, k_atk = 1.10, evade = 0.05, k_init = 0.50 },
    tank       = { name = "重装", k_hp = 1.25, k_atk = 0.75, evade = 0.00, k_init = 0.20 },
    striker    = { name = "突袭", k_hp = 0.90, k_atk = 1.30, evade = 0.30, k_init = 0.90 },
    controller = { name = "控制", k_hp = 0.95, k_atk = 0.85, evade = 0.08, k_init = 0.40 },
    boss       = { name = "首领", k_hp = 1.00, k_atk = 1.30, evade = 0.12, k_init = 0.60 },
}

--- 未知 / 缺省定位回退到斗士（中间档，不会造成极端数值）
EnemyFormula.DEFAULT_ARCHETYPE = "bruiser"

--- 取定位定义
---@param archetypeId string?
---@return table
function EnemyFormula.GetArchetype(archetypeId)
    return EnemyFormula.ARCHETYPES[archetypeId or EnemyFormula.DEFAULT_ARCHETYPE]
        or EnemyFormula.ARCHETYPES[EnemyFormula.DEFAULT_ARCHETYPE]
end

-- ============================================================================
-- §3 血量 / 攻击 / 混乱 / 先手
-- ============================================================================

local function Round(x)
    return math.floor(x + 0.5)
end
EnemyFormula.Round = Round

--- 档位基础血量（未乘定位系数）
---@param grade string?
---@return number
function EnemyFormula.GetHpBase(grade)
    local ttk = EnemyFormula.TTK[grade or "normal"] or EnemyFormula.TTK.normal
    return ttk * EnemyFormula.D_REF
end

--- 怪物血量 = HP_base × k_hp
---@param grade string?
---@param archetypeId string?
---@return integer
function EnemyFormula.GetHp(grade, archetypeId)
    local a = EnemyFormula.GetArchetype(archetypeId)
    return Round(EnemyFormula.GetHpBase(grade) * a.k_hp)
end

--- 单只攻击基准（未按同场数量分摊）
---@param archetypeId string?
---@return number
function EnemyFormula.GetAttackRef(archetypeId)
    local a = EnemyFormula.GetArchetype(archetypeId)
    return EnemyFormula.ATK_BUDGET_TURN * a.k_atk
end

--- 单只攻击 = 每回合总预算 / 同场数量 × k_atk
---@param archetypeId string?
---@param count integer? 同场敌人数（默认 1）
---@return integer
function EnemyFormula.GetAttack(archetypeId, count)
    local n = math.max(1, count or 1)
    local a = EnemyFormula.GetArchetype(archetypeId)
    return Round(EnemyFormula.ATK_BUDGET_TURN / n * a.k_atk)
end

--- 混乱阈值 = 击溃回合 × 每回合命中 × 单次混乱
--- 复现现行 22 / 30 / 45 / 12
---@param grade string?
---@return integer
function EnemyFormula.GetStaggerThreshold(grade)
    local t = EnemyFormula.TTK_COLLAPSE[grade or "normal"] or EnemyFormula.TTK_COLLAPSE.normal
    return Round(t * EnemyFormula.HITS_PER_TURN * EnemyFormula.STAGGER_PER_HIT)
end

--- 闪避率（按定位；未知定位为 0，保证旧数据零行为变化）
---@param archetypeId string?
---@return number
function EnemyFormula.GetEvade(archetypeId)
    local def = archetypeId and EnemyFormula.ARCHETYPES[archetypeId]
    if not def then return 0 end
    return def.evade
end

--- 先手权重（敌方行动排序，降序）
---@param archetypeId string?
---@param attack number 该只攻击
---@param maxAttack number 本场最高攻击
---@return number
function EnemyFormula.GetInitiative(archetypeId, attack, maxAttack)
    local a = EnemyFormula.GetArchetype(archetypeId)
    local ratio = 0
    if maxAttack and maxAttack > 0 then
        ratio = math.min(1, math.max(0, (attack or 0) / maxAttack))
    end
    return a.k_init + ratio * 0.5
end

-- ============================================================================
-- §4 六抗：归一化 + 预算校验
-- ============================================================================

--- 参与预算的五属性（none 是通用兜底，永远 0）
EnemyFormula.RESIST_KEYS = { "fire", "ice", "electric", "light", "nature" }

EnemyFormula.RESIST_MAX = 65      -- 抗性硬上限（用户裁定）
EnemyFormula.RESIST_MIN = -100    -- 弱点不设实际下限，理论最大 -100
EnemyFormula.RESIST_BUDGET = 10   -- Σ 五项抗性绝对值收敛区间 ±10
EnemyFormula.WEAK_THRESHOLD = -15 -- 低于此值才算"弱点"
EnemyFormula.STRONG_THRESHOLD = 15
EnemyFormula.WEAK_MIN = -35       -- 弱点推荐区间
EnemyFormula.WEAK_MAX = -20

--- 归一化六抗：五属性夹到 [-100, 65]，none 强制 0
---@param resist6 table|nil { none, fire, ice, electric, light, nature }
---@return table
function EnemyFormula.NormalizeResist(resist6)
    local src = resist6 or {}
    local out = { none = 0 }
    for _, k in ipairs(EnemyFormula.RESIST_KEYS) do
        local v = tonumber(src[k]) or 0
        out[k] = math.max(EnemyFormula.RESIST_MIN, math.min(EnemyFormula.RESIST_MAX, v))
    end
    return out
end

--- 抗性预算校验（生成期/配表期使用，不参与战斗结算）
---@param resist6 table|nil
---@return boolean ok
---@return string[] reasons 不通过的原因（ok=true 时为空表）
function EnemyFormula.ValidateResist(resist6)
    local r = EnemyFormula.NormalizeResist(resist6)
    local reasons = {}
    local sum = 0
    local hasWeak, hasStrong = false, false
    for _, k in ipairs(EnemyFormula.RESIST_KEYS) do
        local v = r[k]
        sum = sum + v
        if v <= EnemyFormula.WEAK_THRESHOLD then hasWeak = true end
        if v >= EnemyFormula.STRONG_THRESHOLD then hasStrong = true end
        if v > EnemyFormula.RESIST_MAX then
            table.insert(reasons, string.format("%s 抗性 %d 超过上限 %d", k, v, EnemyFormula.RESIST_MAX))
        end
    end
    if not hasWeak then
        table.insert(reasons, "缺少弱点（至少一个属性 <= " .. EnemyFormula.WEAK_THRESHOLD .. "）")
    end
    if not hasStrong then
        table.insert(reasons, "缺少抗性（至少一个属性 >= " .. EnemyFormula.STRONG_THRESHOLD .. "）")
    end
    if math.abs(sum) > EnemyFormula.RESIST_BUDGET then
        table.insert(reasons, string.format("抗性总和 %d 超出预算 ±%d", sum, EnemyFormula.RESIST_BUDGET))
    end
    return #reasons == 0, reasons
end

--- 该抗性表最吃亏的属性（弱点方向），用于"带对属性"提示
---@param resist6 table|nil
---@return string element
---@return number value
function EnemyFormula.GetWeakestElement(resist6)
    local r = EnemyFormula.NormalizeResist(resist6)
    local bestKey, bestVal = "none", 100
    for _, k in ipairs(EnemyFormula.RESIST_KEYS) do
        if r[k] < bestVal then bestKey, bestVal = k, r[k] end
    end
    return bestKey, bestVal
end

-- ============================================================================
-- §5 命中率
-- ============================================================================

EnemyFormula.HIT_MIN = 0.35
EnemyFormula.HIT_MAX = 1.00
EnemyFormula.HIT_COLLAPSED_BONUS = 0.20   -- 目标崩溃：+20%
EnemyFormula.HIT_AOE_BONUS = 0.10         -- AOE 出击：+10%
EnemyFormula.PITY_THRESHOLD = 2           -- 连续未命中 N 次后必中
EnemyFormula.PLAYER_BASE_HIT = 0.90       -- 敌方基础命中（对玩家）
EnemyFormula.PLAYER_BASE_EVADE = 0.05     -- 玩家基础闪避

--- 武器基础命中（6 把，按类别差异化）
---@type table<string, number>
EnemyFormula.WEAPON_BASE_HIT = {
    rifle    = 0.95,  -- 突击步枪
    emp      = 0.93,  -- 电磁步枪
    cryo     = 0.92,  -- 冷冻冲锋枪
    flare    = 0.90,  -- 照明支援铳
    toxic    = 0.88,  -- 腐蚀撒布器
    burner   = 0.85,  -- 燃烧霰弹枪
}

--- 计算单次出击命中率
---@param opts table { baseHit, modHit, collapsed, aoe, targetEvade }
---@return number 0.35 ~ 1.00
function EnemyFormula.GetHitChance(opts)
    local o = opts or {}
    local hit = (o.baseHit or EnemyFormula.PLAYER_BASE_HIT)
        + (o.modHit or 0)
        - (o.targetEvade or 0)
    if o.collapsed then hit = hit + EnemyFormula.HIT_COLLAPSED_BONUS end
    if o.aoe then hit = hit + EnemyFormula.HIT_AOE_BONUS end
    return math.max(EnemyFormula.HIT_MIN, math.min(EnemyFormula.HIT_MAX, hit))
end

--- 获取武器基础命中（未注册武器回退到平均命中）
---@param weaponId string?
---@return number
function EnemyFormula.GetWeaponBaseHit(weaponId)
    return EnemyFormula.WEAPON_BASE_HIT[weaponId or ""] or EnemyFormula.HIT_RATE_AVG
end

--- 保底判定：连续未命中次数达到阈值后必中
---@param missStreak integer 该武器当前连续未命中次数
---@return boolean forcedHit
function EnemyFormula.ShouldPityHit(missStreak)
    return (missStreak or 0) >= EnemyFormula.PITY_THRESHOLD
end

-- ============================================================================
-- §6 威胁值 TV 与遭遇预算
-- ============================================================================

--- 各档遭遇的威胁值预算
---@type table<string, number>
EnemyFormula.TV_BUDGET = {
    normal = 3.2,
    elite  = 4.5,
    boss   = 6.0,
}

--- TV 权重
EnemyFormula.TV_W = { hp = 1.0, atk = 1.0, resist = 0.8, utility = 0.6 }
EnemyFormula.TV_RESIST_NORM = 60
EnemyFormula.TV_TOLERANCE = 0.05   -- 允许超出预算 5%

--- 标准怪基准（TV = 1.0 的参照物）：
--- normal 档斗士，带一组典型抗性（1 弱点 + 1 抗性），无控制/续航
EnemyFormula.STANDARD = {
    grade = "normal",
    archetype = "bruiser",
    resist6 = { fire = -25, ice = 20, electric = 0, light = 0, nature = 0 },
    utility = 0,
}

--- 原始威胁值（未归一化）
---@param mon table { grade, archetype, hp, attack, resist6, utility }
---@return number
local function RawTV(mon)
    local grade = (mon.grade or "normal")
    local arch = mon.archetype
    local hpN = (mon.hp or 0) / EnemyFormula.GetHpBase(grade)
    local atkRef = EnemyFormula.GetAttackRef(arch)
    local atkN = atkRef > 0 and ((mon.attack or 0) / atkRef) or 0

    local resistAbs = 0
    local r = EnemyFormula.NormalizeResist(mon.resist6)
    for _, k in ipairs(EnemyFormula.RESIST_KEYS) do
        resistAbs = resistAbs + math.abs(r[k])
    end
    local resistN = resistAbs / EnemyFormula.TV_RESIST_NORM
    local utilityN = math.max(0, math.min(1, mon.utility or 0))

    local w = EnemyFormula.TV_W
    return w.hp * hpN + w.atk * atkN + w.resist * resistN + w.utility * utilityN
end

--- 标准怪原始 TV（模块加载时算一次，作为归一化除数）
EnemyFormula.TV_UNIT = (function()
    local s = EnemyFormula.STANDARD
    return RawTV({
        grade = s.grade,
        archetype = s.archetype,
        hp = EnemyFormula.GetHp(s.grade, s.archetype),
        attack = EnemyFormula.GetAttackRef(s.archetype),
        resist6 = s.resist6,
        utility = 0,
    })
end)()

--- 计算单只怪的威胁值（归一化：标准怪 = 1.0，预算即"几只标准怪"）
---@param mon table { grade, archetype, hp, attack, resist6, utility }
---@return number
function EnemyFormula.ComputeTV(mon)
    local unit = EnemyFormula.TV_UNIT
    if not unit or unit <= 0 then return 0 end
    return RawTV(mon) / unit
end

--- 遭遇预算校验
---@param monsters table[] 每项 { grade, archetype, hp, attack, resist6, utility }
---@param tier string? "normal" | "elite" | "boss"
---@return number totalTV
---@return number budget
---@return boolean ok
function EnemyFormula.CheckEncounterBudget(monsters, tier)
    local total = 0
    for _, m in ipairs(monsters or {}) do
        total = total + EnemyFormula.ComputeTV(m)
    end
    local budget = EnemyFormula.TV_BUDGET[tier or "normal"] or EnemyFormula.TV_BUDGET.normal
    return total, budget, total <= budget * (1 + EnemyFormula.TV_TOLERANCE)
end

--- 敌方行动顺序（降序先手权重）
---@param monsters table[] 每项需含 archetype / attack
---@return table[] 排序后的浅拷贝
function EnemyFormula.SortByInitiative(monsters)
    local out = {}
    for i, m in ipairs(monsters or {}) do out[i] = m end
    local maxAtk = 0
    for _, m in ipairs(out) do
        if (m.attack or 0) > maxAtk then maxAtk = m.attack or 0 end
    end
    table.sort(out, function(a, b)
        local ia = EnemyFormula.GetInitiative(a.archetype, a.attack, maxAtk)
        local ib = EnemyFormula.GetInitiative(b.archetype, b.attack, maxAtk)
        return ia > ib
    end)
    return out
end

return EnemyFormula
