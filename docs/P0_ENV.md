# P0 环境诊断：3ds Max 2020 启动崩溃

> 本文档记录 3ds Max 2020 启动即崩（ucrtbase abort / 0xC0000409）的采证、实验与处置结论。
> 第一部分（T1，2026-10-19 凌晨，离线）：转储解析 + 运行库时间线 + KB 调查 + 根因判断。
> 第二部分（T2）：受控启动实验（空闲假设）与用户操作清单 —— 由过夜流水线后续补写。
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
