# 离线验收与真实 3ds Max 验收清单

本文件定义"什么算已验证"。原则：**静态测试 ≠ 离线集成测试 ≠ 真实 Max 验证**，
三者不能互相冒充。

## 1. 离线验收（无需 3ds Max，可重复运行）

```bash
python test/static/error_protocol_test.py
python test/static/batch_reliability_test.py
python test/static/object_reference_test.py
python test/static/scene_state_test.py
python test/static/image_result_test.py
python test/static/vision_result_test.py
python test/static/core_tool_validation_test.py
python test/static/offline_acceptance_test.py
python test/static/runtime_contract_test.py
python test/static/runtime_server_test.py
python test/static/scene_runtime_test.py
python test/static/core_contract_test.py
python test/static/catalog_contract_test.py
python test/static/core_evidence_audit.py
python test/static/doc_alignment_audit.py
python test/static/workflow_engine_test.py
python test/static/workflow_scene_test.py
python scripts/verify.py
python scripts/test_e2e.py
```

| 组 | 覆盖 | 测试文件 |
| --- | --- | --- |
| Bridge | 未启动、连接失败、超时、非法 JSON、空回包、MAXScript 错误、中途断开 | `offline_acceptance_test.py`、`error_protocol_test.py` |
| Runtime | 成功、失败、部分成功、参数错误、超时、验证未执行、验证失败 | `scene_runtime_test.py`、`error_protocol_test.py`、`offline_acceptance_test.py` |
| Batch | 空数组、单对象、多对象、部分失败、全部失败、重复对象、传输中断 | `batch_reliability_test.py` |
| Object Reference | 正常、不存在、重名、过期、非法 | `object_reference_test.py`、`runtime_contract_test.py` |
| Visual | 正常 PNG/JPEG、不存在、损坏、MIME 错误、超限、MCP image block | `image_result_test.py`、`vision_result_test.py` |
| 工作流编排 | 步骤顺序/依赖/失败策略、验证三态、重试拒绝、快照与 diff、失败恢复 | `workflow_engine_test.py`、`workflow_scene_test.py`（详见 `docs/WORKFLOW_ACCEPTANCE.md`） |
| 工具契约 | 386 工具 schema/preset/类型/枚举、24 个无 live case 工具 | `catalog_contract_test.py`、`core_tool_validation_test.py` |

`offline_acceptance_test.py` 使用**真实 TCP**（127.0.0.1 随机端口）和一个按剧本应答的
桩桥接，跑通 `dispatch -> server -> MaxBridge -> socket`，所以分帧、超时、断线都是真实
路径；它不模拟 3ds Max 的场景语义（那部分由 `fake_scene.py` 承担，并且明确标注为
离线假场景）。

## 2. 真实 3ds Max 验收清单（待人工执行）

以下项目**本轮没有执行**，因为环境里没有可安全操作的 Max 会话。每项都给出判定标准。

### 2.1 批量可靠性

| # | 步骤 | 期望 |
| --- | --- | --- |
| L1 | `create_box` 建 3 个盒子，然后 `transform_object{objects:[A,B,Missing]}` | 返回 `success:false`、`summary{3,2,1}`、Missing 行 `object_not_found`；A/B 真的移动了 |
| L2 | 同上但三个对象都存在 | `success:true`，`verification.passed:true`，每行 `changed:true` |
| L3 | 建两个同名对象（Max 允许），`delete_objects{objects:[名称]}` | `ambiguous_object`，**两个对象都还在** |
| L4 | `delete_objects` 后立刻 `transform_object` 同一个名字 | `object_not_found`，不误伤其他对象 |
| L5 | `mat_assign{objects:[A,B], material:"X"}`，其中 B 是冻结/不可赋值对象 | B 行 `not_applied`，整体 `success:false` |
| L6 | `select_objects{mode:"replace"}` 传 3 个名字 | 3 行均 `verified:true`；若 Max 少选了某个，该行 `not_applied` |
| L7 | `transform_object` 用相对 `[0,0,0]` | `changed:false`、`success:true`（合法的空操作） |

### 2.2 read-back 字段

| # | 步骤 | 期望 |
| --- | --- | --- |
| L8 | `find_objects{name, exact:true}` 对任意对象 | 返回 `objects[0]` 含 `handle/position/rotation/scale/modifiers` |
| L9 | `get_object_info` 对已删除对象 | `object_not_found`（供 batch 判定 `stale_object_reference`） |
| L10 | 含修改器的对象做 `mod_add` | 每行 `changed:true`，`modifiers` 长度增加 |

### 2.3 场景保存

| # | 步骤 | 期望 |
| --- | --- | --- |
| L11 | `scene_save_as{path: 已存在的 .max}` | `confirmation_required`，原文件时间戳不变 |
| L12 | 同上 + `confirm:true` | 覆盖成功，返回 `saved` |
| L13 | `scene_save_as{path: 新路径, keepPath:false}` | 写成功，`maxFilePath` 仍是原路径 |
| L14 | `scene_save` | 写盘成功，工具被标记为 mutating（非 readOnlyHint） |

### 2.4 视觉反馈

| # | 步骤 | 期望 |
| --- | --- | --- |
| L15 | `vision_capture{max_edge:800}` | 返回 1 个 `image` block，`mimeType` 为 jpeg/png，客户端能渲染 |
| L16 | `vision_views{views:["perspective","front"]}` | 2 个独立 image block，label 正确 |
| L17 | 同上，观察文本块 | `images[].base64Chars` 与实际大小一致，无 `image_errors` |
| L18 | 视口被遮挡/最小化时 `vision_capture` | 要么成功，要么返回明确错误（不得返回占位图） |

### 2.5 错误与超时

| # | 步骤 | 期望 |
| --- | --- | --- |
| L19 | 加载桥接后关闭 Max，再调用任意工具 | `bridge_not_running`（可重试），MCP `isError:true` |
| L20 | 渲染/烘焙长任务，把 `MAXMCP_TIMEOUT` 设为 5s | `bridge_timeout`，且 Max 侧任务行为可解释 |
| L21 | `execute_maxscript{code:"1/0"}` | `max_runtime_error` 或 `max_command_failed`，含 Max 原始异常文本 |
| L22 | 中文版 Max 下触发失败 | 错误文本是正常中文（不是乱码） |

### 2.6 回归

| # | 步骤 | 期望 |
| --- | --- | --- |
| L23 | 运行 `test/live/live_matrix.py` | 既有 43 条 live case 仍全部通过 |
| L24 | `python scripts/doctor.py`、`python scripts/max_health.py` | 无新增告警 |

执行完毕后请把结果记录在 `docs/LIVE_MATRIX.md` 或本文件末尾，注明 Max 版本、日期、
以及每项的 PASS/FAIL。

## 3. 证据等级约定

| 等级 | 含义 | 例子 |
| --- | --- | --- |
| S | 静态检查（语法/schema/注册/文档） | `verify.py`、`core_tool_validation_test.py` |
| O | 离线集成（真实 Python 路径 + 假场景/桩桥） | `batch_reliability_test.py`、`offline_acceptance_test.py` |
| M | 真实 3ds Max 验证 | 上面的 L1–L24 |

本轮交付的结论只到 S / O。任何涉及"场景真的被改对了""截图真的是当前视口"的结论，
都必须等 M 级证据。
