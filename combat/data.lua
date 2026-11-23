-- ============================================================================
-- combat/data.lua - 武器行动制战斗数据（武器 / 敌人 / 改装卡 / 角色技能 / 遭遇）
-- 基底：武器=上场单位（普攻/战技/终结技，每回合各出击1次）；人物=操作者（魔法技能池+独立CD）
-- 改装体系：
--   C1 固定 4 槽：barrel 枪管 / grip 握把 / muzzle 枪口 / module 模块，每槽一张；
--   C2 卡按武器类别绑定：cats 白名单决定谁能装（步枪系/霰弹系/发射器系/支援系/冲锋枪系）；
--   C3 功能×属性双轴不相乘：cats=适配轴（决定谁能装），element=效果词缀（只加附加效果）；
--   C4 附加效果不改主伤害：主伤害永远按武器自带属性算，卡元素只做燃烧/减攻/额外混乱词缀。
-- 弹药系统整体作废：无口径/弹级/弹匣/换弹。六属性=武器自带属性。
-- 纯数据表，零引擎依赖。需要元素图标时由调用方覆盖 Data.ELEMENT_ICONS。
-- ============================================================================

local Data = {}

-- 回合制模型（T1/T2/T7 定案 + M5 被动框架）
Data.CHARGE_MAX = 3            -- 每武器终结技充能上限（默认值；各武器可覆写 chargeMax）
Data.CHARGE_MAX_DOTS = 6       -- 充能点槽位数上限（UI 固定画槽，按有效需求显示/隐藏）
Data.CHARGE_ON_NORMAL = 1      -- 本武器普攻充能
Data.WEAPONS_PER_TEAM = 3      -- T1 上场武器数
Data.COLLAPSE_DMG_MULT = 1.5   -- T7 崩溃期间受伤倍率

-- M5 统一被动框架：把"世界法则"降级为"可收集特性"——武器和人物共用一张触发表。
-- 受击充能不再全局生效：谁带被动谁享有，"为反打感带哪把枪/哪个角色"成为构筑决策。
-- trigger: on_hurt(人物实际掉血) | on_collapse(任意敌进入崩溃) | on_normal | on_ult(预留)
-- effect:  chargeSelf=仅该武器+n | chargeAll=全场武器+n
Data.PASSIVES = {
    flare_spot   = { name = "警戒反打", desc = "人物掉血→本枪充能+1", trigger = "on_hurt",     chargeSelf = 1 },
    command_beat = { name = "崩溃号令", desc = "任意敌崩溃→全场充能+1", trigger = "on_collapse", chargeAll = 1 },
}
Data.GetPassive = function(id) return id and Data.PASSIVES[id] or nil end

-- 六属性（T3：武器自带属性，一把武器 3 技能同属性；C3：改装卡元素=效果词缀）
Data.ELEMENTS = { "none", "fire", "ice", "electric", "light", "nature" }
Data.ELEMENT_NAMES = {
    none = "无", fire = "火", ice = "冰", electric = "电", light = "光", nature = "草",
}
-- 六元素主色（UI/Renderer/Session 三方共用；图标见 ELEMENT_ICONS，色=双通道的颜色通道）
Data.ELEMENT_COLORS = {
    none = { 200, 205, 215 }, fire = { 255, 130, 60 }, ice = { 110, 210, 255 },
    electric = { 255, 230, 90 }, light = { 255, 245, 190 }, nature = { 130, 235, 130 },
}

-- 六元素徽章图标路径（可选）。独立内核不绑定任何资源系统：
-- 需要图标时由调用方在加载后覆盖 Data.ELEMENT_ICONS（值为自己的图片路径/句柄），
-- 不覆盖则全部为 nil，UI 自行回退到 ELEMENT_COLORS 纯色圆点即可。
Data.ELEMENT_ICONS = {}

-- C1 改装槽位（固定 4 槽军械库式，枪管/握把/枪口/模块）
Data.SLOTS = { "barrel", "grip", "muzzle", "module" }
Data.SLOT_NAMES = { barrel = "枪管", grip = "握把", muzzle = "枪口", module = "模块" }

-- C2/C3 武器功能类别（适配轴，共 4 套卡池；六属性不参与装备判定）
-- smg 追加在末尾（位置索引被 ENCOUNTERS/PRESETS 等按序号消费，禁止插到中间）
Data.CATEGORIES = { "rifle", "shotgun", "launcher", "support", "smg" }
Data.CATEGORY_NAMES = { rifle = "步枪系", shotgun = "霰弹系", launcher = "发射器系", support = "支援系", smg = "冲锋枪系" }

-- 武器 = 行动单位（T1/T2/T3 + C2 类别归属）。技能结构：
--   normal 普攻：+1 充能；tech 战技：不产充能（AOE/多段/弱化等高价值）；ult 终结技：耗 3 充能
Data.WEAPONS = {
    {
        id = "rifle", name = "突击步枪", element = "none", category = "rifle",
        chargeMax = 3,
        normal = { name = "点射", dmg = 7,  stagger = 2, desc = "单体,充能+1" },
        tech   = { name = "三连发", dmg = 5, stagger = 4, hits = 3, desc = "3段单体,不产充能" },
        ult    = { name = "⭐弹幕扫射", dmg = 18, stagger = 6, aoe = true, desc = "全体射击（单体×0.85）" },
    },
    {
        id = "emp", name = "电磁步枪", element = "electric", category = "rifle",
        chargeMax = 5,
        normal = { name = "电弧射击", dmg = 8,  stagger = 4, desc = "电:高混乱,充能+1" },
        tech   = { name = "磁暴脉冲", dmg = 10, stagger = 5, aoe = true, desc = "电AOE" },
        ult    = { name = "⭐轨道轰击", dmg = 26, stagger = 8, desc = "电单体爆发" },
    },
    {
        id = "burner", name = "燃烧霰弹枪", element = "fire", category = "shotgun",
        chargeMax = 4,
        normal = { name = "烧灼弹", dmg = 9,  stagger = 2, desc = "火,充能+1" },
        tech   = { name = "烧击", dmg = 8,  stagger = 4, aoe = true, desc = "火AOE" },
        ult    = { name = "⭐炎啸风暴", dmg = 22, stagger = 6, aoe = true, desc = "火全体" },
    },
    {
        id = "cryo", name = "冷冻冲锋枪", element = "ice", category = "rifle",
        chargeMax = 2,
        normal = { name = "冰锥射", dmg = 6,  stagger = 2, desc = "冰,充能+1" },
        tech   = { name = "冷冻穿甲", dmg = 12, stagger = 3, weaken = 0.25, desc = "目标下次攻击-25%" },
        ult    = { name = "⭐冰封枪林", dmg = 14, stagger = 6, weaken = 0.25, desc = "单体+攻击弱化" },
    },
    {
        id = "flare", name = "照明支援铳", element = "light", category = "support", passive = "flare_spot",
        chargeMax = 3,
        normal = { name = "照明弹", dmg = 8,  stagger = 2, desc = "光,充能+1" },
        tech   = { name = "致盲闪光", dmg = 6,  stagger = 3, aoe = true, weaken = 0.2, desc = "光AOE全体减攻" },
        ult    = { name = "⭐圣光裁决", dmg = 20, stagger = 6, desc = "光单体,对佣兵特攻感" },
    },
    {
        id = "toxic", name = "腐蚀撒布器", element = "nature", category = "launcher",
        chargeMax = 4,
        normal = { name = "毒液喷", dmg = 7,  stagger = 3, desc = "草,充能+1" },
        tech   = { name = "毒雾", dmg = 9,  stagger = 4, aoe = true, desc = "草AOE" },
        ult    = { name = "⭐腐蚀风暴", dmg = 21, stagger = 7, aoe = true, desc = "草全体高混乱（单体×0.85）" },
    },
    -- 备弹制冲锋枪（0.5 测试枪）：无战技、无终结技、不产充能、不适配任何配件卡。
    -- 普攻=射一发（点击 1 发 / 长按 4 发每秒），备弹射空才结束该武器本回合行动。
    {
        id = "smg", name = "雷霆冲锋枪", element = "electric", category = "smg",
        chargeMax = 0, reserveMax = 8,
        normal = { name = "电涌连射", dmg = 4, stagger = 1, desc = "单体·消耗 1 备弹" },
    },
}

-- 人物法力体系（W1-W4，2026-09-03 定案）：
-- 法力=出征级资源：不自然恢复、CD 管单场频率、仅撤离回营（或重开）回满。
-- 每次施法是跨战斗的真实牺牲 → 魔法池=有限弹药箱，枯竭=软性撤退倒计时。
Data.MANA_MAX = 10

-- ============================================================================
-- 角色表（多角色前向兼容）
--   Data.CHARACTERS = { [characterId] = {id,name,passive,skills={...}} }
--   首发只有 1 个角色（vanguard=远征者）；新角色=填表 + 决定获取途径，架构零改动。
--   养成态按角色分档由调用方自行存 { [characterId] = Progress }。
-- 技能字段：kind heal|block|charge(全场武器+1)|damage(元素伤害)；mp=蓝耗；
--   learnLevel=到级自动学；passive=角色被动（与武器被动共用 PASSIVES 框架）。
-- ============================================================================
-- ============================================================================
-- 0.5 第三波：角色弱点体系（第一波 §6 枚举表落地）
--
--   A 类（可被武器配件抵消）：抵消后 = 中抗性（正常水准，无额外 debuff）
--   B 类（不可抵消）：角色结构性差异，只能换角色/换构筑
--   约束：每位角色至少 1 条 A 类 + 至少 1 条 B 类。
--
--   命中弱点元素：伤害 ×(1 + amp)，并按元素附加 debuff（抵消后全部不触发）。
--   防御的「非弱点伤害 -20%」对弱点伤害无效（见 Session.DefendPlayer 结算）。
-- ============================================================================
Data.WEAKNESS_TYPES = {
    -- A 类：可被配件抵消
    exposure_element = { name = "元素暴露", kind = "A", desc = "受到某一属性伤害提高" },
    fragile_stagger  = { name = "混乱敏感", kind = "A", desc = "混乱阈值低于同定位基准" },
    weak_sustain     = { name = "续航薄弱", kind = "A", desc = "治疗/护盾效率降低" },
    mana_starved     = { name = "法力饥渴", kind = "A", desc = "法力上限低/技能冷却长" },
    -- B 类：不可抵消
    slow_start       = { name = "启动迟滞", kind = "B", desc = "开局节奏慢，依赖充能/技能起手" },
    narrow_coverage  = { name = "覆盖空洞", kind = "B", desc = "技能池缺某一类形态" },
    backfire         = { name = "反噬", kind = "B", desc = "某类行动后自伤或自减益" },
    fragile_collapse = { name = "崩溃不耐", kind = "B", desc = "崩溃状态下额外受伤" },
}

--- 弱点元素伤害加成（用户定案 +30%）
Data.WEAKNESS_AMP = 0.30

--- 弱点命中附加效果（按元素分化；nil = 无）
---   dot      : 持续伤害（value 每回合，turns 回合）
---   suppress : 全场武器充能需求 +value（turns 回合）
---   healcut  : 治疗/护盾获取 ×(1-value)（turns 回合）
Data.WEAKNESS_DEBUFF = {
    fire     = { kind = "dot",      value = 3,   turns = 2, name = "灼烧" },
    nature   = { kind = "dot",      value = 2,   turns = 3, name = "侵蚀" },
    ice      = { kind = "suppress", value = 1,   turns = 1, name = "冻结压制" },
    electric = { kind = "suppress", value = 1,   turns = 1, name = "过载压制" },
    light    = { kind = "healcut",  value = 0.5, turns = 2, name = "圣光灼伤" },
}

--- 取弱点类型定义（未知返回 nil）
---@param id string|nil
---@return table|nil
function Data.GetWeaknessType(id)
    return id and Data.WEAKNESS_TYPES[id] or nil
end

Data.DEFAULT_CHARACTER_ID = "vanguard"

Data.CHARACTERS = {
    vanguard = {
    id = "vanguard",
    name = "远征者",
    description = "以意念驱策浮空枪械的先遣指挥官，战场急救与信标轰炸的操纵者。",
    passive = "command_beat",
    -- 0.5 第三波：A 类弱点（可被对应元素的抵消配件消除）+ B 类短板（不可抵消）
    weakness = {
        id = "exposure_element", element = "fire",
        amp = 0.30,
        name = "火焰暴露",
        desc = "受到火焰伤害 +30%，并附加灼烧（2 回合）；防御减免对火焰伤害无效",
    },
    flaw = {
        id = "slow_start", name = "启动迟滞",
        desc = "开局节奏慢：终结技依赖充能，首回合容易空转",
    },
    -- shortName=compact 手机魔法按钮短标签（全名+CD+蓝耗在窄卡必然折行；点击有 Notify 全名兜底）
    skills = {
        { id = "c_med",    name = "战场急救", shortName = "急救",  kind = "heal",   value = 18, cd = 3, mp = 2, element = "light",    learnLevel = 1, desc = "回复HP" },
        { id = "c_shield", name = "纳米护盾", shortName = "护盾",  kind = "block",  value = 14, cd = 2, mp = 2, element = "none",     learnLevel = 1, desc = "护甲+" },
        { id = "c_siphon", name = "能量虹吸", shortName = "虹吸",  kind = "charge", value = 1,  cd = 4, mp = 3, element = "electric", learnLevel = 1, desc = "全场武器充能+" },
        { id = "c_beacon", name = "信标轰炸", shortName = "轰炸",  kind = "damage", value = 16, cd = 3, mp = 4, element = "light",    learnLevel = 1, desc = "光单体伤害" },
        -- ↓ 升级解锁的新技能（选装面随养成扩大；新角色换一套库）
        { id = "c_nova",   name = "脉冲新星", shortName = "新星",  kind = "damage", value = 7,  cd = 4, mp = 3, element = "electric", learnLevel = 4, aoe = true,  desc = "电全体伤害" },
        { id = "c_rally",  name = "重整旗鼓", shortName = "重整",  kind = "heal",   value = 30, cd = 5, mp = 5, element = "light",    learnLevel = 6, desc = "大量回复HP" },
        { id = "c_charge2",name = "超载增幅", shortName = "增幅",  kind = "charge", value = 2,  cd = 5, mp = 4, element = "electric", learnLevel = 8, desc = "全场武器充能++" },
        },
    },
}

-- 技能 id → 定义（跨角色全局唯一索引：技能 id 全表内不重复即可跨角色检索；
-- 同名 id 属配置错误，后者覆盖前者）。新增角色往 CHARACTERS 里填即可自动进索引。
local SKILL_BY_ID = {}
for _, ch in pairs(Data.CHARACTERS) do
    for _, sk in ipairs(ch.skills) do SKILL_BY_ID[sk.id] = sk end
end
Data.GetSkill = function(id) return SKILL_BY_ID[id] end

--- 取角色定义（nil/未知 id → 默认角色，防新档 activeCharacterId 未置时崩渲染）
---@param characterId string|nil
---@return table { id, name, passive, skills }
function Data.GetCharacter(characterId)
    return Data.CHARACTERS[characterId or Data.DEFAULT_CHARACTER_ID]
        or Data.CHARACTERS[Data.DEFAULT_CHARACTER_ID]
end

-- ============================================================================
-- 角色养成（G1-G5，2026-09-03 定案；永久态见 Progress.lua）
-- 两级货币：上缴物资→军需贡献点(升级用)；升级→成长点(投体质/法力/研习三系用)
-- ============================================================================
Data.MAGIC_SLOTS = 4            -- G4 上场技能槽数（据点免费换装，不额外吃货币）
Data.LEVELING = {
    maxLevel = 20,
    growthPerLevel = 2,         -- 每升 1 级发放的成长点
    costToLevel = function(level) return 30 + (level - 1) * 20 end,  -- 从 level 升到 level+1 所需贡献点
}
Data.GROWTH = {
    phys = { name = "体质", desc = "每点 +14 HP",              max = 10, hpPerPoint = 14, cost = function(cur) return cur + 2 end },
    mana = { name = "法力", desc = "每点 +2 上限，每 2 点全技能蓝耗 -1", max = 8,  manaPerPoint = 2, cost = function(cur) return cur + 2 end },
}
Data.RESEARCH = { maxRank = 5, valuePerRank = 0.20, cost = function(rank) return rank + 1 end }  -- G5 研习点升单技能
-- G1 上缴：演示用"模拟上缴一箱"给固定贡献点跑通循环；真实上缴由调用方按价值折算
Data.CONTRIBUTE_SAMPLE = 25
-- 真实上缴折算率：每 CONTRIBUTE_RATE 金币物品价值 = 1 军需贡献点（可微调）
Data.CONTRIBUTE_RATE = 10

-- 敌人模板（六抗沿用；resist 百分比，负值=弱点）
-- sprite=纯字符串标识，由调用方自行映射到自己的立绘/模型，内核不解释。
Data.ENEMY_TEMPLATES = {
    {
        id = "hound", name = "孢子猎犬", hp = 60, maxStagger = 22,
        sprite = "rot_worm",
        resist = { none = 10, fire = -20, ice = 20, electric = 0, light = -10, nature = 30 },
        intents = {
            { name = "撕咬", dmg = 14, element = "none" },
            { name = "酸液喷吐", dmg = 9, element = "nature" },
        },
    },
    {
        id = "militia", name = "民兵逃兵", hp = 80, maxStagger = 22,
        sprite = "human_archer",
        resist = { none = 0, fire = 10, ice = 0, electric = -10, light = -20, nature = 10 },
        intents = {
            { name = "射击", dmg = 12, element = "none" },
            { name = "换弹", dmg = 0, block = 15 },
        },
    },
    {
        id = "merc_elite", name = "敌对佣兵(精英)", hp = 120, maxStagger = 30,
        sprite = "mercenary_mercenary",
        resist = { none = 20, fire = 10, ice = 0, electric = -15, light = -10, nature = 10 },
        intents = {
            { name = "穿甲射击", dmg = 16, element = "none" },
            { name = "手雷", dmg = 14, element = "fire" },
            { name = "架枪防御", dmg = 0, block = 25 },
        },
        elite = true,
    },
}

-- ============================================================================
-- 改装部件卡池（M1 永久构筑卡 × C1-C4 结构）
--   slot  = 装到哪个槽（C1 固定 4 槽）
--   cats  = 可装武器类别白名单（C2 类别绑定，适配轴）
--   element = 效果词缀（C3/C4：不改主伤害属性，只附加效果）
--     fire=附加燃烧(每次出击后追加3火伤) ice=附加结霜(命中减攻10%)
--     electric=感电(混乱+2) light=圣光(本次伤害+10%) nature=附毒(追加2草伤) none=纯数值
--   apply: "normal"/"tech"/"ult"/"all" 或 {normal=true,...}（passive=开局生效）
-- 底线（M1/AB-017）：不装卡武器照常全技能可战；卡改行为优先于数值贴皮。
-- ============================================================================
Data.MODS = {
    -- 枪管
    { id = "long_barrel",   slot = "barrel", cats = { rifle = true }, element = "none",
      name = "长枪管",   desc = "普攻/战技伤害+25%",                          apply = { normal = true, tech = true }, dmgMult = 0.25 },
    { id = "heat_barrel",   slot = "barrel", cats = { rifle = true, shotgun = true }, element = "fire",
      name = "燃烧枪管", desc = "战技+15%伤害并附燃烧（词缀·火）",             apply = "tech", dmgMult = 0.15 },
    { id = "split_head",    slot = "barrel", cats = { rifle = true }, element = "none",
      name = "分裂弹头", desc = "战技命中全体（步枪专属行为卡）",               apply = "tech", aoeForce = true },
    { id = "slug_barrel",   slot = "barrel", cats = { shotgun = true }, element = "none",
      name = "独头弹枪管", desc = "战技转单体高伤+6（霰弹专属）",               apply = "tech", aoeOff = true, dmgAdd = 6 },
    { id = "cryo_nozzle",   slot = "barrel", cats = { launcher = true }, element = "ice",
      name = "冷冻喷嘴", desc = "战技+20%伤害并附结霜（词缀·冰）",              apply = "tech", dmgMult = 0.20 },
    { id = "beam_barrel",   slot = "barrel", cats = { support = true }, element = "none",
      name = "集束光腔", desc = "普攻+20%伤害（支援专属枪管）",                 apply = "normal", dmgMult = 0.20 },
    -- 握把
    { id = "quick_charge",  slot = "grip",   cats = { rifle = true, support = true }, element = "none",
      name = "快速装填", desc = "普攻充能+1（两回合一大）",                     apply = "normal", chargeAdd = 1 },
    { id = "stabilizer",    slot = "grip",   cats = { rifle = true, support = true, shotgun = true }, element = "none",
      name = "稳定枪托", desc = "战技混乱+50%",                                 apply = "tech",   staggerMult = 0.50 },
    { id = "gel_grip",      slot = "grip",   cats = { shotgun = true, launcher = true }, element = "ice",
      name = "凝胶握把", desc = "终结技+10%伤害并附结霜（词缀·冰）",            apply = "ult",    dmgMult = 0.10 },
    -- 枪口
    { id = "frag_core",     slot = "muzzle", cats = { rifle = true, launcher = true }, element = "none",
      name = "高爆弹芯", desc = "终结技伤害+40%",                               apply = "ult",    dmgMult = 0.40 },
    { id = "trigger_tune",  slot = "muzzle", cats = { rifle = true }, element = "none",
      name = "扳机调校", desc = "战技段数+1（三连发变四连）",                   apply = "tech",   hitsAdd = 1 },
    { id = "breacher",      slot = "muzzle", cats = { shotgun = true }, element = "electric",
      name = "破门收束器", desc = "战技收束为2段×9并感电（词缀·电）",           apply = "tech",   aoeOff = true, hitsAdd = 1, dmgAdd = 1 },
    { id = "light_muzzle",  slot = "muzzle", cats = { support = true }, element = "light",
      name = "聚光器",   desc = "普攻+15%伤害并圣光增幅（词缀·光）",            apply = "normal", dmgMult = 0.15 },
    -- 模块
    { id = "crash_amp",     slot = "module", cats = { rifle = true, shotgun = true, launcher = true, support = true }, element = "none",
      name = "破溃增幅", desc = "对崩溃目标伤害+30%",                            apply = "all",    collapsedBonus = 0.30 },
    { id = "surge_cell",    slot = "module", cats = { rifle = true, support = true }, element = "electric",
      name = "过载电池", desc = "开局充能满3并感电（词缀·电）",                  apply = "passive", startCharge = 3 },
    { id = "spore_filter",  slot = "module", cats = { launcher = true }, element = "nature",
      name = "孢子滤网", desc = "战技+15%伤害并附毒（词缀·草）",                 apply = "tech",   dmgMult = 0.15 },
    { id = "holo_sight",    slot = "module", cats = { rifle = true }, element = "light",
      name = "全息瞄具", desc = "终结技+20%伤害并圣光增幅（词缀·光）",           apply = "ult",    dmgMult = 0.20 },

    -- ── 0.5 第三波：弱点抵消件（占 4 槽之一，与常规枪管卡竞争槽位=代价）──
    -- 只抵消 counterElement 对应的「元素暴露」弱点：换角色/换元素即失效（不抵消"任意弱点"）。
    -- 抵消后该元素对角色=中抗性：伤害不再 +30%、不再附加 debuff、防御恢复全额减免。
    -- element 故意为 none：避免被当成元素词缀附加到攻击上。
    { id = "insulated_barrel", slot = "barrel", cats = { rifle = true, shotgun = true, launcher = true, support = true }, element = "none",
      name = "隔热涂层枪管", desc = "抵消「火焰暴露」弱点；普攻伤害 +5%",
      counter = "exposure_element", counterElement = "fire", apply = { normal = true }, dmgMult = 0.05 },
    { id = "anti_freeze_barrel", slot = "barrel", cats = { rifle = true, shotgun = true, launcher = true, support = true }, element = "none",
      name = "防冻涂层枪管", desc = "抵消「寒霜暴露」弱点；普攻伤害 +5%",
      counter = "exposure_element", counterElement = "ice", apply = { normal = true }, dmgMult = 0.05 },
    { id = "grounding_barrel", slot = "barrel", cats = { rifle = true, shotgun = true, launcher = true, support = true }, element = "none",
      name = "接地涂层枪管", desc = "抵消「电击暴露」弱点；普攻伤害 +5%",
      counter = "exposure_element", counterElement = "electric", apply = { normal = true }, dmgMult = 0.05 },
    { id = "shade_barrel", slot = "barrel", cats = { rifle = true, shotgun = true, launcher = true, support = true }, element = "none",
      name = "滤光涂层枪管", desc = "抵消「圣光暴露」弱点；普攻伤害 +5%",
      counter = "exposure_element", counterElement = "light", apply = { normal = true }, dmgMult = 0.05 },
    { id = "sealed_barrel", slot = "barrel", cats = { rifle = true, shotgun = true, launcher = true, support = true }, element = "none",
      name = "密封涂层枪管", desc = "抵消「侵蚀暴露」弱点；普攻伤害 +5%",
      counter = "exposure_element", counterElement = "nature", apply = { normal = true }, dmgMult = 0.05 },
}

-- ============================================================================
-- 0.5 第二波：舒适感轴卡（现有 17 张以纯数值为主，缺稳定/容错/节奏）
--   axis：rhythm=节奏 / forgive=容错 / aim=指向 / stable=稳定 / power=纯输出
--   modifiers：整场生效的修正器（dur=nil），由 Session.New 注入 Modifiers 表
-- ============================================================================
Data.MODS[#Data.MODS + 1] = {
    id = "precise_sight", slot = "muzzle", cats = { rifle = true, support = true }, element = "none",
    name = "精密瞄具", desc = "命中 +8%（稳定）", apply = "all",
    modifiers = { { stat = "hitAdd", value = 0.08 } },
}
Data.MODS[#Data.MODS + 1] = {
    id = "steady_hand", slot = "grip", cats = { rifle = true, shotgun = true }, element = "none",
    name = "稳定握把", desc = "命中 +12%，伤害 -8%（稳定·有代价）", apply = "all",
    dmgMult = -0.08, modifiers = { { stat = "hitAdd", value = 0.12 } },
}
Data.MODS[#Data.MODS + 1] = {
    id = "recoil_pad", slot = "grip", cats = { launcher = true, support = true }, element = "none",
    name = "缓冲枪托", desc = "受到伤害 -10%（容错）", apply = "all",
    modifiers = { { scope = "player", stat = "defMul", value = 0.90 } },
}
Data.MODS[#Data.MODS + 1] = {
    id = "spare_mag", slot = "module", cats = { shotgun = true, launcher = true }, element = "none",
    name = "备用弹匣", desc = "普攻充能 +1，伤害 -10%（节奏）", apply = "all",
    dmgMult = -0.10, chargeAdd = 1,
}
-- 0.5 第二波：直接降低终结技充能需求（与武器差异化的 chargeMax 联动）
Data.MODS[#Data.MODS + 1] = {
    id = "light_bolt", slot = "module",
    cats = { rifle = true, shotgun = true, launcher = true, support = true }, element = "none",
    name = "轻量枪机", desc = "终结技所需充能 -1（最低 2）", apply = "all",
    modifiers = { { stat = "chargeReqAdd", value = -1 } },
}

-- ============================================================================
-- 0.5 第二波：武器定位与配件舒适感轴（图鉴展示用，不参与结算）
--   role：general=通用（无属性/抗性稳健） specialist=专精（单一属性/抗性强项）
--         spread=覆盖（AOE/多目标）
-- ============================================================================
Data.ROLE_NAMES = { general = "通用", specialist = "专精", spread = "覆盖" }
Data.ROLE_DESC = {
    general = "无属性依赖，抗性未知时最稳",
    specialist = "单一属性高收益，遇弱属性爆发",
    spread = "多目标覆盖，单目标效率偏低",
}
Data.WEAPON_ROLE = {
    rifle  = "general",
    emp    = "specialist",
    burner = "spread",
    cryo   = "specialist",
    flare  = "general",
    toxic  = "spread",
    smg    = "spread",
}

Data.AXIS_NAMES = { rhythm = "节奏", forgive = "容错", aim = "指向", stable = "稳定", power = "输出" }
Data.AXIS_DESC = {
    rhythm = "改变充能/回合与终结技节奏",
    forgive = "降低受伤或提高护盾，增加容错",
    aim = "改变单体/AOE/多段的指向形态",
    stable = "提高命中，降低随机性",
    power = "纯数值增强，不改变手感",
}
---@type table<string, string>
Data.MOD_AXIS = {
    long_barrel = "power", heat_barrel = "power", split_head = "aim", slug_barrel = "aim",
    cryo_nozzle = "power", beam_barrel = "power", quick_charge = "rhythm", stabilizer = "power",
    gel_grip = "power", frag_core = "power", trigger_tune = "aim", breacher = "aim",
    light_muzzle = "power", crash_amp = "power", surge_cell = "rhythm", spore_filter = "power",
    holo_sight = "power",
    precise_sight = "stable", steady_hand = "stable", recoil_pad = "forgive", spare_mag = "rhythm",
    light_bolt = "rhythm",
    -- 0.5 第三波：弱点抵消件（抵消角色弱点 = 提高容错，归"容错"轴）
    insulated_barrel = "forgive", anti_freeze_barrel = "forgive", grounding_barrel = "forgive",
    shade_barrel = "forgive", sealed_barrel = "forgive",
}
--- 取配件舒适感轴（未知卡返回 nil）
---@param modId string
---@return string|nil
function Data.GetModAxis(modId)
    return Data.MOD_AXIS[modId]
end
--- 取武器定位（未知武器回退通用）
---@param weaponId string
---@return string
function Data.GetWeaponRole(weaponId)
    return Data.WEAPON_ROLE[weaponId] or "general"
end

--- 0.5 第二波：有效充能需求（基础 chargeMax + 配件/敌人修正，clamp 2~6）
--- 单一权威：Session 结算、UI/Renderer 画点、图鉴显示都走这里，防双份逻辑漂移。
---@param weaponDef table? Data.WEAPONS 条目
---@param weaponState table? 武器运行时（配件修正按 target 匹配）
---@param modsSet table? ModifierSet（会话修正器表；nil=无修正）
---@return integer
function Data.GetChargeRequirement(weaponDef, weaponState, modsSet)
    local base = (weaponDef and weaponDef.chargeMax) or Data.CHARGE_MAX
    local delta = 0
    if modsSet then
        delta = modsSet:Query("chargeReqAdd", "weapon", weaponState)
    end
    return math.max(2, math.min(6, math.floor(base + delta + 0.5)))
end
local MOD_BY_ID = {}
for _, m in ipairs(Data.MODS) do MOD_BY_ID[m.id] = m end
Data.GetMod = function(id) return MOD_BY_ID[id] end

-- V8 B3：改装卡「基础池 vs 进阶池」（0.3 补给包开包词条来源；草稿 v1，可微调不改数值）
-- 进阶池 = 带元素词缀 / 行为改动类的高价值卡；基础池 = 其余（纯数值为主）。
Data.MOD_POOL_ADV = {
    heat_barrel = true, split_head = true, slug_barrel = true, cryo_nozzle = true,
    quick_charge = true, gel_grip = true, trigger_tune = true, breacher = true,
    light_muzzle = true, surge_cell = true, spore_filter = true, holo_sight = true,
    -- 0.5 第二波舒适感轴卡（有取舍，进进阶池）
    steady_hand = true, recoil_pad = true, spare_mag = true,
}
--- 取某词条池的改装卡全量（pool: nil/"any"=全部；"basic"/"adv"=分池）
function Data.GetModPool(pool)
    local out = {}
    for _, m in ipairs(Data.MODS) do
        local isAdv = Data.MOD_POOL_ADV[m.id] == true
        if pool == nil or pool == "any" or (pool == "adv" and isAdv) or (pool == "basic" and not isAdv) then
            table.insert(out, m)
        end
    end
    return out
end

--- C2 类别绑定校验：这张卡能否装到该武器
---@param modId string
---@param weaponDef table Data.WEAPONS 条目
---@return boolean
function Data.CanEquip(modId, weaponDef)
    local mod = MOD_BY_ID[modId]
    if not mod then return false end
    return mod.cats[weaponDef.category] == true
end

--- 某类武器某槽位的可用卡列表（按卡池定义顺序）
---@param category string
---@param slot string
---@return table 改装卡数组
function Data.GetModsFor(category, slot)
    local list = {}
    for _, m in ipairs(Data.MODS) do
        if m.slot == slot and m.cats[category] then table.insert(list, m) end
    end
    return list
end

-- ============================================================================
-- 原型演示"构筑"预置（军械库配置代表）：mods[武器位 i] = { [槽名] = 卡id }
-- 换构筑会重启战斗（原型简化）；实战中装卡/卸卡走军械库面板，不重启。
-- ============================================================================
-- 注：预置按 遭遇1 武器位（位1=燃烧霰弹/位2=照明支援/位3=突击步枪）配置以直观展示 C2；
-- 换到其他遭遇时类别不匹配的卡会在 Session.New 里被静默跳过（军械库可手动补装）。
---@type table[]
Data.PRESETS = {
    { name = "全裸对照（C1 底线：4 槽全空照样战）", shortName = "全裸对照", mods = { {}, {}, {} } },
    { name = "爆发开局（霰弹破溃+支援聚光+步枪电池）", shortName = "爆发开局", mods = {
        { module = "crash_amp" },
        { muzzle = "light_muzzle", grip = "quick_charge" },
        { module = "surge_cell", barrel = "long_barrel" },
    } },
    { name = "词缀流（燃烧枪管+破门收束·火/电）", shortName = "词缀流", mods = {
        { barrel = "heat_barrel", muzzle = "breacher" },
        { barrel = "beam_barrel" },
        { barrel = "heat_barrel", muzzle = "trigger_tune" },
    } },
    { name = "步枪位满配（管把口模 4 槽全开示例）", shortName = "满配", mods = {
        {},
        {},
        { barrel = "long_barrel", grip = "quick_charge", muzzle = "frag_core", module = "holo_sight" },
    } },
}

-- 原型编队 = "构筑"决策展示位：每场指定 3 把上场武器（WEAPONS 索引）
---@type table[]
Data.ENCOUNTERS = {
    { name = "遭遇 1：巡逻犬(怕火/光)", enemies = { "hound", "hound" }, loadout = { 3, 5, 1 } },
    { name = "遭遇 2：杂牌哨兵(怕电/光)", enemies = { "hound", "militia" }, loadout = { 2, 5, 4 } },
    { name = "遭遇 3：佣兵精英(怕电,抗无)", enemies = { "merc_elite", "militia" }, loadout = { 2, 6, 1 } },
    -- 出征链加深（连续出征链实玩）：后段压力抬升，法力/血量衰减曲线真正可见
    { name = "遭遇 4：猎犬群袭(怕火)", enemies = { "hound", "hound", "militia" }, loadout = { 3, 5, 1 } },
    { name = "遭遇 5：佣兵精锐队(怕电,抗无)", enemies = { "merc_elite", "militia", "hound" }, loadout = { 2, 6, 1 } },
}

--- 出征链每场胜利累计的「待入账上缴贡献」（G1 模拟；撤离才入账、败北没收）
Data.CHAIN_CONTRIBUTE = 25

Data.PLAYER_HP = 130

-- ============================================================================
-- 战斗道具（六轮四：E5 局内道具·占人物一次行动）
-- 真实模式：从背包/仓库读正式 V2 消耗品卡（cardType=="consumable"），
--   按其自带 heal/damage/applyEffects 字段解释效果（复用 CV3 现有原语，不新建 CV3 物品类型）。
-- 演示模式（无 Game）：回退本表，保证冒烟/演示零风险（AB-025 新系统层默认回退）。
-- kind: heal=回血 / damage=伤害(aoe?) / debuff=全体减攻(weaken，复用 e.weakenPct)
Data.DEMO_ITEMS = {
    { id = "consumable_bandage",    name = "绷带",   icon = "🩹", kind = "heal",   value = 10, uses = 3 },
    { id = "consumable_grenade",    name = "手榴弹", icon = "💣", kind = "damage", value = 20, aoe = true, uses = 1 },
    { id = "consumable_smoke_bomb", name = "烟雾弹", icon = "💨", kind = "debuff", value = 0.5, aoe = true, uses = 1 },
}

return Data
