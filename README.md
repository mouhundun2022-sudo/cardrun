# cardrun-combat — 可复用的回合制战斗内核

从撤离射击游戏《荒原猎火》中抽出的**纯 Lua 逻辑内核**，零引擎依赖。
任何人都可以在自己的 Lua 5.4 项目里 `require` 加载，得到一套完整的
「武器即行动单位」回合制战斗。

## 它是什么

**武器 = 场上行动单位，人物 = 指挥官。**

- 每回合每把武器各有 **1 次行动**（三选一：普攻 / 战技 / 终结技），人物另有 **1 次行动**
- **普攻**产充能 → 攒满 **终结技**（0~3 点，各武器独立）
- **战技**不产充能，但 AOE / 多段 / 弱化等价值更高的效果挂在这里
- 人物施法消耗**出征级法力池**（不自然回复，撤离才回满），魔法走独立 CD

## 内核包含什么

| 模块 | 行数 | 内容 |
|---|---|---|
| `combat/data.lua` | ~550 | 7 把武器（六元素 + 备弹冲锋枪）、3 个敌人模板、27 张改装卡、4 个预置构筑、5 场遭遇、演示道具 |
| `combat/session.lua` | ~1900 | 战斗状态机：出手结算 / 敌方回合 / 目标选择 / 道具 / 护甲 / 崩溃 / 出征链 |
| `combat/modifiers.lua` | ~310 | 统一乘区修正器框架（战技 debuff、配件效果全部走这一张表） |
| `combat/progress.lua` | ~240 | 角色养成永久态：经验、等级、三系加点、技能解锁与研习 |
| `combat/enemy_formula.lua` | ~390 | TTK 驱动的怪物数值公式（等级只是标签，击杀回合数才是自变量） |

**不包含**：渲染（NanoVG / 引擎图形）、UI 布局、资源加载、存档系统。这些全部由宿主自行决定。

## 安装

把 `combat/` 目录拷进你的项目，然后：

```lua
local Session = require("combat.session")
local Data = require("combat.data")
```

`combat/session.lua` 内部用 `require("combat.xxx")` 找同级模块，所以只要
`combat/` 在 `package.path` 能 resolver 的位置即可。

没有外部依赖（`pcall` / `table` / `math` / `string` 都是 Lua 标准库）。

## 最快上手：5 行跑一场

```lua
local Session = require("combat.session")

local s = Session.New(1)              -- 遭遇 1
print(s:PlayWeapon(1, "normal"))      -- 第 1 把枪普攻
print(s:PlayWeapon(2, "tech"))        -- 第 2 把枪战技
print(s:WaitPlayer())                 -- 人物跳过
-- 三把武器 + 人物都行动完 → 自动进入敌方回合并结算
```

`Session.New(encounterIdx, presetIdx, mana, progress, opts)` 五个参数全是可选的：

- `encounterIdx`：用第几场遭遇（`Data.ENCOUNTERS`，默认 `1`）
- `presetIdx`：用第几套预置构筑（`Data.PRESETS`，默认 `1`）
- `mana`：初始法力（不传 = 满）
- `progress`：角色养成态（不传 = 全新 1 级）
- `opts`：见下方「集成」

## 主要 API

### 回合内（我方）
| 方法 | 说明 |
|---|---|
| `s:PlayWeapon(wIdx, skillKind, targetIdx)` | **核心出手**。`skillKind` = `"normal"` / `"tech"` / `"ult"` |
| `s:FireSmg(wIdx, targetIdx)` | 备弹制武器（smg）单发点射 |
| `s:FillReserve(wIdx)` | 备弹制武器填充备弹（占用一次行动位） |
| `s:CastMagic(mIdx, targetIdx)` | 人物施法 |
| `s:UsePendingItem(enemyIdx)` | 使用已选中的战斗道具 |
| `s:DefendPlayer()` | 人物防御（本回合非弱点伤害 -20%） |
| `s:WaitPlayer()` | 人物跳过 |
| `s:EndTurn()` | 主动结束我方回合 |
| `s:SetTarget(enemyIdx)` | 指定全体共享目标（nil = 清空） |

### 状态查询
| 方法 | 说明 |
|---|---|
| `s:GetWeaponPreview(wIdx)` | 该武器当前技能预测（含克制/抵抗提示） |
| `s:ResolveSkill(weaponState, kind)` | 基础技能 × 已装改装卡 → 实际生效技能表 |
| `s:AllActed()` | 本回合所有单位是否已行动完 |
| `s:CheckEnd()` | 判定胜负（`s.state` = `running` / `victory` / `defeat`） |

### 战斗外
| 方法 | 说明 |
|---|---|
| `Session.CollectItems(opts)` | 从宿主物品列表中收集可用消耗品 |
| `s:Advance()` | 出征链：进入下一场遭遇（血量/法力/养成态跨场保留） |
| `s:Evacuate()` | 撤离回营：法力回满，链内累计贡献入账 |
| `s:EquipMod(wIdx, slot, modId)` | 装卸改装卡（`modId == nil` 卸下） |

### 表现层（宿主可选读）
`s.shots`（弹道）、`s.fx`（飘字）、`s.timers`（延迟视觉回调）、`s.banner`（回合横幅）、
`s.player.castT`（指挥手势计时）。**逻辑层不依赖这些字段的任何值**，不读也没关系。

## 集成：`opts` 全部钩子

内核本身**不读存档、不碰资源、不写文件**。凡是需要落库或外部状态的地方，
都用可选钩子暴露给宿主。全部是可选的——不传就是纯内存运行。

```lua
local s = Session.New(1, nil, nil, myProgress, {
    -- 1. 编队：纯数据，不传则用遭遇自带的演示编队
    loadout = {
        { weapon = "burner",                  -- 武器 id（或 Data.WEAPONS 下标）
          mods = { barrel = "heat_barrel" },  -- 已装改装卡 slot->modId
          instanceId = "gun_a",               -- 你自己的实物标识（内核不解释）
          charge = 1 },                       -- 起始充能
        { weapon = "emp" },
        { weapon = 7 },                       -- 下标也行
    },

    -- 2. 消耗品来源：任选其一
    itemLists = { myBagItems, myWarehouseItems },
    -- 或者给 game 对象 + 取列表函数：
    -- game = myGame, storageLists = function(g) return { g.bag, g.warehouse } end,

    -- 3. 改装卡持久化：装/卸卡时回调，你负责扣/回库存、写存档
    onEquipMod = function(opts, instanceId, slot, modId)
        -- 返回 ok, 消息, newMods（newMods 可选，覆盖内核内的 mods）
        return true, "已装配", myNewModsTable
    end,

    -- 4. 道具消耗回调：你负责从真实背包删除
    onItemConsumed = function(opts, itemRef, list) end,

    -- 5. 护甲/耐久减伤：你负责按自己的装备系统折算
    -- 返回 (最终伤害, 减免量)
    applyArmor = function(opts, dmg, element, intent)
        return dmg - 5, 5
    end,

    -- 6. 落库通知：状态变更后调用（装卸卡 / 用道具 / 出征链推进）
    onSave = function(opts) end,

    -- 7. 出征链下一战的新编队
    nextLoadout = { { weapon = "burner" }, { weapon = "emp" }, { weapon = "rifle" } },
})
```

## 扩展：加一把枪

在 `combat/data.lua` 的 `Data.WEAPONS` 末尾追加一项即可，**不用改任何逻辑**：

```lua
{
    id = "railgun", name = "磁轨炮", element = "electric", category = "launcher",
    chargeMax = 4,                          -- 终结技充能需求（nil 用默认 3）
    normal = { name = "穿甲弹", dmg = 12, stagger = 6, desc = "单体高伤" },
    tech   = { name = "过载炮击", dmg = 18, stagger = 8, aoe = true },
    ult    = { name = "⭐湮灭射线", dmg = 40, stagger = 12 },
},
```

可选字段：
- `reserveMax`：备弹制（设为数字即切换为"填弹"模式，`chargeMax` 应设 0）
- `passive`：被动 id（在 `Data.PASSIVES` 里定义；`on_hurt` / `on_collapse` 触发）
- `hits`：多段攻击
- `aoe`：全体
- `weaken`：目标下次攻击削弱比例

## 扩展：加一个敌人

在 `Data.ENEMY_TEMPLATES` 末尾追加：

```lua
{
    id = "sniper", name = "狙击手", elite = false,
    sprite = "enemy_sniper",               -- 纯字符串，你自己映射到立绘
    hp = 26, maxStagger = 30,              -- 血量 / 混乱阈值
    resist = { fire = 10, ice = -20 },     -- 六元素抗性（-100~100，负=弱点）
    intents = {                            -- 攻击意图循环
        { name = "瞄准射击", dmg = 9, element = "none" },
        { name = "穿甲弹", dmg = 12, element = "none" },
    },
},
```

然后把 `id` 写进某场遭遇的 `enemies` 数组即可。

## 扩展：加一张改装卡

```lua
Data.MODS[#Data.MODS + 1] = {
    id = "rail_barrel", name = "磁轨枪管", slot = "barrel",
    cats = { launcher = true },             -- 只适配发射器系
    element = "none",                       -- 词缀元素（none = 不带词缀）
    dmgPct = 0.25,                          -- 普攻/战技伤害 +25%
    desc = "发射器系伤害 +25%",
}
```

可用字段：`dmgPct` / `aoe`(bool) / `hits`(int) / `chargeAdd` / `collapseBonus` /
`startCharge` / `weaken` / `extras`（词缀附加效果）。完整列表见 `data.lua` 的 `MODS`。

## 崩溃机制

敌人有「混乱值」：受到伤害/额外混乱累加，达到 `maxStagger` 即**崩溃**：
- 崩坏的当回合：受到伤害 ×1.5
- 敌人下一回合**被定身跳过**
- 然后混乱清零、恢复行动

## 六元素

`none` / `fire` / `ice` / `electric` / `light` / `nature`

伤害公式：`基础值 × (100 - 有效抗性) / 100`（抗性可为负，负 = 打出更多伤害）。
弱点 debuff（燃烧 / 结霜 / 感电 / 圣光 / 附毒）在 `Data.WEAKNESS_DEBUFF` 定义。

## 角色养成

`combat/progress.lua` 提供完整的永久养成：

```lua
local Progress = require("combat.progress")
local p = Progress.New()          -- 1 级新角色
p:Contribute(200)                 -- 上缴战利品 → 贡献点
p:LevelUp()                       -- 升级（发成长点、解锁技能）
p:Invest("phys")                  -- 投一点体质（另一支系是 "mana"）
p:EquipSlot(1, "pulse_nova")      -- 第 1 槽装备技能（槽位固定 4 个）
p:ResearchSkill("pulse_nova")     -- 研习（升该技能等级）
```

**⚠️ 存档注意**：`Progress` 是带元表的实例。若你要把它存成 JSON 再读回，
读回后是**裸表**（方法全丢）。必须用 `Progress.Wrap(rawTable)` 重新挂载元表再使用：

```lua
local saved = json.decode(json.encode(p))   -- 这里是裸表，调 p:GetMaxHp() 会崩
local p2 = Progress.Wrap(saved)             -- 重挂元表后才能用
```

## 跑测试

```bash
# 纯 Lua 版（不需要任何引擎）
lua5.4 tests/run.lua
```

测试覆盖：三场自动战斗收敛、每武器每回合限 1 次、充能跨回合、护甲清零、
崩溃定身、六元素克制、`opts.loadout` 纯数据编队、全部钩子可被调用。

## 目录

```
cardrun-combat/
├── combat/
│   ├── data.lua            武器 / 敌人 / 改装卡 / 遭遇
│   ├── session.lua         战斗状态机（核心）
│   ├── modifiers.lua       统一修正器框架
│   ├── progress.lua        角色养成永久态
│   └── enemy_formula.lua   TTK 驱动的怪物数值
├── examples/
│   ├── 01_basic_battle.lua        最小一场战斗
│   ├── 02_custom_weapon_enemy.lua 自定义武器 + 自定义敌人
│   └── 03_integration.lua         完整 opts 钩子集成示例
├── tests/
│   └── run.lua             纯 Lua 冒烟测试
├── docs/
│   └── ai-prompt.md        AI 提示词（雷霆冲锋枪 / 仓库概览）
└── README.md
```

## AI 提示词

见 [docs/ai-prompt.md](docs/ai-prompt.md)：含「雷霆冲锋枪」实现提示词与仓库整体说明提示词，可直接投喂给 AI 生成同类模块或扩展示例。

## License

MIT（按仓库 LICENSE 为准）
