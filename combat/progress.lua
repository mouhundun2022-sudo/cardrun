-- ============================================================================
-- combat/progress.lua - 角色养成永久态（G1-G5）
-- 跨战斗保留（由调用方持久化）：等级/贡献点/成长点/三系加点/技能解锁/选装/研习
--   G1 上缴物资 → 贡献点
--   G2 贡献点升级 → 发成长点；成长点投 体质/法力/研习
--   G3 角色自带技能随等级解锁（learnLevel），升级自动学
--   G4 上场 4 槽选装（免费换装，不额外吃货币）
--   G5 研习=成长点单技能 +1 rank（威力 ×(1+20%/rank)）
-- 有效值（战斗读取）：maxHp / manaMax / 技能 {mp, cd, value}
-- ============================================================================

local Data = require("combat.data")

local Progress = {}
Progress.__index = Progress

--- 建某角色的养成态。characterId 决定技能库来源（V8 6.5 多角色）；nil=默认角色。
function Progress.New(characterId)
    local self = setmetatable({}, Progress)
    self.characterId = characterId or Data.DEFAULT_CHARACTER_ID
    self.level = 1
    self.contribution = 0            -- 军需贡献点（G2 升级货币）
    self.growthPoints = 0            -- 成长点（三系加点货币）
    self.phys = 0                    -- 体质已投点数
    self.mana = 0                    -- 法力已投点数
    self.learned = {}                -- [skillId] = true（等级解锁自动写入）
    self.loadout = {}                -- 上场 4 槽：数组，元素为 skillId（G4）
    self.research = {}               -- [skillId] = rank（G5，0~maxRank）
    self:_UnlockByLevel()
    -- 初始选装：学会的前 MAGIC_SLOTS 个（Lv1 恰好 4 个=全带）
    for _, sk in ipairs(self:Skills()) do
        if #self.loadout < Data.MAGIC_SLOTS and self.learned[sk.id] then
            table.insert(self.loadout, sk.id)
        end
    end
    return self
end

--- 本角色技能库（V8 6.5：读自身 characterId 对应的角色表条目）
---@return table[]
function Progress:Skills()
    local ch = Data.GetCharacter(self.characterId)
    return ch and ch.skills or {}
end

--- 等级达标自动解锁（G3 精灵式：到级即学，不花资源——升级本身就是奖励）
function Progress:_UnlockByLevel()
    for _, sk in ipairs(self:Skills()) do
        if (sk.learnLevel or 1) <= self.level then
            self.learned[sk.id] = true
        end
    end
end

-- ============================================================================
-- G1 上缴
-- ============================================================================

--- 上缴一箱模拟物资（正式=背包真实物品折算，V6）
function Progress:Contribute(amount)
    local gain = amount or Data.CONTRIBUTE_SAMPLE
    self.contribution = self.contribution + gain
    return gain
end

-- ============================================================================
-- G2 升级与加点
-- ============================================================================

function Progress:LevelUpCost()
    if self.level >= Data.LEVELING.maxLevel then return nil end
    return Data.LEVELING.costToLevel(self.level)
end

--- 消耗贡献点升 1 级：发成长点+自动学新技能。返回 (ok, msg)
function Progress:LevelUp()
    local cost = self:LevelUpCost()
    if not cost then return false, "已达最高等级" end
    if self.contribution < cost then
        return false, string.format("贡献点不足（%d/%d）", self.contribution, cost)
    end
    self.contribution = self.contribution - cost
    self.level = self.level + 1
    self.growthPoints = self.growthPoints + Data.LEVELING.growthPerLevel
    local before = 0
    for _ in pairs(self.learned) do before = before + 1 end
    self:_UnlockByLevel()
    local after = 0
    for _ in pairs(self.learned) do after = after + 1 end
    local learned = after - before
    if learned > 0 then
        return true, string.format("升到 Lv%d！+%d 成长点，学会 %d 个新技能", self.level, Data.LEVELING.growthPerLevel, learned)
    end
    return true, string.format("升到 Lv%d！+%d 成长点", self.level, Data.LEVELING.growthPerLevel)
end

--- 成长点投支系（phys / mana）。返回 (ok, msg)
function Progress:Invest(branch)
    local g = Data.GROWTH[branch]
    if not g then return false, "无此支系" end
    local cur = branch == "phys" and self.phys or self.mana
    if cur >= g.max then return false, g.name .. " 已满级" end
    local cost = g.cost(cur)
    if self.growthPoints < cost then
        return false, string.format("成长点不足（%d/%d）", self.growthPoints, cost)
    end
    self.growthPoints = self.growthPoints - cost
    if branch == "phys" then self.phys = cur + 1 else self.mana = cur + 1 end
    return true, string.format("%s +%d（消耗%d成长点）", g.name, 1, cost)
end

-- ============================================================================
-- G4 选装（据点免费换装：无货币/无惩罚，槽数固定 MAGIC_SLOTS）
-- ============================================================================

--- 把已学技能装入槽（替换已装槽位）。返回 (ok, msg)
function Progress:EquipSlot(slotIdx, skillId)
    local sk = Data.GetSkill(skillId)
    if not sk then return false, "无此技能" end
    if not self.learned[skillId] then return false, string.format("%s 尚未学会（Lv%d 解锁）", sk.name, sk.learnLevel or 1) end
    if slotIdx < 1 or slotIdx > Data.MAGIC_SLOTS then return false, "无此槽位" end
    -- 同技能不可双槽：若已装别的槽先清空那个槽
    for i, id in ipairs(self.loadout) do
        if id == skillId and i ~= slotIdx then self.loadout[i] = nil end
    end
    self.loadout[slotIdx] = skillId
    return true, string.format("槽%d ← %s", slotIdx, sk.name)
end

--- 点击槽位循环：空→已学技能1→技能2→…→空（仿军械库交互，原型零弹窗成本）
function Progress:CycleSlot(slotIdx)
    local candidates = {}
    for _, sk in ipairs(self:Skills()) do
        if self.learned[sk.id] then table.insert(candidates, sk.id) end
    end
    table.insert(candidates, nil)   -- 末尾=卸下
    local cur = self.loadout[slotIdx]
    local idx = 1
    for k, id in ipairs(candidates) do
        if (id or "nil") == (cur or "nil") then idx = k break end
    end
    local nextId = candidates[(idx % #candidates) + 1]
    self.loadout[slotIdx] = nextId
    if nextId then
        return string.format("槽%d ← %s", slotIdx, Data.GetSkill(nextId).name)
    end
    return string.format("槽%d 已清空", slotIdx)
end

-- ============================================================================
-- G5 研习：成长点升单技能等级
-- ============================================================================

--- 返回 (ok, msg)
function Progress:ResearchSkill(skillId)
    local sk = Data.GetSkill(skillId)
    if not sk then return false, "无此技能" end
    if not self.learned[skillId] then return false, sk.name .. " 尚未学会" end
    local rank = self.research[skillId] or 0
    if rank >= Data.RESEARCH.maxRank then return false, sk.name .. " 研习已满" end
    local cost = Data.RESEARCH.cost(rank)
    if self.growthPoints < cost then
        return false, string.format("成长点不足（%d/%d）", self.growthPoints, cost)
    end
    self.growthPoints = self.growthPoints - cost
    self.research[skillId] = rank + 1
    return true, string.format("%s 研习 Lv%d→Lv%d", sk.name, rank + 1, rank + 2)
end

-- ============================================================================
-- 有效值（战斗读取）
-- ============================================================================

function Progress:GetMaxHp()
    return Data.PLAYER_HP + self.phys * Data.GROWTH.phys.hpPerPoint
end

function Progress:GetManaMax()
    return Data.MANA_MAX + self.mana * Data.GROWTH.mana.manaPerPoint
end

--- 法力支系每 2 点：全技能蓝耗 -1（下限 1，保持"高贵"底线）
function Progress:GetMpCost(skillId)
    local sk = Data.GetSkill(skillId)
    local base = (sk and sk.mp) or 0
    local reduce = math.floor(self.mana / 2)
    return math.max(1, base - reduce)
end

--- 研习后的有效技能（战斗施法与 UI 按钮统一读取）：rank 每级威力 +20%
---@return table { id,name,kind,value,cd,mp,element,aoe,rank }
function Progress:GetEffectiveSkill(skillId)
    local sk = Data.GetSkill(skillId)
    local rank = self.research[skillId] or 0
    local eff = {
        id = sk.id, name = sk.name, kind = sk.kind, cd = sk.cd,
        mp = self:GetMpCost(skillId), element = sk.element, aoe = sk.aoe, rank = rank,
    }
    eff.value = math.floor((sk.value or 0) * (1 + rank * Data.RESEARCH.valuePerRank) + 0.5)
    return eff
end

--- 上场槽位的有效技能列表（含空槽=nil，UI/Session 按位读）
function Progress:GetLoadout()
    local list = {}
    for i = 1, Data.MAGIC_SLOTS do
        local id = self.loadout[i]
        list[i] = id and self:GetEffectiveSkill(id) or nil
    end
    return list
end

--- 从持久化裸表恢复实例（★ 崩溃根因修复：JSON 序列化会丢掉元表，
--- 读回的 Progress 是无元表的纯表，直接调 progress:GetMaxHp() 会
--- attempt to call a nil value。此处重挂元表恢复全部方法，并补齐缺失子表/数值兜底半残档。）
--- 幂等：传入已是实例（getmetatable==Progress）则原样返回。
---@param raw table|nil
---@return table Progress 实例（复用 raw 引用，保持调用方持有的引用一致）
function Progress.Wrap(raw)
    if raw and getmetatable(raw) == Progress then return raw end
    local self = setmetatable(raw or {}, Progress)
    -- 数值字段兜底（防 JSON 丢字段后 nil 参与运算）
    self.level        = self.level or 1
    self.contribution = self.contribution or 0
    self.growthPoints = self.growthPoints or 0
    self.phys         = self.phys or 0
    self.mana         = self.mana or 0
    -- 子表兜底（防半残档/新格式字段缺失）
    self.learned  = self.learned or {}
    self.loadout  = self.loadout or {}
    self.research = self.research or {}
    return self
end

return Progress
