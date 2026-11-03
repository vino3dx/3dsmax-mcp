# 参数暴露规则：声明与读取的双向契约

一个工具的参数字段（catalog 的 `properties`）和 MAXScript handler 实际读取的键，
是两份可以不一致的清单。两个方向都会出问题，但严重性不同。

## 1. 两个方向

| 方向 | 表现 | 后果 | 处理 |
| --- | --- | --- | --- |
| **声明了但从不读** | Agent 传 `keepScene: true`，调用成功，设置没变 | 调用方以为生效了——**比报错更糟** | 硬门禁，`param_contract_audit.py` 直接失败 |
| **读了但没声明** | handler 支持 `limit`，客户端传不进去 | 能力存在但不可发现 | 报告，人工判断（有些是有意的） |

第一条是承诺失效，必须当 bug 修；第二条是能力没写进说明书，可能只是设计选择。

## 2. 当前"读了但没声明"的全部条目

运行 `python test/static/param_contract_audit.py` 会打印这份清单。截至现在共 8 条，
分成三类：

### 2.1 别名（2 条）

| 工具 | 未声明键 | 说明 |
| --- | --- | --- |
| `set_language` | `lang` | 声明的是 `language`，为空时回落到 `lang` |
| `execute_maxscript` | `command` | 声明的是 `code`，为空时回落到 `command` |

别名是历史兼容。**不补声明**：同一个东西给两个名字，只会让 Agent 猜哪个才对。
声明的主名已经是推荐的用法。

### 2.2 共用 handler 的并集（5 条）

`light_create_omni` / `spot` / `directional` / `sun` / `area` 全部指向
`mcpH_light_create`，所以 handler 认识所有灯型的参数；每个工具只声明**该灯型有意义**的那部分。

| 工具 | 未声明键 | 为什么合理 |
| --- | --- | --- |
| `light_create_omni` | `altitude` `azimuth` `coneAngle` `penumbra` | 点光源没有方向与锥角 |
| `light_create_spot` | `altitude` `azimuth` `intensity` | `intensity` 与已声明的 `multiplier` 是同一个量纲 |
| `light_create_directional` | `altitude` `azimuth` `coneAngle` `decay` `intensity` `penumbra` | 平行光没有位置衰减与锥角 |
| `light_create_sun` | `castShadows` `color` `coneAngle` `decay` `intensity` `multiplier` `penumbra` | 太阳由 `light_set_sun` 调方位角/高度角 |
| `light_create_area` | `altitude` `azimuth` `castShadows` `coneAngle` `decay` `intensity` `penumbra` | 面光源没有锥角与方向 |

**不补声明**：如果每个都补成全并集，五个工具的参数表会一模一样，"这是点光源"这个
信息就没有了。需要完整控制时用 `light_set`（它声明了全套）。

### 2.3 静态分析的假阳性（1 条）

| 工具 | 未声明键 | 真相 |
| --- | --- | --- |
| `export_engine_preset` | `preset` `upAxis` | 不是参数：handler 从 `engine` 推导这两个值，然后把它们写进结果 |

审计跟随了函数调用，把被复用的导出逻辑也算进了这个 handler。**不需要任何改动**。

## 3. 新增参数时的决策

```text
要加一个参数？
├─ handler 会读它吗？
│  ├─ 不会 → 不要声明（否则就是虚假承诺，门禁会拦）
│  └─ 会 → 声明它
└─ handler 支持但不想让客户端传？
   └─ 保留在"未声明"清单里，并在第 2 节说明理由
```

反向的陷阱：**不要**为了"让审计安静"而给 handler 加 `mcpGet params "x"`。
那只是让参数从"不可发现"变成"可传但没用"。

## 4. 相关工具

| 命令 | 作用 |
| --- | --- |
| `python test/static/param_contract_audit.py` | 正向：声明了必须读（硬断言）；反向：读了没声明（报告） |
| `python test/static/catalog_contract_test.py` | schema 类型、枚举、preset 合并的正确性 |
| `python test/static/doc_alignment_audit.py` | 工具数量与 `docs/tools.txt` 等文档的一致性 |

## 5. 本轮（Stage 6）修过的

| 工具 | 问题 | 处理 |
| --- | --- | --- |
| `scene_new` | `keepScene` 声明了但从不读，每次调用都重置单位/帧率/分辨率 | 实现，返回 `kept` 说明哪几项保住了 |
| `rig_skin_add_bone` | `rigid` 声明了但 `addBone` 恒传 0 | 读参数，传 0/1 |
| `light_set_sun` | `timeOfDay` 没有可移植 API | 删声明，描述改用方位角/高度角 |
| `list_layers` / `get_scene_assets` | handler 支持 `limit`，catalog 没声明 | 补声明 |
| `bake_ao` / `bake_normals` / `bake_lighting` | handler 支持 `elements` / `template`，catalog 没声明 | 补声明，与 `bake_texture` 对齐 |
