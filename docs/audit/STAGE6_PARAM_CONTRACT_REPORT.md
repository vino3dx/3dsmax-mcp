# Stage 6 报告：虚假参数与枚举键的盲点

日期：2026-11-03
基线：Stage 5 结束于 `b1a1401`

Stage 5 修的是"handler 说了什么但说得不对"。这一轮换了个方向：**catalog 承诺了什么，
而 handler 根本没做**。

## 1. 方法

工具描述是给 Agent 看的契约：声明了 `keepScene`，Agent 就会传它；传了没反应，比报错更糟，
因为调用方会以为设置已经生效。

所以做了一次静态比对：

```text
catalog 声明的参数  vs  handler 里 mcpGet/mcpStr/mcpBool/... 实际读的键
```

难点是误报。三类 handler 静态读不出来，必须跳过，否则会害人删掉真实参数：

| 形态 | 例子 | 为什么跳过 |
| --- | --- | --- |
| 按键名循环 | `for pn in dimProps do mcpGet params pn` | 参数名在数组里，不在调用点上 |
| 全量透传 | `for e in (mcpPairs params) do ...` | `mod_*` 把未读参数塞进修改器属性袋 |
| 别名 | handler 读 `language`，缺失时回落到 `lang` | 已声明的键看不出别名 |

统计：**338 个工具可静态检查，46 个因上述形态跳过，0 违规**（修复后）。

## 2. 找到的四个问题

### 2.1 `scene_new.keepScene`：声明了但从不读

```maxscript
fn mcpH_scene_new params =
(
    resetMaxFile #noPrompt        -- keepScene 在哪里？没有
    ...
)
```

描述写"可选保留当前场景的某些设置"，参数也声明了。实际每次都把单位、帧率、渲染分辨率
连同对象一起重置——**用户以为保住了，其实没有**。

修法：真的实现。

```maxscript
local keep = mcpBool params "keepScene" default:false
-- 先记住四项设置
try ( unitsType = units.SystemType ) catch(...)
...
resetMaxFile #noPrompt
-- 再放回去，并记录哪几项真的恢复了
if keep do ( ... append kept "units" ... )
```

返回里多了 `kept`，调用方能看见哪几项活下来了。

### 2.2 `rig_skin_add_bone.rigid`：声明了但硬编码

```maxscript
try ( skinOps.addBone skinMod boneNode 0 ) catch ( ... )
```

第三个参数一直是 `0`（weighted）。描述却写着"可指定 rigid/weighted 初始模式"。

修法：读参数，保留整数形式（0/1）——对要 boolean 的版本它是 falsy/truthy，
对要整数的版本它就是原值。

### 2.3 `light_set_sun.timeOfDay`：没有实现基础

Max 的 Daylight / Sunlight / IES_Sun 三类系统没有统一的"一天中的时间"属性，
硬做只能猜。**删掉声明**，描述里改成"用方位角/高度角"，这是唯一诚实的选项。

### 2.4 枚举键只认数组，漏掉布尔

这条是修 2.1 时被测试逼出来的：

```text
scene_new   -> {"created": true}
delete_file -> {"deleted": true}
```

`created` / `deleted` 在 `_OUTCOME_KEYS` 里，但 `declared_outcome()` 只接受
`isinstance(value, list)`。于是这两个工具**做完了事却报 `missing_success`**——
和 Stage 4 修的那类"保存成功报失败"是同一个形状。

修法：枚举键按值判定，与回执字段用同一个 `_receipt_verdict`：

```python
for key in _OUTCOME_KEYS:
    if key not in source: continue
    verdict = _receipt_verdict(source[key])   # list / bool / str / int
    if verdict is not None:
        return verdict, key
```

`created: true` 与 `created: ["Box001"]` 现在是同一句话的两种写法。

## 3. 连带修正的测试

两个既有测试用 `{"created": True}` 当"没有结论"的例子：

- `runtime_contract_test.py`
- `scene_runtime_test.py`

这个例子本身是错的：布尔 `created` 就是一句结论。改成 `{"message": "OK"}`
（真正没有结论），并各自补一条"`created: true` 判成功"的断言。

**这不是为了让测试通过而放宽标准**——严格性没变：`message` 依然不算证据，
新的 `param_contract_audit` 反而加了一道门禁。

## 4. 新增门禁

`test/static/param_contract_audit.py`（Static）：

```text
param contract: checked=338 skipped(dynamic)=46 violations=0
```

任何"声明了但从不读"的参数都会让它失败，并打印工具名与参数名。
跳过的 46 个在脚本头部逐类说明了原因——**宁可漏检，也不误报**，
因为误报会引导人去删真实参数。

## 5. 测试与验证

| 检查 | 结果 |
| --- | --- |
| 22 个静态/离线测试文件 | 全通过 |
| `param_contract_audit.py` | 338 checked / 46 skipped / 0 violations |
| `outcome_audit.py` | 282 / 293 可读（与 Stage 5 相同） |
| `verify.py` / `test_e2e.py` / `ms_check.py` | 通过 / 通过 / 0 problem |
| `registration_sync_test` | 仍是部署树漂移（需 install.py） |

新增离线用例 `check_scene_new_keeps_settings_only_when_asked`（Offline）：
不带 `keepScene` 时对象与设置一起清空；带了时对象清空、单位/帧率/分辨率保留，
层回到初始状态。

## 6. 已知限制

| 限制 | 说明 |
| --- | --- |
| 静态比对的盲区 | 46 个工具跳过，其中真的可能有假参数；要覆盖它们需要运行时抓取（记录实际读到的键） |
| 只查"声明了没读" | 反方向（handler 支持、catalog 没声明 = 隐藏能力）只报告不门禁，因为有些是故意的（`light_create_*` 的 `type` 由预设决定） |
| `kept` 依赖 Max 行为 | `resetMaxFile` 之后能否重新赋 `units.SystemType`，离线只能证明逻辑，不能证明 Max 接受；已列入 R14 |

## 7. 下一阶段

1. **R14 真机验收**：`scene_new{keepScene:true}` 之后确认单位/帧率/分辨率真的还在；
   `rig_skin_add_bone{rigid:true}` 之后用 `skinOps.GetBoneWeight` 或蒙皮显示确认是刚性。
2. **把"隐藏能力"变成清单**：`list_layers.limit`、`bake_*.elements` 这类 handler 支持
   但没声明的参数，逐个决定是补声明还是删实现。
3. **运行时参数追踪**：要覆盖那 46 个跳过的工具，只能在桥接侧记录"这次实际读了哪些键"，
   再与 catalog 比对。这比静态扫描可靠，但需要一次真机往返。
