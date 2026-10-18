# 增量开发计划：修改器系统与多边形建模扩展

> 项目：3dsmax-mcp-plugin ｜ 目标版本：3ds Max 2020（兼容至最新版）
> 日期：2026-10-18 ｜ 状态：计划已提交，实施中
>
> **迁移注记（2026-10-18 晚）**：本项目已整合至 `D:\Workspace\Dev\3dsmax-mcp`，
> 下表“工作区”一行及各处 `D:\Sandbox\3dsmax-mcp-plugin\` 路径已并入新项目的
> `test/`（diag 脚本）、`backup/`、`docs/`；源码真相在 `src/ms` 与 `src/python/maxmcp`。

---

## 一、现状盘点（已完成的接口验证）

### 1.1 系统架构

| 层 | 位置 | 说明 |
|---|---|---|
| MCP 服务（Python） | `C:\Users\Vino\AppData\Local\3dsmax-mcp\maxmcp\` | 无第三方依赖，`catalog/` 下按域拆分工具声明 |
| MAXScript 桥接 | `%LOCALAPPDATA%\Autodesk\3dsMax\2020 - 64bit\{ENU,CHS}\scripts\3dsmax-mcp\` | 纯 MAXScript，TCP 8765，换行分隔 JSON |
| 启动加载器 | 上述脚本树 `startup\3dsmax-mcp-bridge.ms` | ENU/CHS 各一份，随 Max 启动自动加载 |
| 工作区 | `D:\Sandbox\3dsmax-mcp-plugin\` | diag 诊断脚本、backup 备份、max 源码副本 |

**通信协议**：`{"id":N,"method":"<命令>","params":{...},"lang":"zh"}\n` → `{"id":N,"ok":true,"result":{...}}\n`。
线缆层为纯 ASCII（中文按 ANSI 字节转 `\u00XX`），见 `mcp_json.ms` / `wire.py`。

**工具注册机制**：Python 侧 `catalog/*.py` 用 `tool()` DSL 声明（双语描述）；MAXScript 侧各模块以
`mcpRegister "<命令>" <handler>` 注册；`mcp_bridge.ms` 的 `mcpBridgeModules` 列表决定加载顺序。
特定修改器工具（如 `mod_turbosmooth`）是 `mod_add` 的薄包装：Python 预设 `modifier` 类名，
额外顶层参数由 MAXScript 作为修改器属性应用。

**撤销机制**：`mcpDispatch` 按注册时的 `undoable` 标志包 `theHold`；失败自动 Cancel。
查询类命令注册为 `undoable:false`。

**CHS/ENU 同步**：两套脚本树逐字节相同（md5 已验证）。改动必须同步复制。

### 1.2 已有能力（禁止重复实现）

**修改器（`mcp_modifiers.ms`，13 个命令 + 19 个特定修改器包装）**
- 通用：`mod_add` / `mod_remove` / `mod_list` / `mod_get_params` / `mod_set_param` / `mod_set_params`
  / `mod_enable` / `mod_disable` / `mod_reorder` / `mod_rename` / `mod_get_gizmo_info`
  / `mod_set_sub_object_selection`
- 特定：TurboSmooth、Bend、Taper、Twist、Noise、FFD 2x2x2/3x3x3/4x4x4、Shell、Symmetry、
  Displace、Relax、Subdivide、Extrude、Lathe、Sweep、PathDeform、WeightedNormals、
  Edit_Poly、Edit_Normals、Smooth

**多边形建模（`mcp_poly.ms`，43 个命令）**
- 转换：`convert_to_editable_poly` / `convert_to_editable_mesh` / `convert_to_nurbs` / `collapse_stack`
- 查询：`poly_info` / `poly_get_verts` / `poly_get_faces` / `poly_get_edges` / `poly_get_stats`
- 顶点：set_vertex / move_vertices / weld_vertices / target_weld / chamfer_vertices / remove_vertices
- 面：select_faces / extrude_faces / bevel_faces / inset_faces / bridge_faces / cap_holes /
  flip_faces / delete_faces / assign_material_id / set_smoothing / detach_faces
- 边：chamfer_edges / connect_edges / extrude_edges / loop_select / ring_select / slice
- 整体：triangulate / quadify / subdivide / optimize / relax / auto_smooth / unify_normals / make_planar

### 1.3 缺口清单（本次增量）

| 需求（任务书） | 现状 | 处置 |
|---|---|---|
| `modifier_list/add/get_params/set_params/remove/reorder` | 已存在（`mod_*` 命名） | **不重复**，沿用现有命名规范 |
| `modifier_toggle` | 只有 enable/disable 两个命令 | 新增 `mod_toggle` |
| `modifier_collapse` | `collapse_stack` 整栈塌陷、无确认机制 | 新增 `mod_collapse`（需 `confirm:true`） |
| Chamfer 修改器 | 只有 Edit Poly 倒角操作 | 新增 `mod_chamfer` 包装 |
| 元素数量查询 | 无 | 新增 `poly_get_elements` |
| 子对象选择**查询** | 只有设置（`poly_select_faces` 限面） | 新增 `poly_get_selection` |
| 子对象选择**设置**（点/边/面/边界/元素通用） | 面以外缺失 | 新增 `poly_select` |
| Graphite（Loop/Ring/Swift Loop/Cut/QuickSlice） | 未调查 | 本轮只做能力矩阵调研 |

### 1.4 环境阻塞（重要）

本机 3ds Max **自 2026-10-17 23:42 起无法启动新实例**（先于本会话存在；时间线以
Windows 应用程序事件日志 Event ID 1000 与 CrashDumps 转储为准，10:54 的首次崩溃详见下）：

- 症状：`3dsmax.exe` 启动即崩，异常码 `0xC0000409`（`ucrtbase.dll!abort`）。
- 事件日志（Event ID 1000）窗口内共 18 次崩溃（10-17 10:54:44 起，10-18 00:00–01:29
  共 14 次）：首次 **2026-10-17 10:54:44**，随后 23:42、23:56、23:59；
  `%LOCALAPPDATA%\CrashDumps` 留有 10 个 `3dsmax.exe` 全量转储
  （2026-10-18 00:07–01:29，共约 2.1 GB）。
- 10-17 10:54 首次崩溃时用户旧实例仍在运行，疑单实例重复启动所致；无实例状态下的
  连续崩溃始于 10-17 23:42（D5 根因未定）。
- 已排除：MCP 桥接脚本（全新配置同样崩溃）、用户配置（移走 ini/整个配置目录均崩溃）、
  安装目录文件（全部为 2019 原始文件）、第三方注入 DLL（转储模块列表干净）。
- 崩溃转储栈含 `stdplugs\EPoly.dlo` 帧（可能是噪声，真实帧为 `abort` 的 noreturn 路径）。
- 今天 9:12 启动的实例（空场景）运行 14 小时后被我关闭，此后所有启动尝试均崩溃。
- `3dsmaxbatch.exe` 同样失败（内部转 `3dsmax.exe`，同样崩溃）。

**影响**：本轮所有新增工具可完成实现与静态检查，但**无法进行真实 Max 实例实测**。
测试脚本将完整编写并就绪，待 Max 环境恢复后一键运行。此为未解决问题，需用户在本机修复
（建议：重启机器后重试；若仍旧，修复/重装 3ds Max 2020 或检查显卡驱动——本机为
NVIDIA + Intel 混合显卡）。

---

## 二、实施方案

### 2.1 新增 MAXScript 模块 `mcp_modeling_ext.ms`

放在 `mcp_poly.ms` / `mcp_modifiers.ms` 之后加载（保持桥接模块化，不塞进单个文件）。
全部遵循现有代码风格：`try/catch` 逐对象处理、`applied/failures` 汇总、操作后重置
`subobjectLevel`、查询类不包 undo。

| 命令 | 行为 | 防护 |
|---|---|---|
| `mod_toggle` | 翻转 `m.enabled`，返回翻转后状态（回读验证） | 修改器不存在 → `msg.no_modifier` |
| `mod_collapse` | 整栈塌陷（`collapseStack`）；**必须 `confirm:true`** | confirm 缺失/非真 → 拒绝并说明；塌陷前检查有修改器 |
| `poly_get_selection` | 回读子对象层级与各级选中索引/数量（分页） | 非 poly 自动转换；逐级 try/catch |
| `poly_select` | 设置子对象层级 + 选中集合（verts/edges/faces/borders/elements） | 索引越界忽略；无效层级报错 |
| `poly_get_elements` |  flood-fill 统计元素数量与每元素面数 | `getElementsUsingFace` 不可用时明确报错 |

同时在 `mcp_bridge.ms` 的 `mcpBridgeModules` 注册新模块；ENU/CHS 双树同步。

### 2.2 Python 目录更新（`catalog/modeling.py`）

新增 6 个工具（双语描述、遵循 `mod_*`/`poly_*` 命名）：
`mod_toggle`、`mod_collapse`、`mod_chamfer`（`_mod` 包装，类名 Chamfer）、
`poly_get_selection`、`poly_select`、`poly_get_elements`。
`mod_chamfer` 参数：amount、segments、openEdges、smoothOnIntersections（按类属性透传，
类不存在时由 `mcpEnsureClass` 返回明确错误）。

### 2.3 测试

- 静态：`diag/ms_check.py`（编码/括号/方法链/符号）+ `python -m maxmcp --selftest-python`。
- 动态：`diag/modeling_ext_test.py`（可重复运行）——Box + TurboSmooth 参数修改回读、
  Edit Poly 建模操作链、堆栈查询、错误路径（无效对象/参数/修改器/不支持类）、
  CHS/ENU 一致性。输出成功/失败计数与错误明细，写入 `diag/logs/`。
- **因 1.4 的环境阻塞，动态测试本轮无法执行**；脚本就绪，Max 恢复后运行。

### 2.4 Graphite 调研（只调查不实现）

产出 `docs/graphite-capability-matrix.md`：Loop/Ring/Swift Loop/Cut/QuickSlice
在 2020 的存在性、MAXScript API、Action Manager 可用性、UI 自动化需求与推荐方案。

---

## 三、交付物

1. `mcp_modeling_ext.ms`（ENU + CHS）+ `mcp_bridge.ms` 模块注册
2. `catalog/modeling.py` 新增 6 工具
3. `docs/graphite-capability-matrix.md`
4. `diag/modeling_ext_test.py`（可重复运行测试）
5. 实测报告（受环境阻塞，记录为未决）
