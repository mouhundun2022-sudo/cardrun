-- ============================================================================
-- combat/modifiers.lua - 状态修正器统一框架
--
-- 设计判断：降命中 / 降防御 / 降护盾获取 / 偷充能 / 额外一段伤害，
-- 本质是**同一个东西——乘区修正器**，只是作用在不同属性上。
-- 因此不逐条加字段，而是统一为 { scope, stat, op, value, dur } 一条记录。
--
-- 属性集合是**封闭的**（见 STAT_DEFS）：新增效果只能从这 9 项组合，不允许加专用字段。
--
-- 配件 = dur = nil（整场）的修正器集合，source = "mod:<id>"。
-- 所以配件系统不需要新框架，只需把 modifiers 注入本表。
--
-- 纯逻辑模块，无引擎运行时依赖，可 headless 冒烟直接断言。
-- ============================================================================

local Modifiers = {}

-- 诊断输出开关：默认静默，宿主调试时设为 true 可见被拒绝的修正器原因。
Modifiers.VERBOSE = false

-- ============================================================================
-- §1 属性定义（封闭集合）
--   agg  = 聚合方式：mul 连乘 / add 求和 / count 计数
--   min/max = 聚合结果封顶（防滚雪球）
--   label = UI 显示用
--   icon  = 图标标识（Renderer/UI 据此取图）
-- ============================================================================

---@type table<string, { agg: string, min: number, max: number, label: string, icon: string }>
Modifiers.STAT_DEFS = {
    -- 输出
    atkMul       = { agg = "mul",   min = 0.10, max = 3.00, label = "攻击",     icon = "atk" },
    dmgAdd       = { agg = "add",   min = -999, max = 999,  label = "固伤",     icon = "dmg" },
    extraHit     = { agg = "count", min = 0,    max = 1,    label = "追加攻击", icon = "extra" },
    -- 防御
    defMul       = { agg = "mul",   min = 0.50, max = 1.50, label = "防御",     icon = "def" },
    blockGainMul = { agg = "mul",   min = 0.00, max = 3.00, label = "护盾获取", icon = "block" },
    -- 命中
    hitAdd       = { agg = "add",   min = -0.25, max = 0.25, label = "命中",    icon = "hit" },
    evadeAdd     = { agg = "add",   min = -0.25, max = 0.40, label = "闪避",    icon = "evade" },
    -- 节奏
    chargeDelta  = { agg = "add",   min = -9,   max = 9,    label = "充能",     icon = "charge" },
    -- 0.5 第二波：终结技所需充能（配件 -1 / 敌人压制 +1；总量封顶 +1，见用户裁定）
    chargeReqAdd = { agg = "add",   min = -2,   max = 1,    label = "充能需求", icon = "charge" },
    -- 混乱
    staggerMul   = { agg = "mul",   min = 0.10, max = 3.00, label = "混乱累积", icon = "stagger" },
}

--- 属性中性值（无任何修正器时的返回值）
Modifiers.NEUTRAL = { mul = 1.0, add = 0, count = 0 }

--- 允许的作用域
Modifiers.SCOPES = { player = true, enemy = true, weapon = true, allWeapons = true }

--- 一次性修正器（dur = 0）的语义标记：消费后消失
Modifiers.DUR_ONE_SHOT = 0
--- 整场修正器（dur = nil / "battle"）
Modifiers.DUR_BATTLE = nil

-- ============================================================================
-- §2 数据结构
-- ============================================================================

---@class Modifier
---@field id integer
---@field scope string
---@field target any
---@field stat string
---@field value number
---@field dur number?
---@field stacks integer
---@field source string

---@class ModifierSet
---@field list Modifier[]
---@field _seq integer
local Set = {}
Set.__index = Set

--- 新建修正器集合
---@return ModifierSet
function Modifiers.New()
    local self = setmetatable({}, Set)
    self:init()
    return self
end

--- 字段在 init 里初始化（而非只在工厂函数里赋值），保证 LSP 能推导成员类型
function Set:init()
    ---@type Modifier[]
    self.list = {}
    self._seq = 0
end

-- ============================================================================
-- §3 匹配与聚合
-- ============================================================================

--- target 为 nil 表示"不限对象"（全局生效）
---@param m Modifier
---@param scope string?
---@param target any
---@return boolean
local function Matches(m, scope, target)
    if scope ~= nil and m.scope ~= scope then return false end
    if target ~= nil and m.target ~= nil and m.target ~= target then return false end
    return true
end

--- 字段合法性校验
---@param mod table
---@return boolean ok
---@return string? reason
function Modifiers.Validate(mod)
    if type(mod) ~= "table" then return false, "modifier 必须是 table" end
    if not Modifiers.STAT_DEFS[mod.stat] then
        return false, "未知属性: " .. tostring(mod.stat)
    end
    if not Modifiers.SCOPES[mod.scope or "enemy"] then
        return false, "未知作用域: " .. tostring(mod.scope)
    end
    if type(mod.value) ~= "number" then
        return false, "value 必须是数字: " .. tostring(mod.value)
    end
    return true
end

-- ============================================================================
-- §4 增删与查询
-- ============================================================================

--- 施加修正器。
--- 同一 (scope, target, stat, source) 已存在时**刷新时长与数值**，不新增条目——
--- 防止"每回合重复施加"无限叠层；不同 source 各自保留，正常叠加。
---@param mod table { scope?, target?, stat, value, dur?, stacks?, source? }
---@return Modifier|nil
function Set:Add(mod)
    local ok, reason = Modifiers.Validate(mod)
    if not ok then
        if Modifiers.VERBOSE then print("[combat][Modifiers] 拒绝无效修正器: " .. tostring(reason)) end
        return nil
    end
    local scope = mod.scope or "enemy"
    local source = mod.source or "unknown"

    for _, m in ipairs(self.list) do
        if m.scope == scope and m.target == mod.target and m.stat == mod.stat and m.source == source then
            m.value = mod.value
            m.stacks = mod.stacks or 1
            if mod.dur ~= nil then m.dur = mod.dur end
            return m
        end
    end

    self._seq = self._seq + 1
    ---@type Modifier
    local entry = {
        id = self._seq,
        scope = scope,
        target = mod.target,
        stat = mod.stat,
        value = mod.value,
        dur = mod.dur,
        stacks = mod.stacks or 1,
        source = source,
    }
    table.insert(self.list, entry)
    return entry
end

--- 查询聚合值（已应用封顶）。无匹配时返回中性值（mul=1 / add=0 / count=0）。
---@param stat string
---@param scope string?
---@param target any
---@return number
function Set:Query(stat, scope, target)
    local def = Modifiers.STAT_DEFS[stat]
    if not def then return 0 end

    local acc = Modifiers.NEUTRAL[def.agg] or 0
    for _, m in ipairs(self.list) do
        if m.stat == stat and Matches(m, scope, target) then
            if def.agg == "mul" then
                acc = acc * (m.value ^ m.stacks)
            elseif def.agg == "add" then
                acc = acc + m.value * m.stacks
            else
                acc = acc + 1
            end
        end
    end
    return math.max(def.min, math.min(def.max, acc))
end

--- 是否存在指定属性的生效修正器
---@param stat string
---@param scope string?
---@param target any
---@return boolean
function Set:Has(stat, scope, target)
    for _, m in ipairs(self.list) do
        if m.stat == stat and Matches(m, scope, target) then return true end
    end
    return false
end

--- 消费一次性修正器（dur = 0 的条目），用于"下次攻击额外一段"这类效果。
---@param stat string
---@param scope string?
---@param target any
---@return integer removed 移除数量
function Set:Consume(stat, scope, target)
    local removed = 0
    for i = #self.list, 1, -1 do
        local m = self.list[i]
        if m.stat == stat and m.dur == Modifiers.DUR_ONE_SHOT and Matches(m, scope, target) then
            table.remove(self.list, i)
            removed = removed + 1
        end
    end
    return removed
end

--- 回合结束推进：有限时长 -1，归零移除；一次性（dur=0）与整场（dur=nil）不动。
function Set:TickTurn()
    local i = 1
    while i <= #self.list do
        local m = self.list[i]
        if m.dur ~= nil and m.dur > 0 then
            m.dur = m.dur - 1
            if m.dur <= 0 then
                table.remove(self.list, i)
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

--- 清空
function Set:Clear()
    self.list = {}
end

--- 按来源前缀移除（0.5：配件重装时先清旧配件修正器，再重新注入）
---@param prefix string
---@return integer removed
function Set:RemoveBySource(prefix)
    local removed = 0
    local plen = #prefix
    for i = #self.list, 1, -1 do
        local src = self.list[i].source or ""
        if #src >= plen and src:sub(1, plen) == prefix then
            table.remove(self.list, i)
            removed = removed + 1
        end
    end
    return removed
end

--- 活跃条目快照（供 UI / 调试遍历，返回浅拷贝）
---@return Modifier[]
function Set:List()
    local out = {}
    for _, m in ipairs(self.list) do table.insert(out, m) end
    return out
end

-- ============================================================================
-- §5 显示辅助
-- ============================================================================

--- 时长文案
---@param m Modifier
---@return string
function Modifiers.FormatDuration(m)
    if m.dur == nil then return "整场" end
    if m.dur == 0 then return "下次" end
    return tostring(m.dur) .. "回合"
end

--- 单条修正器的展示文本，如"命中 -15%（2回合）"
---@param m Modifier
---@return string
function Modifiers.Describe(m)
    local def = Modifiers.STAT_DEFS[m.stat]
    if not def then return tostring(m.stat) end

    local sign, text
    if def.agg == "mul" then
        local pct = math.floor((m.value - 1) * 100 + 0.5)
        sign = pct >= 0 and "+" or ""
        text = sign .. pct .. "%"
    elseif def.agg == "count" then
        text = "追加 " .. tostring(m.stacks) .. " 次"
    else
        local v = m.value * m.stacks
        if m.stat == "hitAdd" or m.stat == "evadeAdd" then
            local pct = math.floor(v * 100 + 0.5)
            sign = pct >= 0 and "+" or ""
            text = sign .. pct .. "%"
        else
            sign = v >= 0 and "+" or ""
            text = sign .. tostring(v)
        end
    end
    return string.format("%s %s（%s）", def.label, text, Modifiers.FormatDuration(m))
end

return Modifiers
