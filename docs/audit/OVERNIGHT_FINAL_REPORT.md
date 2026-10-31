# 3dsmax-mcp 夜间工程最终报告（Core Runtime Reliability & Automated Acceptance）

- 仓库：`D:\Workspace\MCP\3dsmax-mcp`
  （任务书给出的 `D:\Workspace\Dev\3dsmax-mcp` 在本机不存在，已按实际工作区执行）
- 日期：2026-10-31
- 分支：`main`
- 本轮代码提交：`c7e76882313b387b3e3ec10cd36467e1a834d8a8`
  `fix: strengthen core runtime reliability and validation`
- 运行环境：Windows + Python（离线）；**未启动 3ds Max，未连接 8765，未修改任何 `.max` 场景**
- 审计报告：`docs/audit/OVERNIGHT_AUDIT.md`

---

## 1. 本次完成情况

### 1.1 已完成阶段

| 阶段 | 内容 | 状态 |
| --- | --- | --- |
| A | 项目完整性与技术债审计（`docs/audit/OVERNIGHT_AUDIT.md`） | 完成 |
| B | 统一 Runtime 返回协议 + 稳定错误码（`errors.py`、`bridge.py`、`runtime.py`、`docs/ERROR_CODES.md`） | 完成 |
| C | 批量工具可靠性（`batch.py`，逐对象执行 / 对账 / 中断处理 / 去重 / 统计） | 完成 |
| D | 对象身份与引用（预解析、`ambiguous_object`、`stale_object_reference`、`object_ref` 诊断字段） | 完成（接口 + 离线测试；handle 稳定化未实现） |
| E | 视觉反馈链路（字节校验、MIME 嗅探、预算、路径白名单、嵌套 `_images`、`docs/VISUAL_FEEDBACK.md`） | 完成（离线；真实截图未验证） |
| F | 场景快照与差异（`scene_state.py`：snapshot / diff / transform_delta / compare_absolute） | 完成（核心字段；未新增查询工具） |
| G | 24 个无 live case Core 工具的静态与离线校验（`core_tool_validation_test.py`） | 完成（S/O 级证据，未冒充 M 级） |
| H | 安全性与稳定性审计（冻结见报告第 6 节与审计文档） | 完成（低风险项已修，架构项仅方案） |
| I | 离线端到端验收（`offline_acceptance_test.py`，真实 TCP） | 完成 |
| J | 文档更新（CORE_CONTRACT / ERROR_CODES / VISUAL_FEEDBACK / OVERNIGHT_ACCEPTANCE / CHANGELOG / 能力矩阵补充） | 完成 |
| K | 最终质量检查 + Git 提交 | 完成（1 项环境性失败，见 3.2） |

### 1.2 未完成 / 保留项

| 项 | 原因 | 记录位置 |
| --- | --- | --- |
| 真实 3ds Max 验收（L1–L24） | 环境中没有可安全操作的 Max 会话；禁止伪造 Runtime 结果 | `docs/OVERNIGHT_ACCEPTANCE.md` |
| MAXScript 侧 176 处静默 `catch()` 全面改造（A15） | 需要逐 handler 修改 19 个模块并在真实 Max 回归，属架构级改动 | 审计文档 A15 |
| node handle 作为稳定 `object_ref` | `getNodeByHandle`/`getHandleByAnim` 往返可靠性需真实 Max 证明；按约束不把未验证 handle 当 ID | 审计文档 D 段、`CORE_CONTRACT.md` §5 |
| 失败部署树同步（`registration_sync_test`） | 需要运行 `scripts/install.py` 覆盖用户 Max 安装目录，超出授权 | 本报告 3.2 |

### 1.3 修改的功能（用户可见变化）

1. **批量工具不再"全有或全无"**：`transform_object` / `clone_objects` / `delete_objects` 在可靠性模式下逐对象执行并 read-back；`select_objects` / `mat_assign` / `mod_add` 用 Max 回报的 `applied` / 选择集逐对象对账。
2. **部分成功不再伪装成成功**：任一对象失败 -> `success:false` + `failures[].kind=partial_success` + `summary{total,succeeded,failed,skipped,verified}`。
3. **同名/失效引用不再误伤对象**：`ambiguous_object`、`stale_object_reference`、`invalid_object_reference`。
4. **错误码稳定**：MAXScript 的 `err.*` 不再被丢弃；传输错误带 `bridge_*` + `retryable`。
5. **"未验证"不再等同"验证失败"**：`verification.performed=false` 时 `passed=null`，`changed` 可为 `null`。
6. **图片链路可信**：base64 严格校验、文件头嗅探、MIME 以字节为准、大小预算、目录白名单、拒绝把"仅路径"当图片。
7. **参数校验前置**：`enum` / `minimum` / `maximum` / `minItems` 在 Python 层拦截，错误码 `invalid_arguments`。
8. **写盘工具标注修正**：`scene_save` 改为 mutating；`scene_save_as` 覆盖已存在文件需 `confirm:true`，并实现 `keepPath`。

---

## 2. 代码修改

### 2.1 新增文件

| 文件 | 原因 | 内容 |
| --- | --- | --- |
| `src/python/maxmcp/errors.py` | 三层错误信息不一致，MAXScript kind 被丢弃 | `ErrorSpec`/`ERROR_SPECS`、`MAX_ERROR_MAP`、`BRIDGE_KIND_MAP`、`classify`/`error`/`from_exception`/`retryable`/`is_transport_failure` |
| `src/python/maxmcp/batch.py` | 批量工具缺少逐对象结果 | `BatchExecutor`：预解析、逐对象执行、read-back 校验、对账、去重、中断、聚合信封 |
| `src/python/maxmcp/scene_state.py` | 缺少可比较的场景状态 | 节点快照、集合快照、差异（added/removed/modified/unknown）、变换差异、绝对比较、摘要 |
| `test/static/fake_scene.py` | 需要与 MAXScript 命令同构的离线场景 | 实现 12 条命令 + 4 个故障注入开关，明确标注为假场景 |
| `test/static/batch_reliability_test.py` | 阶段 C/I 证据 | 24 个检查：部分/全部失败、空数组、单对象、重复、歧义、过期、传输中断、删除、复制、无效果、绝对变换、对账、服务集成 |
| `test/static/object_reference_test.py` | 阶段 D 证据 | 同名、删除后引用、改名竞态、handle 拒绝、选择集不得兜底 |
| `test/static/scene_state_test.py` | 阶段 F 证据 | 完整/部分快照、跨对象差异、缺失字段、容差、欧拉角环绕 |
| `test/static/error_protocol_test.py` | 阶段 B 证据 | kind 映射表、真实 `_parse`、非法 JSON、空行、断线、wire 幂等、空 payload、错误码文档一致性 |
| `test/static/core_tool_validation_test.py` | 阶段 G 证据 | 24 个工具：注册、必填、类型、枚举、边界、只读/危险标注、参数拦截 |
| `test/static/offline_acceptance_test.py` | 阶段 I 证据 | 真实 TCP 桩桥 + 全链路 dispatch，覆盖传输/运行时/批处理/引用/图片 |
| `docs/ERROR_CODES.md` | 错误码权威说明 | 全部 41 个码 + MAXScript kind 映射 + 兼容性变化表（由 `error_protocol_test.py` 校验文档无缺漏） |
| `docs/VISUAL_FEEDBACK.md` | 视觉链路说明 | 链路、校验规则、配置、限制、测试覆盖 |
| `docs/OVERNIGHT_ACCEPTANCE.md` | 验收标准 | 离线命令清单、证据等级 S/O/M、真实 Max 清单 L1–L24 |
| `docs/audit/OVERNIGHT_AUDIT.md` | 阶段 A | 架构图、链路、18 项问题、高风险位置、缺失测试、修复顺序 |

### 2.2 修改文件

| 文件 | 修改原因 | 修改内容 |
| --- | --- | --- |
| `src/python/maxmcp/bridge.py` | kind 丢失、断开语义错误 | `_parse` 用 `errors.classify` 生成 `code` 并保留 `max_kind`；新增 `BridgeDisconnected`；`import errors` |
| `src/python/maxmcp/runtime.py` | 未验证/空 payload 语义 | `OperationResult.warnings` 改为结构化条目；`empty_result` 警告；`verification.passed` 未验证时为 `None`；`_bridge_failure` 走统一分类并带 stage；`build_batch_result` 修复未验证语义与 `KeyError`；`resolve_object_refs` 使用新码并返回 `object_ref` |
| `src/python/maxmcp/server.py` | 参数校验、批处理接入、图片安全 | 接入 `BatchExecutor` 与执行路径分流；`_coerce` 增加 enum/上下界/数组长度；`_coerce_array`/`_check_bounds`/`_check_enum`；错误信封加 `retryable`；图片：`_sniff_image_mime`/`_validate_image_bytes`/`_allowed_image_roots`/`_is_within`/`_collect_images`、8 MiB/12 MiB 预算；清理 3 个未使用导入 |
| `src/python/maxmcp/wire.py` | 二次解码乱码 | `from_wire` 对含 >U+00FF 的字符串恒等返回 |
| `src/python/maxmcp/config.py` | 图片目录可配置 | 新增 `image_roots` + `MAXMCP_IMAGE_ROOTS` 解析 |
| `src/python/maxmcp/catalog/core.py` | 安全标注与参数契约 | `scene_save` -> mutating；`scene_save_as` 新增 `confirm`，更新 `keepPath` 说明 |
| `src/python/maxmcp/catalog/shading.py` | 参数边界 | `mat_list.limit`（1..5000）/`offset`（>=0） |
| `src/ms/mcp_scene.ms` | 覆盖保护 + 参数一致性 | `scene_save_as`：已存在文件且无 `confirm` -> `err.confirm_required`；实现 `keepPath`；返回 `pathKept` |
| `test/static/image_result_test.py` | 阶段 E 证据 | 从 3 个检查扩到 17 个：PNG/JPEG/缺文件/空文件/MIME 纠正/损坏/超限/越权/`..`/内联 base64/非法 base64/预算/嵌套信封/image block 序列化/默认根目录 |
| `test/static/vision_result_test.py` | 与新校验一致 | 用真实文件头替换 3 字节假数据；断言 MIME 纠正与 `image_errors` |
| `test/static/runtime_contract_test.py` | 契约变更 | 新错误码、`object_ref`、未验证语义 |
| `test/static/runtime_server_test.py` | 契约变更 | `not_running` -> `bridge_not_running` + `retryable` |
| `docs/CORE_CONTRACT.md` | 阶段 B/C/D/F/J 契约 | 重写：执行路径、两种信封、批量语义、read-back 来源表、身份策略、快照、错误边界、证据边界 |
| `docs/CORE_CAPABILITY_MATRIX.md` | 阶段 J 覆盖情况 | 追加"夜间任务补充证据"章节（不改历史基线表） |
| `docs/CHANGELOG.md` | 变更记录 | 新增 Added/Changed 条目 |

### 2.3 明确未做的事

- 未新增任何 MCP 工具（384 个工具数不变，Core 仍为 56）。
- 未删除/弱化既有测试；`runtime_contract_test`、`runtime_server_test` 只更新了**契约变更后的期望值**（kind 改名、未验证语义），断言数量增加。
- 未使用 `git reset --hard` / `git clean` / 强制推送；未启动或关闭 3ds Max；未触碰 `.max` 文件。

---

## 3. 测试报告

### 3.1 通过的检查

| 测试 | 命令 | 结果 |
| --- | --- | --- |
| 运行时服务契约 | `python test/static/runtime_server_test.py` | PASS |
| 场景运行时 | `python test/static/scene_runtime_test.py` | PASS |
| 视觉结果归一化 | `python test/static/vision_result_test.py` | PASS |
| Core 契约（580 组 payload 用例） | `python test/static/core_contract_test.py` | PASS |
| Core 证据审计 | `python test/static/core_evidence_audit.py` | PASS |
| 图片链路（17 组） | `python test/static/image_result_test.py` | PASS |
| 目录契约（384 工具 schema/preset） | `python test/static/catalog_contract_test.py` | PASS |
| 文档一致性 | `python test/static/doc_alignment_audit.py` | PASS |
| Runtime 适配器契约 | `python test/static/runtime_contract_test.py` | PASS |
| 批量可靠性（新增，24 个检查） | `python test/static/batch_reliability_test.py` | PASS |
| 对象身份（新增，7 个检查） | `python test/static/object_reference_test.py` | PASS |
| 场景快照/差异（新增，7 个检查） | `python test/static/scene_state_test.py` | PASS |
| 错误协议（新增，14 个检查） | `python test/static/error_protocol_test.py` | PASS |
| Core 工具校验（新增，8 个检查 / 24 工具） | `python test/static/core_tool_validation_test.py` | PASS |
| 离线端到端验收（新增，17 个检查） | `python test/static/offline_acceptance_test.py` | PASS |
| 静态完整性（语法、注册、文档、未使用代码） | `python scripts/verify.py` | PASS（0 violation / 21 warning） |
| 端到端脚本（stdio + mock bridge） | `python scripts/test_e2e.py` | PASS |
| MAXScript 静态语法 | `python test/static/ms_check.py src/ms` | PASS |
| Python 语法 | `python -m compileall -q src/python test/static scripts` | PASS |
| MCP 自检 | `python -m maxmcp --selftest-python` | PASS |
| 工具数一致性 | `python -m maxmcp --list-profiles` | 384 工具 / core 56（未变） |

### 3.2 失败的检查（唯一一项，环境性）

| 测试 | 命令 | 结果 | 分类 | 说明 |
| --- | --- | --- | --- | --- |
| 部署树同步 | `python test/static/registration_sync_test.py` | FAIL | **环境缺陷（范围外）** | 用户机器上已安装的 Max 脚本（ENU/CHS 各 4 个文件）与仓库 `src/ms` 不一致，属基线状态（本轮开始前即失败）。修复需要运行 `scripts/install.py` 覆盖用户 3ds Max 安装目录，属对用户环境的写入，本轮未授权执行。 |

其余失败分类（代码缺陷 / 依赖缺失 / 需要真实 Max / 测试基础设施）：**无**。

### 3.3 测试过程中的真实问题（已修）

1. `_envelope` 在"无对象列表"路径把 `success` 算成 `False`（空 rows）——改为显式 success。
2. `build_batch_result` 对缺少 `verified` 字段的行抛 `KeyError`（既有 bug）——改为 `row.get`。
3. `BridgeTimeout.kind="timeout"` 未映射为稳定码——补 `BRIDGE_KIND_MAP`。
4. 未识别回包结构（无 `applied` / 无选择集）时会把对象误判为失败——改为"未验证 + `reconcile_unavailable` 警告"，只在能证明时判定失败。

---

## 4. Core 工具状态

严格区分三类证据（S=静态、O=离线集成、M=真实 Max）：

| 指标 | 数量 | 说明 |
| --- | --- | --- |
| Core 工具总数 | **56** | 与基线一致，未增减 |
| MCP 工具总数 | **384** | 未新增工具 |
| 有静态测试（S）的工具 | **56 / 56** | `catalog_contract_test.py`（schema/preset/类型）+ `core_evidence_audit.py`；其中 24 个缺口工具另有 `core_tool_validation_test.py` 的注册/必填/枚举/边界/安全标注校验 |
| 有离线集成测试（O，语义级）的工具 | **8** | 6 个批量工具（逐对象/对账语义，`batch_reliability_test.py`）+ 2 个 vision 工具（图片链路，合成字节，`image_result_test.py` / `offline_acceptance_test.py`） |
| 有离线传输级测试（O，仅传输与信封）的工具 | 全部 | `error_protocol_test.py` / `offline_acceptance_test.py`（真实 TCP） |
| 有真实 Max Runtime 验证（M）的工具 | **32** | 来自既有 live matrix 的历史证据，本轮**未重新执行** |
| 尚未有真实 Max 验证的工具 | **24** | 21 个 `BLOCKED` + 3 个仅 `OFFLINE_TESTED`（`delete_objects` / `get_selection` / `mat_list` 等），与本轮新增的 24 缺口清单一致 |

> 24 个缺口工具（本轮静态/离线覆盖，仍待 M 级）：`bridge_capabilities`、`bridge_ping`、
> `create_circle`、`create_cone`、`create_geosphere`、`create_plane`、`create_pyramid`、
> `create_torus`、`create_tube`、`delete_objects`、`execute_maxscript`、`get_selection`、
> `mat_list`、`mod_symmetry`、`mod_turbosmooth`、`poly_chamfer_edges`、`poly_connect_edges`、
> `poly_get_selection`、`poly_get_stats`、`poly_inset_faces`、`poly_weld_vertices`、
> `scene_open`、`scene_save`、`scene_save_as`。

---

## 5. 视觉反馈状态

| 项目 | 状态 | 证据 |
| --- | --- | --- |
| 图片处理（byte 级） | 正常 | `image_result_test.py`：PNG/JPEG、空文件、损坏、MIME 纠正、超限、越权、预算 |
| MCP Image Content Block | 正确 | `{"type":"image","data":<base64>,"mimeType":...}`；文本块与图片块并存；JSON 序列化往返通过（`image_result_test.py`、`offline_acceptance_test.py`） |
| 仅返回路径而不返回图片 | 已消除 | 路径必须可解析到白名单目录且字节通过嗅探，否则进 `image_errors` |
| runtime 信封内图片丢失 | 已修复 | `_collect_images` 递归 `data` / `result` |
| 真实 Max 视口截图 | **未验证** | 需要真实 Max（验收项 L15–L18） |
| 多视图 / 渲染预览 | **未验证** | 同上 |
| 真实截图字节与文件头一致性 | **未验证（风险）** | 若 Max 侧输出格式与嗅探不符，会被判 `corrupt_image`；这是"宁可报错"的有意设计 |

**禁止事项遵守情况**：测试中未使用任何本地图片冒充 3ds Max 视口截图；所有图片均为合成文件头 + 明确标注的离线 fixture。

---

## 6. 风险清单

### 6.1 剩余 Bug / 已知缺陷

| # | 风险 | 影响 | 缓解 |
| --- | --- | --- | --- |
| R1 | 其他 350+ 个 MAXScript handler 仍有 176 处静默 `catch()` | 单节点失败不可见（批量 6 个工具已由 Python 兜住） | 列入下一阶段第 1 项 |
| R2 | 逐对象模式（transform/clone/delete）产生多条 undo 记录 | 用户按一次 Ctrl+Z 只撤销一个对象 | 仅在可靠性模式下启用；文档标注；下一阶段可加 `asOneUndo` 包裹 |
| R3 | `mat_assign` 的 `changed` 为 `null`（无逐对象 read-back） | 客户端无法判断材质是否真的变化 | 需要 Max 侧 read-back 或 `get_object_info.material` 二次读取 |
| R4 | `transform_object` 绝对旋转（axis-angle）只校验"确实转动了" | 角度错误可能漏检 | 需要读回 quaternion 或 euler 统一口径 |
| R5 | 图片校验只做文件头，不完整解码 | 截断图片仍可能通过 | 可选引入 Pillow（新依赖，需决策） |
| R6 | `execute_maxscript` 仍是任意代码执行；`scene_open` 可加载任意路径 | 提示注入/误操作导致破坏 | 架构层方案：白名单、只读模式、审计日志；需产品决策 |
| R7 | bridge 为单连接单锁 | 长渲染/烘焙会阻塞所有工具调用 | 下一阶段：请求级取消 + 长任务通道 |

### 6.2 需要人工验收

- `docs/OVERNIGHT_ACCEPTANCE.md` 的 **L1–L24**（批量逐对象、read-back 字段、保存确认、截图、错误与超时、回归 live matrix）。
- 特别是 L3（同名对象）、L5（部分对象不可赋值）、L11–L13（保存/覆盖/keepPath）、L15–L18（截图）、L22（中文错误不乱码）。

### 6.3 环境风险

- `registration_sync_test` 失败说明**用户 Max 里的脚本是旧版本**。在用户执行 `python scripts/install.py` 之前，真实 Max 中的 `scene_save_as` 不会带 `confirm` 保护、bridge 也不会返回 `err.*` 之外的新增字段。这是发布前必须提醒用户的一步。

---

## 7. Git 状态

| 项目 | 值 |
| --- | --- |
| 分支 | `main` |
| 起始 HEAD | `98e6499826ee1206b686c0d93069d97cdea4e844` |
| 本轮 Commit | `c7e76882313b387b3e3ec10cd36467e1a834d8a8` |
| Commit 标题 | `fix: strengthen core runtime reliability and validation` |
| 提交文件数 | 29（10 个源码/MAXScript + 9 个测试 + 10 个文档，4474 insertions / 142 deletions） |
| 未提交修改 | 仅本报告（`docs/audit/OVERNIGHT_FINAL_REPORT.md`，单独提交） |
| 用户原有修改 | 开始时工作树干净，无用户未提交修改被混入 |
| 破坏性命令 | 未使用 |

---

## 8. 下一阶段建议（按优先级）

1. **MAXScript 侧失败可见化**：把 `try(...) catch()` 改为收集 `#(nodeName, message)` 并从 `applied`/`failures` 返回；先用 `mod_add`/`mat_assign` 做样板，再推广到几何与 poly 模块，最后跑真实 Max 回归（消除 R1）。
2. **真实 Max 验收闭环**：执行 L1–L24，生成新的 `docs/LIVE_MATRIX.md`，把 24 个 `BLOCKED` 工具逐个转成 `RUNTIME_VERIFIED` 或记录失败原因（消除第 4 节的最大证据缺口）。
3. **批量操作 undo 原子性**：在 `mcp_net.ms` 的 dispatch 层支持整批 `undo ... begin/accept`，或提供 `atomic=true` 参数，让逐对象模式只产生一条 undo 记录（消除 R2）。
4. **长任务与并发**：引入请求级取消 + 独立通道，避免渲染/烘焙阻塞所有工具；同时把 bridge 超时拆成"连接超时/执行超时"（消除 R7）。
5. **图片质量与体积策略**：可选 Pillow 完整解码校验、服务端缩略图（保留原图）、以及真实 Max 截图格式实测；同时在 `vision_capture` 输出中附带"截图时间/视口/分辨率"以便 Agent 判断新鲜度（消除 R5，补齐视觉 M 级证据）。

---

## 9. 附：本轮命令与结果摘要

```text
PASS  test/static/runtime_server_test.py
PASS  test/static/scene_runtime_test.py
PASS  test/static/vision_result_test.py
PASS  test/static/core_contract_test.py
PASS  test/static/core_evidence_audit.py
PASS  test/static/image_result_test.py
PASS  test/static/catalog_contract_test.py
PASS  test/static/doc_alignment_audit.py
PASS  test/static/runtime_contract_test.py
PASS  test/static/batch_reliability_test.py
PASS  test/static/object_reference_test.py
PASS  test/static/scene_state_test.py
PASS  test/static/error_protocol_test.py
PASS  test/static/core_tool_validation_test.py
PASS  test/static/offline_acceptance_test.py
PASS  scripts/verify.py
PASS  scripts/test_e2e.py
FAIL  test/static/registration_sync_test.py   # 环境：已部署 Max 脚本与仓库不一致（基线即失败）
```

`scripts/verify.py` 摘要：

```text
MAXScript modules: 19, registered commands: 353
catalog tools        : 384 in 8 categories
docs/tools.txt: 384 entries, every name resolves to the catalog
offline lint: 49 python file(s), 20 maxscript file(s), 384 tool(s)
              -- 0 violation(s), 21 warning(s)   # server.py 的 3 个未使用导入已清理
                                              # 剩余 warning 均为既有文件（doctor.py 等）
all integrity checks passed
```
