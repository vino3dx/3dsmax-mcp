# 过夜流水线总报告（2026-10-19 夜间）

> 执行窗口：2026-10-19 00:08 – 07:5x（墙钟上限 8 小时内收尾）。
> 仓库：`D:\Workspace\Dev\3dsmax-mcp`，main 分支，起始 HEAD `e1b5746`。
> 执行者：唯一 agent（WorkBuddy 过夜流水线）。

---

## 1. 本轮任务与完成状态

| 任务 | 内容 | 状态 | 提交 |
| --- | --- | --- | --- |
| T1 | P0 采证收尾：MDMP 解析器 + UCRT 时间线 + KB 调查 + P0_ENV.md 第一部分 | **完成** | `8cf407f`（已 push） |
| T2 | P0 受控启动实验：max_health.py + 后台循环 12 次 | **完成（12/12 崩溃，无 PASS）** | `P0_ENV.md` 第二部分，见下 |
| T3 | 实机验证（仅 T2 PASS 才执行） | **未执行（环境阻塞）** —— 按任务书定义不算失败 | — |
| T4 | P1 验证矩阵：live_matrix.py + 43 用例 + mock 自检 + LIVE_MATRIX.md | **完成** | `2332415`（已 push） |
| T5 | P2 工具面提案：TOOL_PROFILES_PROPOSAL.md | **完成** | `c56b32a`（已 push） |
| 收尾 | P0_ENV 第二部分 + 本报告 + 终检 | **完成** | 本轮最后提交 |

push 全部成功（SSH remote `git@github.com:vino3dx/3dsmax-mcp.git`，普通 push，无 force）。

## 2. P0 根因判断与置信度（详见 docs/P0_ENV.md）

- **已确认【实测】**：崩溃点是 3ds Max 进程主动调用 `abort()`
  （ucrtbase.dll 10.0.26100.9444 + 0xa527e = 导出符号 `abort` + 78 字节；
  fail-fast 子码 7 = FAST_FAIL_FATAL_APP_EXIT；异常码 0xC0000409）。
  自研纯标准库 MDMP 解析器与 WER Report.wer 逐字段互证（偏移/版本/时间戳/
  异常数据全部一致）。
- **已确认【实测】**：abort 由 C++ terminate 路径调用（栈上 `terminate`+
  `__std_terminate`）——典型的未处理 C++ 异常 / noexcept 违规 / 纯虚调用。
- **高度怀疑【栈扫描，非完整 unwind】**：抛出源在 Autodesk 自带
  `EPoly.dlo`（Editable Poly 插件，22.0.0.757）+ 0xe0930 —— 两个相隔 20 小时的
  独立转储栈偏移完全一致。转储不含模块映像，无法 .pdata 展开坐实。
- **已确认【实测】**：与 3dsmax-mcp 插件无关（全新配置也崩、自动加载器未执行、
  栈上无本插件模块）。
- **已排除【实测】**：10-17 三个 KB **没有**更新 ucrtbase.dll（文件 mtime
  2026-09-10 22:59，早于安装 5 周）；联网检索三个 KB 均无
  "应用启动 abort/UCRT"已知问题；"10-18 19:27 蓝屏"说法作废（未引用）。
- **空闲假设：被实验否定【实测】**：12 次受控启动 12 次崩溃，空闲 3.2h 与
  20 min 无差异（存活 34-47s），签名 12/12 与历史 24 次完全相同——同一确定性
  崩溃点累计 36 次。历史唯一存活案例（约 19.4h 空闲后）无法复现也无法解释。
- **未知**：为何 10-17 起才触发（时间相关但 KB 未改 UCRT，因果未证实）；
  EPoly.dlo 中被触发异常的具体代码路径。

## 3. 关键证据摘录（均为【实测】）

- Application 日志：10-16 起 24 条 3dsmax.exe Event 1000（版本 22.0.0.757）。
- WER：EventType=BEX64，桶 `8ebcaa78...`，故障模块 ucrtbase.dll 10.0.26100.9444
  （时间戳 2bbefd73），偏移 0xa527e，异常数据 7。
- 转储解析（3 个历史样本 + 12 个实验样本）：异常码/地址/模块/栈模式逐字段一致；
  栈扫描顶部帧：`terminate+30 → __std_terminate+9 → EPoly.dlo+0xe0930`。
- 转储仅含崩溃线程（WER mini 类型）、无模块映像（memory_ranges 覆盖检查
  `pdata_image_in_dump=False`）→ 完整 unwind 不可行，已如实标注。
- T2 实验：12 次启动，每次前确认无残留进程，崩溃后自动抓 1 个新转储并核对签名
  （12/12 相同），转储存档 `test/logs/dumps/`（12 × ~224 MB）。
- 实验机器状态：可用内存 2.15-2.95 GB / 15.6 GB（约 81-86% 已占用）。

## 4. 需要用户手动执行的操作（按优先级，复验命令统一为
`python scripts/max_health.py launch-watch`）

1. 核对并考虑卸载 10-17 三个更新（KB5127648/47/90，设置→Windows 更新→卸载更新）；
   注意本诊断已弱化 KB 因果（ucrtbase 未被改动），此项是排除手段。
2. 系统还原到 10-17 09:05 重启之前（`rstrui`）。
3. 修复 VC++/UCRT 运行库（重装 VC++ 2015-2022 x64 最新版 + `sfc /scannow`）。
4. 更新 NVIDIA 驱动（当前 2025-12-30 版已 10 个月）。
5. 安装第二个 Max 版本做对照（锚定 Max 2020 vs 系统状态）。
6. 可选：下次崩溃抓全内存转储（procdump 全内存模式或 WER DumpType=2），
   以坐实 EPoly.dlo 抛出点。

## 5. 提交列表（hash + push 状态）

| 提交 | 内容 | push |
| --- | --- | --- |
| `8cf407f` | P0: max_health.py（check/launch-watch/dump-analyze，纯标准库）+ P0_ENV.md 第一部分 | 成功 |
| `2332415` | P1: test/live_matrix.py + test/live_cases/（43 用例）+ docs/LIVE_MATRIX.md | 成功 |
| `c56b32a` | P2: docs/TOOL_PROFILES_PROPOSAL.md（仅文档） | 成功 |
| 本轮收尾提交 | P0: P0_ENV.md 第二部分（T2 实验结果）+ 本报告 | 见 git log |

新增文件全部在允许清单内：`scripts/max_health.py`、`docs/P0_ENV.md`、
`test/live_matrix.py`、`test/live_cases/*.json`（5 个）、`docs/LIVE_MATRIX.md`、
`docs/TOOL_PROFILES_PROPOSAL.md`、`docs/OVERNIGHT_REPORT_20261019.md`。
每个提交前 `scripts/verify.py` 全绿（离线 lint 七关含文档对齐审计）。

## 6. 未确认事项

1. EPoly.dlo+0xe0930 的具体函数与抛出原因（需带模块映像的完整转储 + 符号）。
2. 10-17 前后系统级变化的完整清单（KB 内容之外的驱动/组件变化未逐项排查）。
3. KB5127648 文档标注 25H2 目标 build 26200.9711，现场为 26200.9457，
   两者关系未确认（Get-HotFix 显示 KB 已安装）。
4. 更长空闲（>3.2h，如过夜 ~12h）下的启动行为未测试。
5. 三个 KB 是否存在未公开的兼容性问题——检索未见报告，不能证明不存在。
6. token 估算为粗估方法（ASCII/4 + CJK/1，误差 ±20%），仅用于横向比较。

## 7. 遗留风险与事件记录

1. **并行进程改动工作区【实测事件】**：T2 实验执行期间（00:26–00:48 之间），
   `scripts/max_health.py` 工作区被一个来源不明的进程改动（+155/-35 行：
   新增 WER 报告检查、`--close-after`、`--memory-min-mb` 等）。本流水线
   未做此改动；12 次实验实际运行在该改动版本上。处理：改动全文留存
   `test/logs/foreign_max_health_diff.patch`（361 行，未入库），文件已回滚到
   已验证提交 `8cf407f`，`git status` 恢复干净。**建议用户核查是否有第二个
   agent/会话在操作本仓库**（与 2026-10-18 offline_lint_helper 并行写入事件
   同类）。
2. T3 未执行 → live_matrix 的 43 条用例与 modeling_ext_test 仍未在真实 Max 上
   跑过；P1 框架的有效性目前只由 mock 自检保证（4/4 阶段通过）。
3. 仓库内 `docs/LIVE_MATRIX.md` 为离线快照（全部"未验证"），需在 Max 恢复后
   用 `python test/live_matrix.py --port 8765 --write-doc docs/LIVE_MATRIX.md`
   重新生成。
4. test/logs/ 现约 3.1 GB（12 个实验转储 + 3 个历史转储分析 JSON），
   已 gitignore，建议问题解决后清理。
5. Max 2020 非 Windows 11 官方兼容版本（Autodesk 官方支持自 2023 起）——
   即使本次修复，该组合仍属"非官方可用"。

## 8. 终检结果

- `git status` 干净（工作区与暂存区无未提交改动）。
- 无残留 3dsmax.exe（循环结束后 tasklist 核实）。
- test/logs 之外无新增临时文件（新增文件全部入库或位于 gitignored 的 test/logs）。
- 全部 6 个后台/前台任务资源已回收（mock bridge 已停止、launch 循环已退出）。
