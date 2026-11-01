# Stage 4 工作流报告：把工作流变成默认习惯，并把证据补全

日期：2026-11-01
分支：`main`
提交：`abbe95e` — `feat: make scene workflows the default and close the evidence gaps`
基线：Stage 3 结束于 `f03e4e0`（工作区干净）

Stage 3 建好了机器；Stage 4 让这台机器成为默认做法，并补上能力矩阵里最后两行空白。
本阶段**没有新增工具**（仍 386 个）、**没有新增桥接命令**（仍 353 个），改动集中在
"读得准、证得实、说得清"三件事上。

## 1. 起点与范围

Stage 3 的最终报告列了五项后续任务，本阶段做了其中四项：

| # | 建议任务 | 本轮 | 说明 |
| --- | --- | --- | --- |
| 1 | 补第 12、15 步（组织、保存导出）的离线证据 | 做了 | 见第 3 节 |
| 2 | 执行 R1–R10 真实 Max 验收 | **未做** | 需要启动 3ds Max，超出本阶段约束；清单仍在 `docs/WORKFLOW_ACCEPTANCE.md` 第 3 节 |
| 3 | 把 `workflow_run` 接进 Agent 的默认操作习惯 | 做了 | 改 MCP `instructions`，见第 6 节 |
| 4 | 报告与诊断收口 | 部分做了 | `recovery.diagnosis` 做了；**MCP log 通知没做**，理由见第 7 节 |
| 5 | 快照基线可持久化 | 做了 | `saveBaseline` / `baselineFile`，见第 5 节 |

## 2. 过程中发现的真问题：执行成功却被报成失败

补组织/保存导出的离线证据时，第一步就撞墙：`create_layer` 在 core 档位下返回
`missing_success`。顺着查下去，这不是个别工具的问题，而是一整类。

**根因**：可靠性模式下 `runtime.declared_outcome()` 只认 `success` / `ok` /
`failures` / `applied` / `deleted` / `created` / `objects`。而 `src/ms` 里一批 handler
用的是**回执式**返回：

```maxscript
mcpPair p "saved" full                      -- scene_save / scene_save_as
mcpPair p "written" res[1]                  -- export_*
mcpPair p "opened" path                     -- scene_open
mcpPair p "group" g.name                    -- group_objects
mcpPair p "layer" name                      -- create_layer
```

这些字段**本来就带着真实证据**（`written` 来自导出后对文件的检查，`saved` 来自
`saveMaxFile` 之后的实际路径），只是 Python 侧没读。也就是说：缺的不是证据，是读取。

**影响面**：core 档位下 `scene_save`、`scene_save_as`、`scene_open` 三个日常工具
一直在报失败——保存成功却说失败，Agent 很可能因此重试保存或改道，而这两件事都有风险。

**全量审计**（`test/static/outcome_audit.py`，静态扫描 299 个 mutating 工具）：

| 指标 | 修前 | 修后 |
| --- | --- | --- |
| 能读出结论的 mutating 工具 | 211 | 219 |
| 读不出的 | 88 | 74 |
| core 档位缺口 | 7 | **0** |

（core 那 7 个是 `execute_maxscript`、`rename_object`、`poly_select_faces`、
`mat_set_diffuse`、`light_create_omni` / `create_spot`；`transform_object` 是审计的
假阳性——它走逐对象 batch，结论在 Python 侧构造，不依赖桥接回包。）

剩下 74 个是真正的声明缺口（`hide_objects`、`freeze_objects`、`bake_set_output`、
`mat_set_pbr` 等），它们要么只返回 `{message}`，要么在 `catch()` 里吞掉错误。
本阶段**没有**为了凑数给它们加 `success:true`——那会把"静默失败"变成"成功"，
比现在的错误更危险。

## 3. 判定规则：回执按值读，`message` 永不算数

`runtime.declared_outcome()` 的判定顺序（`docs/ERROR_CODES.md` 第 5 节同步）：

| 顺序 | 依据 | 规则 |
| --- | --- | --- |
| 1 | `success` / `ok`（布尔） | 直接采用 |
| 2 | `failures`（数组） | 空即成功，非空即失败（条目可以是错误对象，也可以是纯文本） |
| 3 | `applied` / `deleted` / `created` / `objects` / `results`（数组） | 非空即成功，空即"没做成" |
| 4 | 回执字段 | 布尔（`written`/`reset`/`copied`/`renamed`）取值本身；路径名（`saved`/`opened`/`merged`/`group`/`layer`）非空即成功；对象名列表（`moved`/`aligned`/`attached`/`detached`/`children`/`ungrouped`）非空即成功 |
| 5 | 都没有 | `missing_success`——**没有证据不等于成功** |

关键约束：**`message` 永远不参与判定**。每个 handler 都会返回它，包括什么都没做的那些；
把它当结论，就是把"没有证据"读成"成功"，而这正是这个函数存在的理由。

同一原则的第二个用法：`{"saved": ""}` 与 `{"written": false}` 必须判**失败**。所以回执
按值读，不按存在读——一个 handler 无法靠"字段出现了"蒙混过关。

### 3.1 MAXScript 侧补的三类诚实回执

改 Python 只能读已有字段；有些 handler 确实什么都没说。本阶段补了 4 处，每处都是
"把已经发生的事实说出来"，不是加一个乐观默认值：

| handler | 改动 | 为什么是诚实的 |
| --- | --- | --- |
| `mcpH_execute_maxscript` | `mcpPair p "success" true` | 脚本抛错时上面已经 `throw failure`，能走到这行说明脚本跑完了 |
| `mcpH_mat_set_diffuse` | `mcpPair p "success" true` | 前面有 `if not done do mcpFail`，能返回就说明真的设上了 |
| `mcpH_light_create` | `mcpPair p "success" true` | 未知类型/缺类已经 `mcpFail`，能返回说明灯对象存在 |
| `mcpH_rename_object` | `mcpPair p "renamed" (n.name == newName)` | Max 遇到重名**不报错、静默保留旧名**，所以比较而不是假设 |
| `mcpH_ungroup_objects` | 收集 `ungrouped` / `failures` | 原实现 `for n in nodes do (try (ungroup n) catch())` 把每个错误吞掉后回答 "ok" |

`ungroup_objects` 那处是行为改变，不只是加字段：以前对普通网格解组会回答成功，
现在 `ungrouped` 为空即判失败。离线用例 `check_ungroup_reports_what_it_did` 覆盖了它。

## 4. 组织与保存导出的离线证据

`FakeScene` 新增 7 个 handler，形状逐字对照 `src/ms`：

| 命令 | 返回形状 | 状态是否真的变 |
| --- | --- | --- |
| `create_layer` | `{layer, message}`，重名抛 `err.bad_value` | `self.layers` 增加 |
| `list_layers` | `{count, layers[{name,hidden,frozen,wireColor,nodeCount}]}` | 按节点 `layer` 现算 |
| `assign_to_layer` | `{layer, moved, failures}`，层不存在时自动建（镜像 `mcpEnsureLayer`） | 节点 `layer` 改变 |
| `group_objects` | `{group, message}`，空选择抛 `err.no_selection` | 新增 `Group` 节点，成员 `parent` 指向它 |
| `ungroup_objects` | `{ungrouped, failures}` | 删组节点，成员 `parent` 清空 |
| `scene_save_as` | `{saved, pathKept, message}`，已存在且未 `confirm` 抛 `err.confirm_required` | 记录 `saved_path`，**不写盘** |
| `export_fbx` | `{path, preset, written, message}` | 记录 `exported_path`，**不写盘** |

另外修了一处"假场景比真 Max 更友好"的偏差：原来的 `_h_rename_object` 在重名时**抛错**，
而真实 MAXScript 是这样：

```maxscript
try ( n.name = newName ) catch()
mcpPair p "newName" n.name          -- 重名时这里还是旧名字
```

现在 FakeScene 也静默保留旧名并返回 `renamed: false`。这一条值得单独说：**假场景如果比
真机宽松，测试就是在用假象通过**——而重命名的形状正是这样漂移的。

### 新增的离线用例（`workflow_scene_test.py`，16 → 22 个）

| 用例 | 证明了什么 |
| --- | --- |
| `check_organisation_workflow` | 建层 → 归层 → 编组三步全 verified；层成员数（2）与 `parent` 靠**独立回读**确认，不走工作流验证器；重名建层被拒且步骤失败 |
| `check_ungroup_reports_what_it_did` | 编组后解组成功；对普通网格解组回执为空 → 失败，不再是 "ok" |
| `check_save_and_export_workflow` | 保存/导出两步 verified；导出路径写错 → `verification_failed`（说明回执不是"只要成功就行"） |
| `check_overwrite_guard_stops_the_workflow` | 目标文件已存在且未 `confirm` → 步骤失败、后续 `skipped`、`saved_path` 仍为空、`export_fbx` 一次都没被调用 |
| `check_unknown_verification_kind_is_refused` | 未知 validation kind 在执行前被拒，一次桥接调用都没发生 |
| `check_baseline_file_roundtrip` | 基线写盘 → 改场景 → 读回 diff；缺失/版本不符/JSON 损坏/非 `.json`/相对路径五种异常都明确失败 |

第 12 步的证据强度是分开记的：`group_objects` 之后用 `count` 验证对象数真的 +1（读回），
而"对象是否真的在那个层上"只有 `list_layers.nodeCount` 与 `get_object_info.layer` 两处
回读——离线场景里这两处是 FakeScene 自己维护的，真机是否一致仍属 R1 风险。
第 15 步同理：离线只能证明"回执与请求一致、覆盖保护有效"，不能证明磁盘上真多了一个
`.max` 文件。这两点都写进了 `docs/AGENT_WORKFLOW_CAPABILITY.md`。

## 5. 跨会话基线：`saveBaseline` / `baselineFile`

```text
scene_snapshot {"saveBaseline": "C:/work/before_modeling.json"}
... 关掉 Max、第二天再开 ...
scene_snapshot {"baselineFile": "C:/work/before_modeling.json"}   -> diff
```

文件格式固定，读到不认识的版本就拒绝：

```json
{ "schemaVersion": 1, "tool": "scene_snapshot", "createdAt": "2026-11-01T22:40:40",
  "tolerance": 0.0001, "nodeCount": 4, "document": { "nodes": {...}, "selection": [...] } }
```

| 情况 | 行为 |
| --- | --- |
| 非绝对路径 / 非 `.json` 后缀 | `invalid_arguments`（**防手误覆盖 `.max`**） |
| 父目录不存在 | 自动创建 |
| 文件缺失 | `snapshot_unavailable` + `reason: baseline_file_missing`，不静默新建 |
| JSON 损坏 / 无 `nodes` | `reason: baseline_file_corrupt` |
| 版本不符 | `reason: unsupported_snapshot_version`，回报 `found` / `expected` |
| 同时给 `baseline` 与 `baselineFile` | 文件优先 |

容差用**本次调用**的 `tolerance`，文件里的只作记录。这不是场景数据库：一次一个文件、
无索引、无历史；要管多份基线就自己命名多个文件。

## 6. 把工作流写进 MCP `instructions`

`server._instructions()` 的中英文都改成以工作习惯开头（zh 437 字符 / en 857 字符，
只写在影响工具选择的地方）：

- 改动前先 `scene_snapshot` 留基线，改完用它对比；
- 三步以上且有依赖的任务用 `workflow_run`，并给关键步骤声明 `verification`；
- **步骤"执行成功"不等于"目标达成"**——没有验证过就如实说未验证；
- `execute_maxscript` 的定位从"其余情况兜底"收窄为"只有现有工具确实做不到时才用，并说明原因"。

最后一条改的是既有文案。原来那句"其余情况用 execute_maxscript 兜底"实际上在鼓励绕过
现有工具能力，与"不通过任意 MAXScript 绕过"的原则相冲突。

新增用例 `check_unknown_verification_kind_is_refused` 之外的 `outcome_declaration_test.py`
（9 组静态用例）把判定规则逐条钉住，包括"`message` 不是证据"和"空回执不是成功"。

## 7. 恢复诊断，以及没做的那件事

`recovery` 原来只有 `scene_readable` + `object_count`，而"桥断了"和"场景读不出来"都表现为
`object_count: null`，调用方只能猜。现在：

| `diagnosis` | 判据 | `suggest_actions` | 意思 |
| --- | --- | --- | --- |
| `scene_readable` | 对象数读到了 | `["get_object_info"]` | 场景没事，是这步没达成目标 |
| `bridge_unreachable` | 读失败且是传输类错误 | `["bridge_status", "bridge_selftest"]` | Max 可能被关了/脚本被重置，先修桥 |
| `scene_unreadable` | 读失败但不是传输类 | `["bridge_selftest"]` | 桥能答话，但场景状态读不出来 |

三种状态各有一个静态用例（`check_recovery_diagnosis`）。

**没做 MCP log 通知**（Stage 3 建议里的"把逐步记录写进 MCP log 通知"）。理由：

1. 需要改 `tools/call` 的响应时序（在响应前插入 `notifications/message`），而当前环境没有
   真实的 MCP 客户端可以验证这个时序，改了等于拿客户端兼容性赌博。
2. 逐步记录本来就完整地在返回值里（每步 status/execution/verification/error/recovery），
   通知只是"边跑边看"的体验优化，不增加任何可验证性。

这条如实记在这里，而不是假装做了。

## 8. 测试结果

| 检查 | 结果 |
| --- | --- |
| 静态/离线测试 | 20 个文件全部通过（见下） |
| `scripts/verify.py` | `all integrity checks passed`（21 条既有 silent-catch 警告） |
| `scripts/test_e2e.py` | `all checks passed (8 bridge calls observed)` |
| `test/static/ms_check.py src/ms` | `0 problem(s)` |
| `compileall` | 通过 |
| `--selftest-python` | `all checks passed` |
| `--list-profiles` | 386 总数；core 58 / modeling 204 / lookdev 190 / animation 180 / pipeline 175 |
| `registration_sync_test` | **1 problem**：部署树漂移（基线即失败，见第 9 节） |

20 个文件：`batch_reliability`、`catalog_contract`、`core_contract`、
`core_tool_validation`、`error_protocol`、`image_result`、`object_reference`、
`runtime_contract`、`runtime_server`、`scene_runtime`、`scene_state`、`vision_result`、
`core_evidence_audit`、`doc_alignment_audit`、`offline_lint_helper`、`outcome_audit`、
`outcome_declaration_test`、`workflow_engine_test`、`workflow_scene_test`、
`offline_acceptance_test`。

测试函数：`workflow_scene_test.py` 22 个（Offline）、`workflow_engine_test.py` 18 个
（Static）、`outcome_declaration_test.py` 9 组（Static）。验收矩阵从 26 类扩到 37 类
（`docs/WORKFLOW_ACCEPTANCE.md`），**Runtime 仍是 0 类**。

## 9. 已知风险与限制

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| R1 无真实 Max 证据 | 所有结论只到 S/O 级；FakeScene 是"我们对 Max 的理解"的回声 | 按 `WORKFLOW_ACCEPTANCE.md` R1–R10 人工验收 |
| R2 部署漂移 | 本阶段改了 `mcp_objects.ms` / `mcp_lights.ms` / `mcp_shading.ms` / `mcp_system.ms`，用户机器上的桥接仍是旧的 | 合并后必须 `python scripts/install.py --yes`，否则 `mat_set_diffuse`/`light_create`/`execute_maxscript`/`rename_object`/`ungroup_objects` 在 core 档位仍会被判失败 |
| R3 仍有 74 个 mutating 工具声明不出结论 | 只返回 `{message}`，或在 `catch()` 里吞错 | `outcome_audit.py` 量化并列出清单；硬断言只覆盖"标准工作流用到的工具"，避免用一个不可能达成的大数字卡住门禁 |
| R4 `payload_field` 比回读弱 | 它只核对"工具说它写到了哪"，不核对"磁盘上有没有" | 验证器名字与文档都写明；真机上应用 `read_ok` 或外部检查补强 |
| R5 恢复诊断依赖错误分类 | `err.*` → 传输类的映射若不准，`bridge_unreachable` 会误判 | 分类表在 `errors.py`，有 `error_protocol_test` 守着 |
| R6 基线文件无锁 | 两个进程同时 `saveBaseline` 同一路径会互相覆盖 | 基线是可再生的缓存，不做文件锁；文档写明一次一个文件 |
| R7 层/组的证据强度不齐 | 组有 `count` 读回，层只有 `list_layers` 回读 | 已在能力矩阵与验收文档里分开标注 |

`git diff --check` 对 `mcp_shading.ms` 等 CRLF 文件仍会报 trailing whitespace 假警报；
本阶段新增行全部验证过：`mcp_objects.ms` / `mcp_lights.ms` / `mcp_shading.ms` 保持全 CRLF
（CRLF 计数 == LF 计数，无孤立 LF），`mcp_system.ms` 保持 LF + BOM。

## 10. Git commit

- `abbe95e` — `feat: make scene workflows the default and close the evidence gaps`
  （19 个文件改动 + 2 个新测试文件，+1003 / −49）
- 本报告单独提交为 `docs: add stage 4 workflow report`

## 11. 下一阶段的五项任务

1. **执行 R1–R10 真实 Max 验收**（仍是第一优先）。本阶段把清单扩到 37 类，
   但 Runtime 证据依然是 0；最关键的三条没变：R5（中途关 Max）、R9（无图只降级）、
   R10（逃逸仓不重试）。本阶段新增一条值得加的：**R11 —— 重名建层 / 重名重命名**，
   验证 `rename_object` 的 `renamed:false` 与真实 Max 行为一致。
2. **补完 74 个工具的结论声明**，但**不要**用统一的 `success:true` 兜底。正确做法是
   逐个把 `catch()` 吞掉的错误收集成 `failures`，先把"静默失败"消灭掉，再谈声明。
   建议从 `hide_objects` / `freeze_objects` / `set_units` 这类高频工具开始。
3. **`payload_field` 的真机补强**：在真实 Max 上验证 `saveMaxFile` 之后
   `getFiles "*.max"` 能看到文件，把"回执级"证据升级成"文件系统级"，再决定是否需要
   新的验证 kind。
4. **工作流的可观察性**（本阶段跳过的那件事）：如果将来有真实 MCP 客户端可测，
   再考虑 `notifications/message`；届时应做成默认关闭、可用配置开启，并保证响应时序
   在关闭时与现在完全一致。
5. **把 `scene_snapshot` 的基线接进 `workflow_run`**：目前工作流的前后快照仍走内存，
   跨会话的长任务（例如"今天建模、明天补材质"）拿不到统一的前后对比。可行的做法是给
   `workflow_run` 加 `saveBaseline` / `baselineFile` 透传，而不是再造一套。
