# P0 环境诊断：3ds Max 2020 启动崩溃

> 本文档记录 3ds Max 2020 启动即崩（ucrtbase abort / 0xC0000409）的采证、实验与处置结论。
> 第一部分（T1，2026-10-19 凌晨，离线）：转储解析 + 运行库时间线 + KB 调查 + 根因判断。
> 第二部分（T2）：受控启动实验（空闲假设）与用户操作清单 —— 由过夜流水线后续补写。
> 第三部分（2026-10-20）：P0-Single-Test 单次受控复验（第 37 次同签名崩溃 + UCRT 换版未止崩）。
> 所有结论标注【实测】（有日志/dump/退出码证据）或【推测】（无直接证据）。
> 工具：`scripts/max_health.py dump-analyze`（纯 Python 标准库，无 cdb/WinDbg）。

---

## 第一部分：采证与交叉验证

### 1.1 事件时间线（【实测】，来源：Application 事件日志 / WER / CrashDumps）

| 时间 | 事件 | 证据 |
| --- | --- | --- |
| 2026-09-10 22:59 | ucrtbase.dll 当前版本落盘（10.0.26100.9444，时间戳 2bbefd73） | 文件 mtime |
| 2026-10-17 09:05 | 机器重启（KB5127648 / KB5127647 / KB5127690 已于此前安装） | Get-HotFix: InstalledOn 2026/10/17 |
| 2026-10-17 10:54:44 | 首次 3dsmax.exe Application Error（Event 1000） | 事件日志 |
| 2026-10-17 23:42 ~ 10-18 01:28 | 连续崩溃 17 次（含 00:44 全新空配置 `.fresh_crash` 实验） | 事件日志共 24 条 |
| 2026-10-18 20:57 ~ 21:18 | 再次连续崩溃 6 次 | 事件日志 |
| 2026-10-18 21:18:26 | CrashDumps 目录最后更新（3dsmax.exe.41944.dmp） | 目录 mtime |

- Application 日志自 10-16 起共 **24 条** 3dsmax.exe Application Error（Event ID 1000），
  应用版本全部为 22.0.0.757 / 时间戳 0x5c7f03ff（Max 2020 原版，无 Update）【实测】。
- WER 崩溃桶唯一：`Response.BucketId=8ebcaa78e7b344257e372af4f881a525`，
  EventType=BEX64，24 次签名完全一致【实测】。
- System 日志近 7 天无 BugCheck/TDR/Display 事件；唯一 Minidump 为 2026-09-10，
  故"10-18 19:27 蓝屏"的说法作废，本文不再引用（沿用总指挥结论）。

### 1.2 转储解析结果（【实测】，3 个样本，全部一致）

样本：`3dsmax.exe.41944.dmp`（10-18 21:18，最新）、`3dsmax.exe.15320.dmp`（10-18 00:49，
`.fresh_crash` 实验后第一次崩溃）、`3dsmax.exe.6812.dmp`（10-18 20:58）。三者
**逐字段一致**：

| 字段 | 转储解析值 | WER Report.wer 对应值 | 一致性 |
| --- | --- | --- | --- |
| 异常代码 | 0xC0000409 | 异常代码 c0000409 | 一致 |
| 异常偏移 | ucrtbase.dll + 0xa527e | 异常偏移 00000000000a527e | 一致 |
| 故障模块版本 | 10.0.26100.9444（时间戳 2bbefd73） | 故障模块版本 10.0.26100.9444 / 时间戳 2bbefd73 | 一致 |
| 异常数据（fail-fast 子码） | 7 = FAST_FAIL_FATAL_APP_EXIT | 异常数据 0000000000000007 | 一致 |
| 符号还原（磁盘同名 DLL 导出表） | ucrtbase.dll 导出 `abort` + 78 字节 | — | — |
| 已加载模块数 | 617 ~ 619 | — | — |

**崩溃点结论【实测】**：RIP 落在 `ucrtbase.dll!abort` 函数体内（+78 字节），
以 `__fastfail(FAST_FAIL_FATAL_APP_EXIT)` 终止进程 —— 即 **进程主动调用了 `abort()`**。

**崩溃线程栈（栈扫描，RSP 向上最近的模块指针）【实测】**

```
ucrtbase.dll + 0x116128
ucrtbase.dll + 0xc218e   ~terminate + 30
ucrtbase.dll + 0xaea99   ~__std_terminate + 9
EPoly.dlo    + 0xe0930   <-- Autodesk 自带 Editable Poly 插件（stdplugs）
ucrtbase.dll + 0xb35e0
ucrtbase.dll + 0xaea90   ~__std_terminate + 0
...
ntdll.dll    + 0x16557f
```

**解读【高度怀疑，非实测】**：`__std_terminate`（C++ 默认 terminate 处理器，其唯一行为是
调用 abort）下方最近的非 ucrtbase 返回地址是 `EPoly.dlo + 0xe0930`。这是典型的
**C++ 未处理异常 / noexcept 违规 / 纯虚调用 → std::terminate → abort** 路径，
抛出点位于 EPoly.dlo（3ds Max 核心 Editable Poly 插件 DLL，版本 22.0.0.757）。
两个独立样本栈偏移完全相同，说明是确定性调用点而非随机内存踩踏。

**解析局限（诚实声明）**：
- WER LocalDumps 为 minidump，仅含崩溃线程（thread_count=1）与 8462 个内存段，
  **不含任何模块映像**（`pdata_image_in_dump=False`），因此无法基于 .pdata 做完整
  unwind 链验证；栈结论来自"栈上落入模块范围的 qword"扫描，理论上可能掺入陈旧值。
  若需坐实 EPoly.dlo 调用点，需要带模块映像的完整转储（见 1.6）。
- 栈扫描中 ucrtbase 的符号名为"最近导出"，大函数内部偏移可能落在非导出区域
  （如 `_wctype`、`longjmp` 附近实际是其他内部函数），仅供定位参考。

### 1.3 与本插件的关系（【实测】）

- 10-18 00:44 使用全新空用户配置（`.fresh_crash`）启动同样崩溃 —— 与本插件
  的用户配置无关（总指挥已核实，本文引用）。
- 10-18 全部崩溃中 MCP 自动加载器均未执行（autoloader 日志为空）—— 崩溃早于任何
  MAXScript 执行（总指挥已核实，本文引用）。
- 崩溃线程栈上不存在本插件模块（3dsmax-mcp 的 .ms 不走原生 DLL）。
- 结论：**崩溃与 3dsmax-mcp 插件无关**，属 3ds Max / 系统环境级问题【实测】。

### 1.4 UCRT / VC 运行库时间线（【实测】）

| 文件 | 版本 | mtime | 与 10-17 KB 的关系 |
| --- | --- | --- | --- |
| `C:\Windows\System32\ucrtbase.dll` | 10.0.26100.9444 | 2026-09-10 22:59:07 | **未更新**（早于安装 5 周） |
| `C:\Windows\System32\msvcp_win.dll` | 10.0.26100.9444 | 2026-09-10 22:59:07 | 未更新 |
| `msvcp140.dll` / `VCRUNTIME140.dll` / `VCRUNTIME140_1.dll` | 14.50.35719.0 | 2025-11-21 | 未更新 |
| `msvcp100.dll` | 10.0.40219.325 | （2011 年代） | 未更新 |

- 转储中加载的 ucrtbase.dll 版本（10.0.26100.9444）与磁盘当前文件一致，
  时间戳 2bbefd73 与 WER 记录一致 —— 现场运行的就是系统 UCRT【实测】。
- **结论：10-17 安装的三个 KB 没有更新 ucrtbase.dll**。UCRT 自 2026-09-10 后未变动，
  而 09-10 至 10-17 期间 Max 未发生此类崩溃，时间相关性弱。
- `C:\Windows\System32` 在 10-17 08:00–12:00 窗口内 **0 个文件** mtime 变动
  （累计更新经 WinSxS/Servicing 落地，属预期行为，不代表"无改动"）【实测】。
- 当前 OS：Windows 11 家庭版 中文版，Build 26200.9457，DisplayVersion 25H2【实测】。
  注：KB5127648 文档标注 25H2 目标 build 为 26200.9711，与现场 26200.9457 不一致，
  两者关系【未确认】（Get-HotFix 显示三个 KB 均于 10-17 安装）。

### 1.5 KB 联网调查（【实测】搜索，2026-10-19）

- **KB5127648**（2026-10-13 发布）：Windows 11 24H2/25H2/26H2 累积更新
  （OS build 26100.9711 / 26200.9711 / 26300.9711），内嵌服务堆栈更新 KB5127647
  （26100.9703）。其已知问题仅两项：非管理员 RDP 失败 0xC000000D、USB Audio Class 1.0
  设备异常 —— **均与应用启动 abort / UCRT 无关**。
- **KB5127647**：服务堆栈更新（SSU），无独立已知问题清单。
- **KB5127690**：.NET Framework 3.5 / 4.8.1 安全累积更新，官方标注
  "Microsoft is not currently aware of any issues"。
- 未检索到任何将这三个 KB 与"ucrtbase abort / 应用启动即崩"关联的报告。
- 兼容性背景（第三方汇编，非官方）：3ds Max 2020 **不在** Windows 11 官方兼容列表
  （Autodesk 官方支持自 2023 起；2020 属"多数可用但非官方"），社区有"旧版 Max 在
  Win11 大版本更新后崩溃"的历史报告。Autodesk 官方对随机崩溃的标准建议包括：
  重装/修复 VC++ 运行库、更新显卡驱动、重置用户配置。
- 结论：**未找到 KB 与本次崩溃的因果证据**，"KB 导致 Max 崩溃"目前只是时间相关性
  【推测】。

### 1.6 根因判断汇总

| 判断 | 置信度 | 性质 |
| --- | --- | --- |
| 崩溃点是 3ds Max 进程主动 `abort()`（ucrtbase+0xa527e，fail-fast 7），24 次签名完全一致 | 已确认 | 实测（转储 + WER 双源互证） |
| abort 由 C++ terminate 路径调用（`__std_terminate` 在栈上） | 已确认 | 实测（栈扫描 + fail-fast 码） |
| 抛出源在 Autodesk 自带 EPoly.dlo（+0xe0930，未处理 C++ 异常/noexcept 违规/纯虚调用） | 高度怀疑 | 栈扫描显示调用者返回地址；缺完整 unwind 佐证 |
| 与 3dsmax-mcp 插件无关 | 已确认 | 实测（fresh config + autoloader 未执行 + 栈上无本插件模块） |
| 10-17 三个 KB 是根因 | 低（仅时间相关） | 推测；KB 未改动 ucrtbase，无已知问题报告 |
| 触发条件（为何 10-17 起才出现、为何偶发可存活） | 未知 | 样本不足，待 T2 实验 |

**下一步取证建议**（需用户手动，见第二部分操作清单）：用Sysinternals procdump `-ma`
（或 WER LocalDumps 调 DumpType=2 完整转储）抓一次带模块映像的转储，即可对
EPoly.dlo+0xe0930 做 .pdata 完整 unwind，坐实或排除抛出点。

---

## 第二部分：受控启动实验（T2，2026-10-19 00:31–04:30）

### 2.1 实验设计

`test/logs/overnight_launch_loop.py`（后台进程）调用
`python scripts/max_health.py launch-watch --json`：每次启动前确认无残留
3dsmax.exe，启动后监测；PASS = 存活 ≥120s 且桥接 ping 成功。每次尝试间隔
20 分钟（空闲假设），最多 12 次；崩溃后自动复制新转储到 `test/logs/dumps/`
并用 `max_health.py dump-analyze` 核对签名是否仍是 ucrtbase+0xa527e。
并发运行 `test/diagnostics/dismiss_modal.py`（90s 窗口，白名单标题）清理启动阻塞弹窗。

> **2026-10-20 更新（P0-Next-3 安全加固）：上述过夜循环脚本已停用（RETIRED），
> 不能用于当前 P0 测试。** 现位于 `test/logs/2026-10-19/overnight_launch_loop.py`
> 的该脚本原先会在每次尝试前对机器上**所有** `3dsmax.exe` 执行按映像名的批量
> 结束（先优雅、后强制），可能误杀用户的日常 Max 实例（含未保存场景），并且
> 无法区分"本次测试实例"与"用户实例"；同时它会并发拉起无 PID 过滤的全局弹窗
> 点击器。现已删除全部进程终止路径与弹窗点击器调用，脚本入口直接打印停用
> 说明并以 exit 2 退出，不再启动/监视/关闭任何 Max 进程。
> **当前唯一受支持的受控启动方式是有人值守的单次复验：**
> `python scripts/max_health.py launch-watch --json`
> ——发现任何残留 `3dsmax.exe` 即中止、不关闭任何进程；启动前基线化全部崩溃
> 证据（CrashDumps / WER / 事件日志），只归因本次尝试的新增证据；
> `AppHangTransient` 仅记 WARNING，不判定崩溃。5 连发的 DoD campaign 需先
> 获得用户批准（执行窗口 + 尝试间关闭 Max 的责任人），且严禁使用已停用的
> 过夜循环脚本。

**实验条件说明【实测】**：第 1 次尝试距上次 Max 退出（10-18 21:18 崩溃）
空闲约 3.2 小时；第 2-12 次按设计间隔 20 分钟。实验期间可用物理内存
2.15-2.95 GB / 15.6 GB。注：实验执行期间 `scripts/max_health.py` 工作区被
一个来源不明的并行进程改动过（新增 WER 报告检查、--close-after 等，见
遗留风险），12 次尝试实际运行在该改动版本上；实验结束后已回滚到本仓库
已验证提交（8cf407f），改动全文留存于
`test/logs/foreign_max_health_diff.patch`。

### 2.2 实验结果（【实测】，12/12 全部崩溃，无 PASS）

| 尝试 | 开始 | 空闲时长 | 可用内存 | 存活 | 结果 | 签名核对 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 00:31:55 | 11605s（3.2h） | 2.19 GB | 42.3s | 崩溃 exit=0xC0000409 | 相同 |
| 2 | 00:53 | 1201s | 2.28 GB | 33.3s | 崩溃 exit=0xC0000409 | 相同 |
| 3 | 01:15:01 | 1201s | 2.28 GB | 46.5s | 崩溃 | 相同 |
| 4 | 01:36:33 | 1201s | 2.35 GB | 43.3s | 崩溃 | 相同 |
| 5 | 01:58:06 | 1201s | 2.35 GB | 35.3s | 崩溃 | 相同 |
| 6 | 02:19:39 | 1201s | 2.29 GB | 35.3s | 崩溃 | 相同 |
| 7 | 02:41:12 | 1201s | 2.17 GB | 36.3s | 崩溃 | 相同 |
| 8 | 03:02:44 | 1201s | 2.15 GB | 46.4s | 崩溃 | 相同 |
| 9 | 03:24:17 | 1201s | 2.27 GB | 35.3s | 崩溃 | 相同 |
| 10 | 03:45:49 | 1201s | 2.45 GB | 42.4s | 崩溃 | 相同 |
| 11 | 04:07:22 | 1201s | 2.60 GB | 36.3s | 崩溃 | 相同 |
| 12 | 04:28:55 | 1201s | 2.95 GB | 34.3s | 崩溃 | 相同 |

- 每次崩溃各产生 1 个新转储（WER 桶偏移均 0xa527e / 代码 c0000409 /
  异常数据 7），12 份已复制到 `test/logs/dumps/attemptNN_3dsmax.exe.<pid>.dmp`。
- **累计证据：同一签名崩溃现在共 36 次（24 次历史 + 12 次受控实验），
  覆盖全新配置、自动加载器禁用、批处理模式与空闲 20 分钟~3.2 小时多种条件。**

### 2.3 结论

1. **空闲假设在本实验中被否定【实测】**：空闲 3.2 小时（attempt 1）与 20 分钟
   （attempt 2-12）的存活时间无差异（34-47s），12/12 崩溃。历史上唯一的
   存活案例（10-18 20:51，安装前，距前次退出约 19.4h）无法用"空闲时长"解释，
   也未能在本实验中复现（本实验最长空闲仅 3.2h，**更长的空闲未测试**）。
2. 触发条件仍未定位：崩溃与用户配置、插件自动加载、GUI/批处理模式、
   空闲时长均无关【实测】。剩余可变因素指向系统级状态（更新引入的某个组件、
   驱动、或与 EPoly.dlo 交互的某个环境变化）【推测】。
3. 每次尝试之间可用内存 2.15-2.95 GB（约 81-86% 已占用）——偏低，但崩溃签名
   完全确定，内存压力不是直接原因【推测】。

### 2.4 需要用户手动执行的操作（按优先级）

> 每步之后复验：`python scripts/max_health.py launch-watch`
> （PASS = 存活 ≥120s 且桥接 ping 成功；崩溃则自动记录转储与签名）。
> 1-3 涉及系统变更，请先保存工作并确认有还原手段；本流水线无权执行这些操作。

1. **核对并考虑卸载/回滚 10-17 三个更新**（KB5127648 / KB5127647 / KB5127690）
   —— 通过「设置 → Windows 更新 → 更新历史记录 → 卸载更新」逐个卸载
   （KB5127647 是服务堆栈更新通常不可单独卸载；KB5127690 是 .NET 更新影响面小
   可最后处理），重启后复验。注意：本诊断显示 ucrtbase.dll 未被这些更新改动
   （mtime 2026-09-10），且三个 KB 均无相关已知问题报告 —— 卸载是排除手段
   而非高置信度修复（见 1.5/1.6），按任务书要求仍列为第一位。
2. **系统还原点**：恢复到 10-17 09:05 重启之前的还原点（`rstrui`）。
   能一并回滚更新与驱动变更，比逐个卸载更彻底。
3. **修复 VC++/UCRT 运行库**：重装 Microsoft Visual C++ 2015-2022
   Redistributable (x64) 最新版；管理员运行 `sfc /scannow`。Autodesk 官方对
   随机崩溃的标准建议包含此项（见 1.5）。
4. **更新 NVIDIA 驱动**：当前 32.0.15.9174（2025-12-30，已 10 个月）；
   本机为混合显卡（RTX 4060 + Intel UHD + 虚拟显示适配器），建议装 NVIDIA
   Studio 驱动最新版。
5. **安装第二个 Max 版本做对照**（如 Max 2024/2025 试用版）：若新版本正常，
   可把问题锚定在 Max 2020（非 Win11 官方兼容版本）与当前系统状态的组合上。
6. **（证据增强，可选）抓完整转储**：下次崩溃现场用 Sysinternals procdump
   全内存模式（或把 WER LocalDumps 的 DumpType 改为 2）抓带模块映像的转储，
   即可对 EPoly.dlo+0xe0930 做 .pdata 完整 unwind，坐实或排除 1.2 节的
   抛出点判断。

---

## 第三部分：P0-Single-Test 单次受控复验（2026-10-20，第 37 次同签名崩溃）

> 完整记录见 `docs/reports/P0_SINGLE_TEST_20261020.md`（含证据 SHA-256 与关联链）。
> 本轮为有人值守**单次** `python scripts/max_health.py launch-watch --json`（默认参数），
> 用户已确认无未保存日常 Max 工作；仅 1 次启动，未循环、未并行、未自动重试。

### 3.1 启动与结果（【实测】）

| 项 | 值 |
| --- | --- |
| PID | 43016（事件 ProcessCreationTime 07:59:40.63 与启动时间精确吻合） |
| 启动 / 崩溃 | 2026-10-20 07:59:40 / 存活 **39.8 秒**后 0xC0000409 退出 |
| 桥接 | 从未连接；自动加载器未执行（loader.log 无新条目，崩溃早于 MAXScript） |
| 判定 | **FAIL**（DoD：存活 ≥120s 且桥接 ping 成功 —— 未满足） |

### 3.2 签名核对与第 37 次崩溃（【实测】）

异常码 0xC0000409 / ucrtbase.dll + 0xa527e / fail-fast 7（FAST_FAIL_FATAL_APP_EXIT，
即进程主动 abort）/ 最近导出 `abort + 78`；栈顶 ucrtbase+0x116108 → ~terminate+30 →
~__std_terminate+9 → **EPoly.dlo + 0xe0930**，与 1.2 节两个历史样本逐偏移相同。
累计：24 次历史 + 12 次受控实验 + 本次 1 次 = **第 37 次同签名崩溃**。
新增证据（仅归因本次，基线 diff）：dump `3dsmax.exe.43016.dmp`（228,345,268 B，
SHA-256 02681F05…45E2）、WER `AppCrash_3dsmax.exe_e8c173fc…`（BEX64，BucketId
e8620d54…）、事件 150511（Application Error 1000）+ 150512（WER 1001 BEX64）。

### 3.3 UCRT 版本变化：9444 → 9711，崩溃不变（【实测】+【存疑】）

| WER 报告时间 | 故障模块版本（Sig[4]） | 偏移 |
| --- | --- | --- |
| 2026-10-20 08:00:15（本次） | **10.0.26100.9711** | 0xa527e |
| 2026-10-19 04:29:27 | 10.0.26100.9444 | 0xa527e |
| 2026-10-19 04:07:56 | 10.0.26100.9444 | 0xa527e |

- 磁盘 `ucrtbase.dll` 当前为 10.0.26100.9711（mtime 2026-10-17 09:46:47）。
  10-19 04:29 之后 UCRT 已换版，最可能随 10-19 12:39–12:44 更新批次与重启落地；
  生效副本的确切切换机制【存疑】。
- **版本变化未消除该崩溃**：异常码/偏移/fail-fast/栈形状全部不变，abort 调用点 RVA
  0xa527e 在两个构建中相同；WER BucketId 因版本改变而变化（8ebcaa78… → e8620d54…），
  属连带变化而非新故障模式。
- **不得据此认定 Windows 更新为根因**：无因果证据——历史上唯一存活启动（10-19 22:20）
  同样发生在该重启之后；9444 期间亦既有崩溃也有存活。"换 UCRT 不修复"是实测结论，
  "更新导致崩溃"仍只是未经证实的推测。
- 时效修正：1.4 节"10-17 三个 KB 没有更新 ucrtbase.dll"在该时点为真（当时磁盘为
  9444 / mtime 09-10），但**后续更新已把 UCRT 换成 9711**，该结论仅对 10-19 凌晨的
  现场有效，不适用于当前环境。

### 3.4 EPoly.dlo 线索的边界（维持 1.2/1.6 的局限声明）

- EPoly.dlo + 0xe0930（版本 22.0.0.757 / 0x5c7f03b9，Autodesk 自带 Editable Poly
  插件）出现在崩溃线程栈上，且两个历史样本偏移完全相同——这是**待验证线索**，
  **不是根因判定**：minidump 不含模块映像（`pdata_image_in_dump=False`），栈扫描
  理论上可能掺入陈旧值；EPoly.dlo 无公共符号，当前工具只能给出偏移。
- 坐实或排除它需要**带模块映像的完整转储**（procdump `-ma` 或 WER LocalDumps
  DumpType=2）做 .pdata 完整 unwind——所需工具与操作已列于 2.4 节第 6 条，
  **本轮未安装、未下载、未修改任何系统设置**。

### 3.5 本轮边界

未执行任何系统修复；未重复启动；未启动第二次测试；未移动/删除/覆盖任何崩溃证据；
未提交 Git（P0-Next-3 工作区改动与本轮文档更新一并保留待审）。

### 3.6 启动弹窗处置（良性，不阻断测试）

【用户确认】Max 启动时会弹出**缺失 Houdini 插件、材质编辑器**等报错对话框，
不影响整体软件，点"确定"忽略即可。但其**运营影响**必须处置：模态对话框会
**阻断 MAXScript 自动加载器**（`test/diagnostics/dismiss_modal.py` 文档记载
"A modal dialog stops the MAXScript autoloader dead"）——弹窗不消，桥接就不会
监听 8765，`loader.log` 不会更新。10-19 22:20 成功会话即人肉点掉弹窗后桥接
1100ms 内起来；无人值守启动若撞上弹窗，即使 Max 不崩也拿不到桥接。

**处置协议（有人值守单次复验时，2026-10-20 起生效，取代 P0-Single-Test 轮
"不启动弹窗自动点击工具"的旧约束）**：
1. **优先人工点击**：值守者看到弹窗直接点"确定/OK"，零工具风险；
2. 或伴随运行弹窗清理器（只向白名单内的启动阻塞型对话框发 BM_CLICK，
   **从不终止任何进程**）：
   `python test/diagnostics/dismiss_modal.py 120 --log <日志路径>`
   白名单含 houdini / missing / not found / error / 警告 / 无法 / 找不到 等；
   DENY 清单（侦听器/调试器/升级）不点；已知 Max PID 时可加 `--pid <pid>`
   收紧范围（不带 `--pid` 时它是全局枚举、白名单是唯一防线，故仅限有人
   值守时使用）；标题不在白名单的弹窗它不会碰——那种请人工点；
3. **良性弹窗不是失败条件**：PASS 判定只看"存活 ≥120s + 桥接 ping 成功"，
   弹窗出现不计入；但"因弹窗导致桥接未起"按桥接未通处理。

**边界**：这些弹窗**不是 37 次崩溃的原因**（崩溃是引擎级 ucrtbase abort，
早于/独立于弹窗）。想永久消除属可选治理：不用 Houdini Engine 就禁用/卸载
该插件；材质编辑器弹窗需提供确切文本后单独诊断。均不影响测试判定。

### 3.7 插件清理后复跑与桥接模块语法缺陷修复（2026-10-20 09:24）

**复跑记录（第 38 次同签名崩溃）**【实测】：用户清理了一批阻挡插件后，09:24:27
按 §3.6 协议复跑（launch-watch 默认参数 + dismiss_modal 150s 伴随）。结果：
PID 13548，存活 **42.4s**，exit 0xC0000409，签名完全相同（ucrtbase+0xa527e /
fail-fast 7 / EPoly.dlo+0xe0930 栈），新 dump `3dsmax.exe.13548.dmp`
（228,286,932 B，SHA-256 21B3534B…919F）、新 WER（BEX64，BucketId e8620d54…，
Sig[4] 仍 9711）、事件 150541/150542。**dismiss_modal 零点击**——Houdini 弹窗
随插件移除已消失，崩溃仍早于任何弹窗阶段。插件清理**未消除崩溃**。

**重大对照发现（用户手动会话全部存活）**【实测】：bridge.log / loader.log 显示，
当天 09:14–09:21 用户**多次手动启动 Max 全部存活**（≥3 次自动加载器执行，全部
`state=LISTENING`；09:17:51 桥接 1170ms 监听、bridge.json pid=41004；
**09:21:21 首次记录到真实客户端连接** `net: accepted client, open=1`——用户通过
MCP 客户端连上过活桥接；该时段无任何崩溃事件/转储）。即：**插件清理后手动启动
可稳定存活**；而我的自动启动在用户会话结束后约 3 分钟仍崩——与"空闲后首启存活、
密集重试即崩"的历史模式一致（10-18/10-19 均如此），但样本仍少，待复验。

**桥接模块语法缺陷（已修复）**【实测】：`mcp_modeling_ext.ms` 自 10-19 22:20 起
每次实机加载都失败：`load: module failed: mcp_modeling_ext.ms -> -- Syntax
error: at max, expected =`，导致 **17/18 模块加载**。根因：两个函数把 MAXScript
**内建函数名 `max` 用作参数名**——
`fn mcpExtBACount ba max =` 与 `fn mcpExtBAIndices ba max limit:0 =`
（无括号多参数写法本身是本仓库惯例且可正常解析，如 mcp_animation.ms；问题仅在
`max` 这个内建 token）。已修复：参数改名 `max` → `n`（函数体与调用点同步，
调用点为位置传参不受影响），并加注释警示。**影响面**：该模块注册的 5 个命令
（mod_toggle / mod_collapse——含 collapse_stack 别名依赖的 confirm 门禁 /
poly_get_selection / poly_select / poly_get_elements）**在实机桥接中从未注册过**，
`test/live/modeling_ext_test.py` 的核心对象正是它们——即该测试即使 Max 存活也
从未具备通过条件。
**门禁盲区**【实测】：ms_check / offline_lint 的 .ms 检查只覆盖括号/字符串/编码，
查不出语法错误；本机 `3dsmaxbatch.exe` 不执行脚本，无离线 MAXScript 解释器——
此类缺陷此前只能靠实机 fileIn 暴露。建议后续评估引入 MAXScript 语法预检方案
（需用户批准，暂缓）。

**部署漂移**【实测】：仓库源文件已修复，但 ENU/CHS 部署树中的
`mcp_modeling_ext.ms` 仍是旧版（registration_sync 报 1 problem：deployed tree
drifted）。**在重新部署前，下次实机启动该模块仍会加载失败。** 重部署
（`python scripts/install.py --yes`，会为四个客户端配置留 .bak）需用户批准后
执行；如只求最小变更，也可经批准后仅将修复后的单文件同步到两棵脚本树。

### 3.8 实机验证战役：62/62 + 42/43（2026-10-20 11:30–15:10）

用户手动启动的 Max 会话（PID 45720，09:48 起）**存活至今未崩**——插件清理后的
首次长会话。Agent 通过桥接直接对活会话执行了完整验证战役：

1. **`modeling_ext_test.py`：62/62 全部通过（项目史上首次实机通过）**。
2. **`live_matrix.py` 43 用例：42 通过 / 1 失败**（LIVE_MATRIX.md 已重写为实测结果）。
3. 验证过程中发现并修复的缺陷（全部经 ms_check / catalog_contract / verify 门禁）：
   - `mcp_modeling_ext.ms`：`max` 内建名用作参数名 → 模块加载必败（§3.7）；
   - `mcp_modifiers.ms` mod_reorder：调用了不存在的 `moveModifierTo`（Max 2020 无
     任何重排序内建，7 个候选全部探针证伪）→ 改为"拷贝→删除→逆序重加"栈重建，
     参数值与自定义名称保留（已实测重排成功）；
   - `mcp_objects.ms` create_line：`setNumSplines`/`addPoint` 不存在 → 改为
     `SplineShape + addNewSpline + addKnot`（实测构建成功）；
   - `mcp_lights.ms` uvw_map：`mapping`/`u_Tiling`/`v_Tiling`/`w_Tiling` 属性名
     全错（实测应为 `maptype`/`utile`/`vtile`/`wtile`），且裸 `catch()` 吞错导致
     静默无操作 → 改正属性名并按桥接约定收集 failures；
   - `mcp_poly.ms`：poly_select_faces / poly_triangulate 的裸 `subobjectLevel=4`
     赋值在非修改面板上下文会抛错 → 包 try/catch（polyop 选择不依赖 level）；
   - `mcp_shading.ms`：mat_create 系列创建的材质未注册进 sceneMaterials，
     mat_get/mat_assign/mat_list 按名找不到 → mcpAssignCreatedMat 现按名称去重
     后注册；
   - `live_matrix.py`：sys.path 缺 test/static（文档记载的调用方式直接
     ImportError）→ 补齐；
   - 43 个用例中 24 个的 create_box 步骤缺必填 `class` 参数、及多处离线编写
     的预期与 Max 实测行为不符（Box 三角面数 12 而非 6、2x2x2 box 实测 26 顶点
     而非 27、材质需赋值后才进 sceneMaterials、Targetspot 实测类名字符串为
     targetSpot、UVWMap 属性名等）——已全部按实测修正。
4. **用户自己的桥接修复（10:14，未经 Agent）**【实测】：mcp_bridge.ms
   （mcpBridgeReadPort 的 port==undefined 回退）、mcp_core.ms（mcpResolveNode 的
   h==undefined 守卫）、mcp_scene.ms（mcpGet/SetPropByPath 的 idx==undefined 守卫）
   ——修复"as integer 对非数字返回 undefined 不抛异常"这一根因模式的三处实例，
   与 Agent 在 mod_reorder 发现的缺陷同类。工作树含这些改动，门禁全绿。
5. **遗留**：poly_triangulate 调用的 `n.triangulate()` 在 Editable_Poly 上不存在
   （Unknown property，实测）——三角化是 Editable_Mesh 概念，该工具需要语义
   决策（重定向到 mesh / 改为 EPoly 对角线操作 / 移除），**唯一未通过的用例**。
   部署漂移：mcp_bridge/core/scene（用户修复）未部署；活会话（09:48 启动）跑的
   是旧代码 + Agent 热重载的 6 个模块。**下次 Max 重启前需重新部署**（install.py
   或单文件同步），否则用户的 undefined 守卫修复不生效。
