# P0 单次受控复验报告（2026-10-20）

- 日期：2026-10-20（记录于 08:20）
- 仓库：`D:\Workspace\Dev\3dsmax-mcp`，写入前 HEAD `99ef002`（工作区含 P0-Next-3
  未提交改动：过夜循环废弃桩 + `scripts/max_health.py` 诊断增强 + P0_ENV.md 停用公告）
- 执行方式：有人值守**单次** `python scripts/max_health.py launch-watch --json`
  （默认参数：survive 120s / watch 300s / poll 1s / ping-every 5s / evidence-grace 30s）。
  用户已确认当前没有未保存的日常 Max 工作。仅 1 次启动：未循环、未并行、未自动重试。
- 约定：【实测】= 有 dump / 事件 / WER / 文件时间戳 / 退出码证据；【推测】= 无直接证据；【存疑】= 证据不足或归因冲突。

---

## 1. 启动前检查（7/7 通过）

| # | 检查项 | 结果 |
| --- | --- | --- |
| 1 | `3dsmax.exe` 进程枚举 | 0 个（CIM + tasklist 双通道；启动前 1 分钟复核仍为 0） |
| 2 | TCP 8765 监听 | 无监听，无归属不明 |
| 3 | `max_health.py` 版本 | 符合 P0-Next-3 预期（py_compile OK；监视参数未变；终止面 grep 零命中） |
| 4 | Max 可执行文件 | `C:\Program Files\Autodesk\3ds Max 2020\3dsmax.exe` 存在，与脚本 `MAX_EXE` 一致 |
| 5 | launch-watch 终止行为 | 不关闭/不终止任何进程（仅 `Popen` 启动；残留即中止） |
| 6 | 过夜循环 / dismiss_modal | 均未运行（在运行的 python 仅本会话 maxmcp MCP 客户端） |
| 7 | 证据采集初始化 | 正常：基线 9 个历史 dump、WER 24h 窗 0 条、事件日志可用（1 条历史 AppHangTransient） |

环境说明【实测】：本机 Bash 工具沙箱会在命令完成时树杀子进程（眠进程实测被杀），
故本次启动以脱离沙箱的前台方式执行，保证 PASS 情形下 Max 可留存（本例未 PASS，该机制
未被触发）。

## 2. 本次启动与结果

| 项 | 值 |
| --- | --- |
| PID | **43016** |
| 启动时间 | 2026-10-20 07:59:40（事件日志 ProcessCreationTime 07:59:40.63 精确吻合） |
| 存活时长 | **39.8 秒**（Application Error 事件 08:00:02；WerFault 收集约 18s 后进程完全退出） |
| 退出码 | **3221226505 = 0xC0000409** |
| 桥接 Ping | 从未连接（connection refused）；自动加载器未执行（loader.log / bridge.log 仍停留在 10-19 22:20:13） |
| 判定 | **FAIL**（存活 39.8s < 120s 且桥接未通，DoD 未满足） |

## 3. 证据固化（只读：未移动、未删除、未覆盖）

| 证据 | 路径 | 大小 | 时间戳 | SHA-256 |
| --- | --- | --- | --- | --- |
| 新转储 | `C:\Users\Vino\AppData\Local\CrashDumps\3dsmax.exe.43016.dmp` | 228,345,268 B | mtime 2026-10-20 08:00:17（created 08:00:15） | `02681F05B2FB2F6A2D0767D1CF13E39E5F4F370DB1E9FFE5BA6C4ACA9F8B45E2` |
| 新 WER 报告 | `C:\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_3dsmax.exe_e8c173fca3e53694db2ff8127dcca5296817295e_cf62a662_35d51f17-6f79-4634-9166-42ebeea78c16\Report.wer` | 173,350 B | dir mtime 2026-10-20 08:00:15 | `2F92FC1754EDF0B4B1A25A3E5603AF958185DB8D7013637D57FF5F93B613C63A` |
| 事件 150511 | Application 日志，Application Error / Event ID 1000 | — | 2026-10-20 08:00:02 | （事件记录，无文件哈希） |
| 事件 150512 | Application 日志，Windows Error Reporting / Event ID 1001（BEX64） | — | 2026-10-20 08:00:15 | （事件记录，无文件哈希） |

事件 150511 关键字段【实测】：AppName=3dsmax.exe（22.0.0.757 / 0x5c7f03ff）、
ModuleName=ucrtbase.dll（**10.0.26100.9711** / 0x3f426c5b）、ExceptionCode=c0000409、
FaultingOffset=0xa527e、**ProcessId=0xa808=43016**、ProcessCreationTime=0x1dd6025e7952187
（=07:59:40.63）、Report ID=e7d89d6f-2529-434d-847b-951159b5dd47。
WER 报告目录关键字段【实测】：EventType=BEX64、Sig[3]=ucrtbase.dll、
Sig[4]=**10.0.26100.9711**、Sig[6]=0xa527e、Sig[7]=c0000409、Sig[8]=7、
Response.BucketId=e8620d5477cec2e96ef6ec3989e9c619。

## 4. 关联链（PID 43016 ↔ dump ↔ WER ↔ 事件）

四源互证，无缺口【实测】：
1. `launch-watch` 报告：PID 43016，`new_crash_dumps=[3dsmax.exe.43016.dmp]`（WER LocalDumps 以 PID 命名）；
2. 事件 150511：ProcessId=0xa808=43016、ProcessCreationTime=07:59:40.63 与启动时间精确吻合；
3. 时间窗：dump 落盘 08:00:17、WER 报告 08:00:15、事件 08:00:02/08:00:15，全部落在
   看护窗口 07:59:40–08:00:22 内；
4. 字段一致：异常码 0xC0000409 / 偏移 0xa527e / 故障模块 ucrtbase.dll / fail-fast 7 在
   dump、WER、事件三处完全相同。

历史证据未混入【实测】：启动前基线为 9 个历史 dump（最新 10-19 04:29:30，早于本次 27 小时）
与 1 条历史限挂事件（10-19 22:20:15）；diff 仅产生本次 4 项新增（见上）。
附注【实测】：CrashDumps 目录按应用滚动保留——本次新 dump 落盘时，07:19 尚在的一枚
最旧 3dsmax dump 已被系统移除（asus_framework dump 不受影响）；WER ReportArchive
不受此影响，42 条历史报告 + 本次 1 条全部在档。

## 5. 崩溃签名与 UCRT 版本变化（本轮最重要新事实）

**签名核对【实测】**：0xC0000409 / ucrtbase.dll + 0xa527e / fail-fast 7
（FAST_FAIL_FATAL_APP_EXIT，即主动 abort）/ 最近导出 `abort + 78` 字节；
崩溃线程栈扫描顶部：ucrtbase+0x116108 → ~terminate+30 → ~__std_terminate+9 →
**EPoly.dlo + 0xe0930** → …，与 1.2 节两个历史样本逐偏移相同。这是该签名的
**第 37 次**崩溃（24 次历史 + 12 次受控实验 + 本次 1 次）。

**UCRT 版本变化【实测】**（WER Report.wer 的 Sig[4] 逐条比对）：

| WER 报告时间 | 故障模块版本 | 偏移 |
| --- | --- | --- |
| 2026-10-20 08:00:15（本次） | **10.0.26100.9711** | 0xa527e |
| 2026-10-19 04:29:27 | 10.0.26100.9444 | 0xa527e |
| 2026-10-19 04:07:56 | 10.0.26100.9444 | 0xa527e |

- 磁盘 `C:\Windows\System32\ucrtbase.dll` 当前为 10.0.26100.9711（mtime 2026-10-17 09:46:47）。
  即 10-19 04:29 之后 UCRT 已换版，最可能随 10-19 12:39–12:44 的更新批次与重启落地
  （MoUsoCoreWorker 12:39:10 / TrustedInstaller 12:43:48 / 重启 12:44:10）；
  文件 mtime 与实际生效副本的切换机制【存疑】（更新服务的硬链接/延迟生效细节无法从
  本机直接确认）。
- **版本变化未消除该崩溃【实测】**：异常码、偏移、fail-fast 子码、栈形状全部不变，
  连 abort 调用点 RVA 0xa527e 在两个 UCRT 构建中完全相同。WER BucketId 因模块版本
  改变而变化（8ebcaa78… → e8620d54…），属签名连带变化，非新故障模式。
- **但不得据此认定 Windows 更新为根因【存疑】**：无任何因果证据——历史上唯一的存活
  启动（10-19 22:20:13）也发生在该重启之后；9444 版本期间同样既有崩溃也有存活。
  版本更迭只是证明了"换 UCRT 不修复"，未证明"更新导致崩溃"。

## 6. 与插件无关的再次印证

- 本次 loader.log / bridge.log **无任何新条目**（仍停留在 10-19 22:20:13）——
  自动加载器未执行，崩溃早于任何 MAXScript 运行【实测】。
- 崩溃线程栈上无本插件模块（.ms 不走原生 DLL）【实测，沿用 1.3 节结论】。

## 7. 结论

1. 本次单次复验 **FAIL**：存活 39.8s < 120s、桥接未通、退出码 0xC0000409。
2. 第 37 次同签名崩溃；UCRT 已从 9444 换为 9711 但崩溃不变（更新未修复，亦未证明是根因）。
3. EPoly.dlo + 0xe0930 仍是**待验证线索**（见 P0_ENV.md 1.2/1.6 的局限声明），不是根因判定。
4. **本轮未执行任何系统修复、未重复启动、未启动第二次测试**；未修改任何证据文件。
5. DoD（同配置连续 5 次 PASS）仍未满足；是否需要继续复验由用户决定。

## 8. 未确认事项

1. UCRT 9711 的确切生效时间与机制（mtime 10-17 09:46 vs 推测的 10-19 12:39 批次落地）。
2. 10-19 22:20 成功启动时加载的是哪个 UCRT 版本（无转储，无法回查）。
3. EPoly.dlo+0xe0930 的真实函数与抛出原因（需完整转储 + 符号，见第 9 节）。
4. 触发条件（为何偶发可存活、为何 10-17 起才出现）仍未知。

## 9. 下一步（均需用户批准后执行）

1. 把本报告结论并入 `docs/P0_ENV.md` 第三部分（已随本轮提交文档更新完成）。
2. 证据增强：下次崩溃现场用 Sysinternals procdump `-ma`（或把 WER LocalDumps 的
   DumpType 改为 2）抓**带模块映像的完整转储**，即可对 EPoly.dlo+0xe0930 做 .pdata
   完整 unwind，坐实或排除抛出点。所需工具与操作：安装 procdump（或改注册表 DumpType）
   ——**本轮未安装、未下载、未修改任何系统设置**。
3. 符号化（可选）：WinDbg + Microsoft 公共符号可命名 ucrtbase/系统帧；EPoly.dlo 无
   公共符号，即使 WinDbg 也只能给出偏移——需提前管理预期。
4. 系统级修复仍按 P1（禁用 GameViewer 虚拟显示适配器）→ P2（卸载 10-17/10-19 更新
   或系统还原）→ P3（修复 Max 与 VC++ 运行库）排序，每步后单次复验。
5. DoD 5 连发需用户批准执行窗口与尝试间关闭 Max 的责任人；严禁使用已停用的过夜循环脚本。

---

## 10. 复跑记录（09:24，用户清理阻挡插件后，第 38 次同签名崩溃）

按 §3.6 弹窗处置协议复跑：`launch-watch --json`（默认参数，唯一一次）+
`dismiss_modal.py 150` 伴随。

| 项 | 值 |
| --- | --- |
| PID / 启动 | 13548 / 2026-10-20 09:24:27 |
| 存活 / 退出码 | **42.4s** / 3221226505（0xC0000409） |
| 桥接 | 从未连接；自动加载器未执行（崩溃早于脚本） |
| 判定 | **FAIL**（第 38 次同签名崩溃） |
| 新证据 | dump `3dsmax.exe.13548.dmp`（228,286,932 B，mtime 09:25:08，SHA-256 `21B3534B9945C5A78A934C7E9BA1FD091C198521EAEC6F3EDBD18AFAA173919F`）；WER `AppCrash_3dsmax.exe_e8c173fc…13595cca…`（09:25:05，BEX64，BucketId e8620d54…，Sig[4]=9711）；事件 150541（Application Error 1000 @09:24:46）+ 150542（WER 1001 @09:25:05） |
| 签名 | 0xC0000409 / ucrtbase.dll+0xa527e / fail-fast 7 / abort+78；栈顶 ucrtbase+0x116108 → ~terminate+30 → ~__std_terminate+9 → **EPoly.dlo+0xe0930**（与历史样本逐偏移相同） |
| 弹窗 | dismiss_modal **零点击**（Houdini 弹窗随插件移除消失；崩溃早于弹窗阶段） |

**同日对照（用户手动会话，09:14–09:21）**【实测】：≥3 次手动启动**全部存活**，
自动加载器全部 `state=LISTENING`；09:17:51 桥接 1170ms 监听（bridge.json
pid=41004）；**09:21:21 `net: accepted client, open=1`——首次记录到真实客户端
连上活桥接**；该时段零崩溃事件/零转储。结论：插件清理后**手动启动可存活**；
用户会话结束约 3 分钟后的自动启动仍崩（42.4s）——符合"空闲后首启存活、密集
重试即崩"历史模式，样本待扩充。

**顺带发现并修复的桥接缺陷**：`src/ms/mcp_modeling_ext.ms` 自 10-19 22:20 起
实机加载必失败（`Syntax error: at max, expected =`，17/18 模块），根因是
`fn mcpExtBACount ba max =` / `fn mcpExtBAIndices ba max limit:0 =` 将 MAXScript
内建函数名 `max` 用作参数名。已改名 `max` → `n` 修复（ms_check 0 problems、
catalog_contract 580/580、verify 全绿；registration_sync 报部署漂移 1 problem
——**重部署前实机仍加载失败**，待用户批准）。影响：mod_toggle / mod_collapse /
poly_get_selection / poly_select / poly_get_elements 五个命令在实机桥接中从未
注册，modeling_ext_test.py 的核心对象即它们。详见 docs/P0_ENV.md §3.7。
