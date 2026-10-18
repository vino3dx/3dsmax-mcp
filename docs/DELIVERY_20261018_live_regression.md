# 交付报告：环境恢复后实机回归与架构裁决跟进

> 日期：2026-10-18 晚 ｜ 基线提交：`b80b8f0` ｜ 目标版本：3ds Max 2020（兼容至最新版）
>
> 本轮任务书前提"3ds Max 环境已恢复正常"。实测：Max **可启动但启动稳定性严重退化**
> （见第 4 节时间线），实机全量回归因此未能完成；静态三关、部署零漂移、架构裁决均已完成。

---

## 1. 本轮执行内容

| # | 任务 | 结果 |
|---|---|---|
| 1 | 第六关契约测试 `test/catalog_contract_test.py` | **通过**：384 工具 0 静态违例，580 payload 用例 0 失败，危险工具表 19 项仅输出 |
| 2 | 注册同步 `test/registration_sync_test.py` | **通过**：384 Python 工具 ↔ 353 MAXScript 命令 ↔ 19 模块；部署树（ENU/CHS）字节级比对零漂移 |
| 3 | 全局完整性 `scripts/verify.py` | **通过**：384 工具 / 8 分类、353 注册命令、52 个 Listener 速查符号全部解析 |
| 4 | Mock 桥接端到端 `scripts/test_e2e.py` | **通过**：stdio 链路、中文往返、HTTP/SSE/鉴权、语言 auto 跟随（全部检查点绿） |
| 5 | 部署 `scripts/install.py --yes` | **完成**：19 模块 + 自动加载器 → ENU/CHS 双脚本树；服务端 17 文件刷新；配置同步 8765/auto/full |
| 6 | 实机全量回归 `test/modeling_ext_test.py` | **未完成**：Max 启动崩溃（环境性，见第 4 节） |
| 7 | 架构裁决 ×2 | **完成**：结论见第 5 节 |

---

## 2. 静态检查与部署证据

```
$ python test/catalog_contract_test.py
tools checked (A)        : 384
static violations        : 0
payload cases (C)        : 580 passed, 0 failed
dangerous tools (B)      : 19 (output only)
catalog contract holds

$ python test/registration_sync_test.py     # 部署后复跑（含字节级部署树校验）
python tools          : 384
maxscript commands    : 353
repo script files     : 19
all consistent

$ python scripts/verify.py
catalog: 384 tools in 8 categories
MAXScript modules: 19, registered commands: 353
Listener cheatsheet: 52 bridge symbols resolve
all integrity checks passed

$ python scripts/test_e2e.py
end to end: all checks passed (8 bridge calls observed)
```

部署记录（`scripts/install.py --yes`）：ENU 与 CHS 两棵脚本树各 19 个 `.ms` 模块 +
`startup/3dsmax-mcp-bridge.ms` 自动加载器 + `3dsmax-mcp.ini`（port=8765, language=auto）；
服务端 17 个 Python 文件刷新至 `%LOCALAPPDATA%\3dsmax-mcp\maxmcp`；
`~/.3dsmax-mcp/config.json` 同步 port/language/profile。安装器按自身安全机制为四个客户端
配置（Claude / Cline / Cursor / WorkBuddy）各留了一份 `.bak` 备份（内容与改前一致）。

---

## 3. 实机回归环境事实

- 首次启动（20:51，安装前）：**存活**（数分钟后被正常关闭）。
- 安装后 GUI 连续 5 次启动：**全部崩溃**；批处理模式 1 次：**崩溃**（见第 4 节时间线）。
- 崩溃不留标准工件：无 Application Error 事件、无 WER dump、无 Max 日志条目；
  自动加载器日志 `%TEMP%\3dsmax-mcp\loader.log` 存在但为空（与历史 D5 崩溃形态一致）。
- 机器背景：今日 19:27 曾发生 GPU LiveKernelEvent（TDR, 193）并伴随一次蓝屏
  （`C:\WINDOWS\Minidump\091026-15062-01.dmp`）。混合显卡（RTX 4060 + Intel UHD +
  GameViewer 虚拟显示适配器），NVIDIA 驱动 32.0.15.9174（2025-12-30）。
- 可用内存 3.1 GB / 共 15.6 GB（偏低，但非耗尽）。

---

## 4. 实机回归尝试时间线与对照实验

| 时间 | 动作 | 结果 |
|---|---|---|
| 20:51 | 首次启动 Max（安装前，无自动加载器在场） | **存活**，正常关闭 |
| 20:58 | `install.py --yes` 后启动（自动加载器生效） | ~4s 崩溃 |
| 21:03 | 原样重试 | ~36s 崩溃 |
| 21:07 | **对照实验：禁用 ENU+CHS 两处自动加载器**后启动 | ~32s 崩溃 |
| 21:10 | 恢复自动加载器后启动 | ~36s 崩溃 |
| 21:17 | 再次启动 | ~44s 崩溃 |
| 21:16 | **批处理模式** `3dsmaxcmd.exe -continueOnError -preRenderScript:探针.ms <场景>` | `Max is down`（~6s），探针脚本未被执行 |
| 21:2x | 最后 1 次 GUI 启动 | ~36s 崩溃 |

**对照实验结论**：
1. 禁用本插件自动加载器后 Max 依然崩溃 → 崩溃与本插件无关，
   排除"桥接启动路径导致崩溃"的假设。
2. 批处理模式（`3dsmaxcmd.exe`，实际拉起 `3dsmax.exe` 引擎、无 GUI 视口）
   同样在数秒内崩溃，且早于任何脚本执行 → 崩溃位于 **Max 核心引擎启动阶段**
   （插件/内核初始化），与 GUI、视口、本插件均无关。
3. 崩溃时机 4s/32s/36s/36s/44s 不固定、无任何事件日志/dump 残留，
   结合当日 19:27 的 TDR/蓝屏背景，判定为**机器级环境不稳定**，非插件缺陷。

**统计**：本轮共 8 次引擎启动（7 GUI + 1 批处理），仅 20:51 首次（安装前）存活。

**对 DoD 的影响**：实机端到端与全量回归（`test/modeling_ext_test.py` 6+6 组）
未执行。该脚本要求空场景、连 8765 端口真实桥接，Max 无法稳定存活即无法开展。
待环境稳定后按 `python test/modeling_ext_test.py`（默认 127.0.0.1:8765）一键复跑，
其 `--list` 模式提供无 Max 的用例清单自检。

---

## 5. 架构裁决结论

### 5.1 `render_element_remove` 的 `undoable:false` —— **维持不变**

评估依据：

1. **语义链**：`undoable` 标志由中央分发器消费（`src/ms/mcp_net.ms:104-106`）——
   `true` 时用 `theHold.Begin/Accept` 包裹 handler，`false` 时直接执行；
   且支持按请求覆盖（`params.undo`），调用方可在单次调用中临时获得 undo 包裹。
2. **类别策略一致**：`src/ms/mcp_render.ms:872` 注释明确"mutating / slow - keep them
   undoable:false"，渲染元素三兄弟（add/remove/set_output）与整个 render 类别统一
   `undoable:false`；单独改 remove 会造成同组不对称。
3. **未验证风险**：`maxOps.GetCurRenderElementMgr().RemoveRenderElement` 是否被
   theHold 捕获（即 Ctrl+Z 能否真正恢复被移除的元素）**未在 Max 2020 上验证**。
   若底层操作非 hold-aware，改 `true` 只会 Accept 一条空 undo 记录，构成虚假承诺
   （违反 V2"声称必须可复现"）。
4. **已有逃生口**：按请求 `undo:true` 覆盖；且误删元素可通过 `render_element_add`
   重建（元素本身无唯一状态）。

**后续验证方案**（Max 稳定后执行，一次即可定案）：
`render_element_add zdepth` → `render_element_remove(element=zdepth, undo=true)` →
`undo_last` → `render_elements_list` 检查元素是否恢复。若恢复 → 将
`src/ms/mcp_render.ms:888` 改 `undoable:true`（一行改动，随下次部署生效）；
若不恢复 → 维持 `false`，本文档结论即为终局。

### 5.2 preset 与模型显式传参的覆盖逻辑 —— **无需调整**

现行语义（`src/python/maxmcp/server.py:360-381` `_build_payload`）：
preset 为基座；**仅 schema 声明的键**会被模型显式传参覆盖；未声明键一律忽略
（容忍模型输出漂移，preset 原值存活）；随后做 required 校验与类型强转。

该语义精确实现了既定的**两级工具设计**：

| 工具层 | 身份键（class/type） | 模型可否指定 | 例 |
|---|---|---|---|
| 基础工具 | 声明且 required | **可** | `create_primitive`（class 必填）、`light_create`（type 必填） |
| 专用工具 | 仅存于 preset、未声明 | **不可** | `create_rectangle`（恒 Rectangle）、`light_create_omni`（恒 omni） |

设计意图：**工具名即契约**——专用工具的身份不可被参数篡改（`create_rectangle`
传 `class=Circle` 无效，仍建 Rectangle），需要别的类应换基础工具或对应专用工具。
调整此逻辑只会有两种后果：(a) 允许覆盖身份键 → 破坏工具契约；(b) 对未声明键报错 →
 模型轻微漂移即硬失败。两者均劣于现状。契约测试已用
"preset survives an undeclared same-name argument"与
"declared argument overrides preset value"两用例锁定该行为（580 payload 断言之一）。

---

## 6. 改动文件清单

本轮**未改动任何源码**（两个裁决均为"维持现状"结论，无需代码变更；
部署动作只写入 `%LOCALAPPDATA%` 两棵部署树，仓库工作树保持干净）。

| 文件 | 说明 |
|---|---|
| `docs/DELIVERY_20261018_live_regression.md` | 本报告（新增） |

---

## 7. 未确认事项与建议

1. **【阻塞实机回归】Max 引擎启动不稳定（环境级）**：本轮 8 次启动 7 次崩溃
   （GUI 与批处理模式均崩，禁用本插件自动加载器后仍崩，崩溃早于脚本执行），
   与本插件无关。建议：更新 NVIDIA 独显驱动（当前 2025-12-30 版本已 10 个月）；
   排查 GameViewer 虚拟显示适配器与混合显卡的冲突；分析 19:27 蓝屏转储
   `C:\WINDOWS\Minidump\091026-15062-01.dmp`。注意仅"长时间空闲后首次启动"
   存活过一次（20:51），后续连续启动全崩——若需继续实机回归，建议停机闲置
   一段时间后再试，或先在另一台机器上验证环境。待启动稳定后，按第 4 节方案
   一键复跑实机回归（`python test/modeling_ext_test.py`，默认 127.0.0.1:8765）。
2. **render_element_remove undo 探针**（第 5.1 节方案）待 Max 稳定后执行。
3. 安装器为四个客户端配置生成的 `.bak` 备份保留在用户目录（安装器安全机制），
   确认无误后可手动删除。
4. 历史存档目录 `%LOCALAPPDATA%\Autodesk\3dsMax\2020 - 64bit.fresh_crash\`
   （先前崩溃调查留档）本轮未动，可由用户决定去留。
