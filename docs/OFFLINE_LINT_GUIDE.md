# 离线开发与静态检查指南

本指南面向在本仓库工作的开发者（人类或 AI 智能体）：**不启动 3ds Max、
不连 8765、不写注册表**，能把绝大多数问题挡在提交之前。

硬边界（所有离线工具共同遵守）：

- 不启动 / 关闭 / 操作任何 3ds Max 实例，不使用 `3dsmaxbatch.exe`；
- 不向 `127.0.0.1:8765`（及 e2e 的 8791–8795、契约测试的 8796）发任何数据；
  模拟桥接只绑本地回环，且由各自的测试自行启停；
- 不读改写注册表，不触碰 `%LOCALAPPDATA%` 下的部署树；
- 纯文本分析 + 进程内调用，断网也能全绿。

---

## 1. 七道离线关卡总览

| # | 命令 | 覆盖内容 | 退出码 |
|---|---|---|---|
| 1 | `python scripts/verify.py` | 全局完整性 umbrella：catalog ↔ MAXScript 注册一一对应、禁用构造、括号平衡、模块加载列表、速查表符号、**工具分布统计**、**文档数字对齐**、**第七关离线 lint**（见下） | 0/1 |
| 2 | `PYTHONPATH=src/python python -m maxmcp --selftest-python` | catalog 自洽 + 线编解码往返（含中文） | 0/1 |
| 3 | `PYTHONPATH=src/python python scripts/test_e2e.py` | MockBridge 顶替 Max 的端到端：stdio / HTTP / SSE / 鉴权 / 语言 auto | 0/1 |
| 4 | `python test/catalog_contract_test.py` | Python 层契约（第六关）：384 工具的 schema 合法性、preset 键、必填拒绝、类型强转、危险工具门禁表 | 0/1/2 |
| 5 | `python test/ms_check.py src/ms` | MAXScript 逐文件深报：编码、括号、方法链取成员、未定义 `mcp*` 符号 | 0/1 |
| 6 | `python test/registration_sync_test.py` | catalog ↔ `mcpRegister` ↔ 部署树（ENU/CHS）零漂移 | 0/1 |
| 7 | `python test/offline_lint_helper.py` | **本轮新增**：Python / MAXScript 源码 lint + catalog 工具定义审计（规则见第 3 节） | 0/1/2 |

第 1 关是 umbrella：它以进程内方式运行第 7 关（以及文档对齐审计），
把违例并入全局结果——**"verify 绿" 现在包含离线 lint**。想单独看 lint 的
聚焦报告，直接跑第 7 关；想入 CI，跑第 1 关即可。

---

## 2. 运行方式

```bash
python test/offline_lint_helper.py           # 人读报告，按检查组分节汇总
python test/offline_lint_helper.py --json    # 机器可读报告（violations/warnings/stats）
```

退出码：**0** = 干净（允许 warning）；**1** = 有违例；**2** =  harness 自身
故障（例如 catalog 突然 ImportError，属于树坏了而不是检出问题）。

warning 不拦提交，但会在 `verify.py` 末尾统一列出；violation 让第 7 关和
第 1 关同时红。

---

## 3. 第七关检查规则（每条规则都对应一个真实故障形态）

### 3.1 Python 源码（`src/python`、`scripts`、`test`；`examples` 参与语法/编码/命名检查）

| 规则 | 级别 | 为什么 |
|---|---|---|
| `ast.parse` 通过 | 违例 | 语法错误的文件根本跑不起来。catalog 之外的脚本（`scripts/`、`test/`）不在服务端 import 图里，只有 lint 能发现 |
| 严格 UTF-8 解码 | 违例 | 非 UTF-8 的 `.py` 在跨机器 checkout 后必出乱码 |
| 无 UTF-8 BOM | 告警 | Windows 下各工具对 BOM 态度不一，统一不加 |
| 使用的名字必须已导入/已定义/是内建 | 违例 | "在我机器上能跑"的经典根因：残留的 `sys.path` 条目掩盖了漏导入。AST 全程扫描（含函数体、注解、推导式），任一作用域有绑定即算绑定；`import *` 的模块跳过（看不全） |
| 导入未使用 | 告警 | 死导入。`__init__.py`（再导出门面）与 `__all__` 内的名字豁免 |
| 代码中无作者机器路径 | 违例 | `C:\Users\<你>\...`、`/home/<你>/...`、`%LOCALAPPDATA%` 等环境变量字面量。**注释和文档字符串先用 `tokenize` 掩码后**再扫，所以文档里的示例路径合法；`C:\Program Files`、`C:\Windows` 属于平台契约（安装器、诊断脚本正当引用），**不**算违例 |

### 3.2 MAXScript 源码（仓库内全部 `.ms`）

| 规则 | 级别 | 为什么 |
|---|---|---|
| 编码三选一：纯 ASCII / ANSI(GBK) / UTF-8 **带 BOM** | 违例 | MAXScript 的 `fileIn` 按 ANSI 代码页读文件；UTF-8 无 BOM 的含非 ASCII 文件会被错解码（Autodesk 仅支持 "UTF-8 with BOM"）。本关首跑即抓到真实案例：`examples/maxscript/listener_cheatsheet.ms` 含中文示例却是 UTF-8 无 BOM，已补 BOM 修复 |
| `()`/`[]` 平衡、字符串终止 | 违例 | 失衡即 `fileIn` 编译错误，整个桥接静默死亡。**复用 `ms_check.py` 的词法分析器**（`strip_code` / `check_structure`），不重写第三份 |

> 分工：`ms_check.py` 是逐文件深报（含方法链取成员、`mcp*` 符号），
> 第七关给的是全仓汇总视角；编码规则两边一致，结论不会互相矛盾。

### 3.3 catalog 工具定义（`src/python/maxmcp/catalog/` 全部模块）

| 规则 | 级别 | 为什么 |
|---|---|---|
| `description_zh` / `description_en` 均非空 | 违例 | 双语是硬契约，模型按任一语言都要能解析参数 |
| 描述无占位文本（TODO/TBD/FIXME/WIP/XXX/待补/待定/未完成） | 违例 | 半成品描述会原样进模型上下文 |
| 描述 ≥ 8 字符；zh/en 不相同；zh 含中文；en 不含中文 | 告警 | 常见偷懒：英文描述直接当中文用 |
| 参数 `type` 必须是六种 JSON 类型之一 | 违例 | `strng`/`int`/`float`/`bool` 这类拼写错误会让 schema 校验形同虚设 |
| `default` / `enum` 的值类型与声明一致 | 违例 | `isinstance(True, int)` 在 Python 里是 `True`——布尔默认值配 `integer` 类型是最容易漏的坑 |
| `minimum`/`maximum` 只用于数值类型且最小值 ≤ 最大值 | 违例 | 拼写错位到字符串参数上属于静默失效 |
| `array` 参数带 `items`；非 `array` 不带 `items`；空 `enum` | 告警 | DSL 之外的手写 schema 才可能触发 |
| `required` 的键都在 `properties` 里 | 违例 | 必填一个不存在的参数 = 永远无法通过校验 |
| `category` 属于八个已文档化分类 | 违例 | 分类拼错会让档位裁剪静默漏掉整个工具 |
| 工具名不跨模块重复 | 违例 | `Catalog.add` 直接抛错，重复注册让整个 catalog 起不来 |

**故意不查的**（边界，别在这里加戏）：

- 参数名大小写/风格—— catalog 实际是混合约定（多数 lowerCamelCase 对应
  MAXScript 属性名，vision 家族用 snake_case，桥接按精确名读取），
  本地启发式只会误报；
- 参数名 ↔ MAXScript `mcpXxx params "key"` 读取名的一致性——这是桥接
  契约，由第六关（preset 键白名单）与 `docs/BRIDGE_CONVENTIONS.md` 负责；
- 工具 ↔ `mcpRegister` 注册、部署树漂移、文档数字——分别是第 6、第 1 关
  （文档对齐审计）的职责。

---

## 4. 分布统计怎么读（`scripts/verify.py` 新增输出）

```
catalog distribution: 384 tools / 6 modules / 8 categories
  module     tools  mutating  read-only  dangerous  categories
  core          58        20         38          3  files=8 scene=17 system=33
  ...
  total        384       298         86         19  mutating share 77.6%
```

- **module**：catalog 源码模块（`core.py` 一个模块横跨 system/scene/files
  三个分类，所以模块数 6 ≠ 分类数 8）；
- **mutating / read-only**：写操作与只读操作占比，`readOnlyHint` 的来源；
- **dangerous**：名字带 `delete/remove/clear/collapse/reset/cleanup/
  optimize` 且 mutating 的工具数，与第六关的危险工具门禁表同一套令牌
  （定义在第七关，契约测试是门禁表的权威），两处数字必须一致（当前 19）。

新增工具后这张表就是最直观的"长在哪了"答案；review 时发现某个模块
mutating 占比异常，往往意味着 undo 标注漏了。

---

## 5. 日常自查流程

改完任何代码（Python、MAXScript、catalog、文档），按序：

```bash
python test/offline_lint_helper.py            # 7. 聚焦 lint，最快
python scripts/verify.py                      # 1. 全局（含 7 + 文档对齐 + 分布表）
python test/ms_check.py src/ms                # 5. MAXScript 深报（改了 .ms 才需要）
python test/registration_sync_test.py         # 6. 改了工具/注册/部署才需要
PYTHONPATH=src/python python -m maxmcp --selftest-python   # 2. 改了线编解码/文案才需要
```

新增一个工具的完整清单（与 `docs/BRIDGE_CONVENTIONS.md` 第 7 节配合看）：

1. `src/ms/mcp_*.ms` 加 handler + `mcpRegister`（undo 标注要如实）；
2. `src/python/maxmcp/catalog/<模块>.py` 用 `tool(...)` 声明（中英双语 +
   schema，参数类型用 `s/n/i/b/arr/num3`，别手写 dict）；
3. 跑第 7、1、6 关；涉及文档数字（总数/分类数/命令数）的改动，
   第 1 关的文档对齐审计会直接报漂移。

---

## 6. 常见违例与修法

| 报错 | 修法 |
|---|---|
| `name 'x' is used but never imported or defined` | 补 import；若确实是运行时注入，改用 `getattr` 或在模块顶部显式定义 |
| `unused import 'x'` | 删掉；`__init__.py` 的再导出请加进 `__all__` |
| `hardcoded user-profile path` | 改 `os.environ` / `Path.home()` / 相对仓库根（`__file__` 推导） |
| `environment-variable literal (use os.environ)` | `os.environ.get("LOCALAPPDATA")` 等；文档字符串里的示例路径不受影响（已掩码） |
| `.ms: utf-8 without BOM + non-ASCII` | 编辑器另存为 "UTF-8 with BOM"；纯 ASCII 文件则无所谓 |
| `parameter 'x' has unknown type 'strng'` | 改用 `s()/n()/i()/b()/arr()/num3()`，或手写时用六种合法类型名 |
| `default True does not match type 'integer'` | 类型改 `b()`，或默认值改数值——布尔不是整数 |
| `unknown category 'anim'` | 拼回 `animation`（八个分类见 `catalog/schema.py` 的 `PROFILES`） |
| `duplicate tool name` | 两个模块声明了同名工具，合并或改名 |
| `placeholder text in description` | 补写真实描述，中英各一句 |

---

## 7. 当前已知告警（不拦提交，清不掉再说）

树上有少量**先于本关存在**的死导入告警（`scripts/doctor.py`、
`src/python/maxmcp/server.py`、`test/` 下若干诊断脚本）。它们是 warning
级：`verify.py` 会列出但放行。要清零就删掉对应 import——但那属于各文件
owner 的决定，本指南只负责让它们**可见**。
