# P2 工具面提案：profile 体系重构与一致性治理

> 本文档为 P2 设计输入，**不改任何代码**。所有数字由
> `maxmcp.catalog` 现场重算（Python 313，2026-10-19），标注【实测】；
> 估算方法随文给出。行号引用仓库 `D:\Workspace\Dev\3dsmax-mcp` 当前 HEAD
> （`2332415`）下的文件。

---

## 1. 现状量化（【实测】，重算自 catalog）

### 1.1 各 profile 工具数与上下文开销

口径：每个工具取 `to_mcp("zh", bilingual=True)` + MCP annotations 后
`json.dumps(ensure_ascii=False, separators=(",",":"))` 的 UTF-8 字节数；
token 估算 = 非 CJK 字符数 / 4 + CJK 字符数（双语描述下 CJK 约 1 token/字，
ASCII 约 4 字符/token；这是粗估，误差 ±20%，仅用于横向比较）。

| profile | 工具数 | JSON 字节 | 约 token |
| --- | --- | --- | --- |
| full | 384 | 370,018（361.3 KB） | ~95,730 |
| core（现状） | 119 | 132,483 | ~33,922 |
| modeling | 202 | 212,456 | ~54,813 |
| lookdev | 188 | 189,250 | ~48,588 |
| animation | 178 | 187,627 | ~48,266 |
| pipeline | 173 | 178,134 | ~45,826 |

**结论**：full 档一次性注入约 9.6 万 token 的工具描述，对多数客户端是显著固定
成本；现状 core 档（119 个）仍要 ~3.4 万 token，且只是"砍掉四个分类"，没有按
工作流频率筛选。

### 1.2 分类占比

| 分类 | 工具数 | 占比 | 字节 | 约 token |
| --- | --- | --- | --- | --- |
| modeling | 83 | 21.6% | 79,973 | ~20,892 |
| shading | 69 | 18.0% | 56,767 | ~14,667 |
| objects | 61 | 15.9% | 97,015 | ~24,658 |
| animation | 59 | 15.4% | 55,144 | ~14,344 |
| pipeline | 54 | 14.1% | 45,651 | ~11,905 |
| system | 33 | 8.6% | 19,825 | ~5,187 |
| scene | 17 | 4.4% | 10,798 | ~2,825 |
| files | 8 | 2.1% | 4,845 | ~1,252 |

objects 类字节数最高（61 个工具 97 KB）—— primitives 家族每个工具都带全套
尺寸参数描述（length/width/height/depth/radius/radius1/radius2/segments/sides...），
是单工具描述最重的分类。

---

## 2. 新 profile 体系提案

### 2.1 core 档候选清单（57 个，【实测】78.0 KB / ~20,468 token）

入选标准：**高频建模工作流**——"从空场景建成一个带材质和灯光的可编辑多边形
模型"这条主路径上的每一步，加上连接自检与文件存取。每个工具的入选理由：

**system（6）**

| 工具 | 理由 |
| --- | --- |
| bridge_status | 任何会话第一步；也验证语言/版本/场景计数 |
| bridge_ping | 最轻量心跳，断连判定 |
| bridge_capabilities | 本机命令清单，插件可用性探测（无文档客户的发现手段） |
| bridge_selftest | 环境 vs 参数问题的分界器 |
| get_max_version | 跨版本功能前的确认 |
| execute_maxscript | 万能逃生舱：没有专用工具时的唯一通路，必须常驻 |

**scene（5）**

| 工具 | 理由 |
| --- | --- |
| scene_info | 空场景门禁/进度确认的事实来源 |
| scene_new | 每个用例/每次重来的重置手段 |
| scene_save / scene_save_as / scene_open | 存取是工作流边界，不可省 |

**objects（20）**

| 工具 | 理由 |
| --- | --- |
| create_box/sphere/cylinder/cone/torus/teapot/plane/tube/pyramid/geosphere | 十种标准参数化几何体，硬表面建模起点 |
| create_line / create_rectangle / create_circle | 样条建模起点（Line 是唯一需要 points 的创建器） |
| transform_object | move/scale/rotate 统一入口，使用频率最高的对象操作 |
| clone_objects | 阵列/复制工作流核心 |
| rename_object | 后续按名引用的前提 |
| delete_objects | 清理频率极高；**危险工具，建议补 confirm 门禁**（见 5.2） |
| select_objects / get_selection | 选择是大多数编辑工具的实际输入（fallbackToSelection） |
| list_objects | 场景内容盘点 |

**modeling（18）**

| 工具 | 理由 |
| --- | --- |
| convert_to_editable_poly | 建模主路径的第一跳（其余 poly_* 都要求它） |
| poly_get_stats / poly_get_verts / poly_get_faces / poly_get_selection | 拓扑读数四件套，验证一切编辑的结果 |
| poly_select_faces | 面级选择，编辑的前置 |
| poly_extrude_faces / poly_bevel_faces / poly_inset_faces | 面编辑三件套（挤出/倒角/插入） |
| poly_chamfer_edges / poly_connect_edges | 边编辑两件套（卡线/连接） |
| poly_weld_vertices | 清理缝合 |
| poly_triangulate / poly_subdivide | 拓扑加密两路 |
| mod_add | 修改器统一入口（TurboSmooth/Bend/Symmetry 都可由它加） |
| mod_bend / mod_turbosmooth / mod_symmetry | 三个最高频修改器的薄包装（保留是为了省一次参数拼装） |

**shading（8）**

| 工具 | 理由 |
| --- | --- |
| mat_create_standard / mat_assign / mat_set_diffuse / mat_get / mat_list | 标准材质最小闭环（建/赋/改/读/列） |
| light_create_omni / light_create_spot | 两种基础灯光 |
| uvw_map | 贴图前必需（planar 覆盖 80% 场景） |

### 2.2 明确排除的类别及理由

| 排除对象 | 规模 | 理由 |
| --- | --- | --- |
| animation 全类 | 59 | 独立工作流（关键帧/控制器/约束/骨骼/IK），建模会话不需要；放入 animation 档 |
| pipeline 全类 | 54 | 渲染/烘焙/导入导出是一次性收尾任务，不是交互建模；放入 pipeline 档 |
| shading 长尾 | ~61 | PBR/Arnold/V-Ray/Corona/FStorm 材质创建器（按渲染器分裂，mat_create_arnold/vray/corona/fstorm 各自薄包装）、贴图槽位族、UVW 展开族——按需进 lookdev 档 |
| files 类 | 8 | read/write/list/exists 等是运维向；core 只保留经 scene_save/open 的文件通路 |
| system 长尾 | ~27 | set_language/undo/redo/hold/fetch、单位/时间配置、类反射族（list_max_classes/get_class_properties/...）——反射族恰好适合"按需发现"（见 4） |
| mod_* 薄包装长尾 | 22 | mod_ffd_2x2x2/3x3x3/4x4x4、mod_shell、mod_chamfer、mod_twist、mod_taper、mod_noise、mod_smooth、mod_lathe、mod_extrude、mod_sweep、mod_pathdeform、mod_displace、mod_relax、mod_subdivide、mod_weightednormals、mod_editpoly、mod_editnormals 等——全部可由 `mod_add` + `mod_set_param` 等价完成，纯为省参数拼装而占描述额度 |
| 第二梯队 primitives | ~9 | create_chamferbox/capsule/hedra/ngon/text/arc/helix/ellipse/donut 等——均可由 create_primitive(class:...) 覆盖 |

### 2.3 standard 档建议边界

**standard = core（57）+ 建模/着色第二梯队（上表排除项中的 objects 长尾 13 +
modeling 长尾 27 + shading 常用 11）≈ 128 个工具，【实测】153.1 KB /
~40,243 token**。即"core + 一个主攻分类的非薄包装工具"，与现有 named profile
（modeling=202）相比砍掉的全部是薄包装与按渲染器分裂的创建器。

分档建议（最终形态）：

| 档 | 工具数 | 约 token | 定位 |
| --- | --- | --- | --- |
| core | 57 | ~20.5k | 建模主路径，默认档 |
| standard | ~128 | ~40.2k | core + modeling/lookdev 非包装长尾 |
| full | 384 | ~95.7k | 现状保留，显式选择 |

---

## 3. 不一致清单（带 file:line，【实测】）

### 3.1 命名

1. **同概念两套家族前缀**：样条读写是 `spline_get_points`/`spline_set_points`
   （注册于 `src/ms/mcp_objects.ms:1045`），多边形读写是 `poly_get_verts`/
   `poly_set_vertex`。spline 与 poly 是同一层的两种几何，前缀分裂让
   "读取这个形状的点"依赖使用者记住对象类型。
2. **单复数混用**：`poly_set_vertex`（单个，`src/python/maxmcp/catalog/modeling.py`）
   与 `poly_move_vertices`/`poly_weld_vertices`（多个）并存；`poly_target_weld`
   参数名又是 `vertex`/`target`（单数）。
3. **通用入口 vs 薄包装并存**：`mod_add`（统一入口）与 20+ 个 `mod_*` 薄包装
   （如 `mod_bend`，`catalog/modeling.py:907`，preset 仅 `{"modifier":"Bend"}`）。
   两套都可以用，模型需要猜哪个是"正路"。
4. **info 后缀不统一**：`scene_info`、`get_system_info`、`get_max_version`、
   `poly_info`、`get_object_info`、`light_get`、`mat_get`——"读详情"有
   info/get/_info 三种写法。

### 3.2 参数风格

1. **`type` 一词两义**：`list_objects` 的 `type` 实际按 **superclass** 过滤
   （`src/ms/mcp_objects.ms:604-605`：`if typ != "" and (mcpSuperclass n) != typ`），
   而 `light_create` 的 `type` 是**灯光种类**（omni/spot/...，`src/ms/mcp_lights.ms:73-86`）。
   同一个参数名在不同工具里是不同维度的枚举。
2. **目标选择器六种写法**：`name`（get_object_info）、`object`（get_property_value）、
   `objects`（select_objects）、`material`（mat_get）、`light`（light_get）、
   `modifier`（mod_*）。都是"操作对象是谁"，没有统一约定。
3. **大小写混合**：主流 lowerCamelCase（keepScene/castShadows/materialId/uTiling），
   vision 家族却是 snake_case（`max_edge`，`src/python/maxmcp/catalog/pipeline.py:296,324,347`）。
   该例外有历史原因（桥接按精确名读取，见 offline_lint_helper 文档），但没有任何
   工具描述向使用者提示这一分裂。
4. **别名参数**：`create_primitive` 同时接受 `class` 与 `preset_class`
   （`src/ms/mcp_objects.ms:45-46`）、`name` 与 `setName`（同文件 `53-54`）。
   别名是隐式的，schema 里查不到。
5. **`name` 角色漂移**：create_* 里 `name` 是"要赋给新对象的名"；rename_object 里
   `name` 是"被改名的旧名"；`newName` 才是新名。

### 3.3 返回结构

1. **列表端点四种键名**：`objects`（list_objects，`mcp_objects.ms:624-628`）、
   `materials`（mat_list，`mcp_shading.ms:146-149`）、`lights`（light_list，
   `mcp_lights.ms:142-144`）、`modifiers`（mod_list，`mcp_modifiers.ms:167-170`）、
   `params`（mod_get_params）、`verts`（poly_get_verts，`mcp_poly.ms:250-254`）。
2. **分页回声不一致**：list_objects/mat_list/light_list 返回
   `{count, offset, limit, X}`；mod_list 与 poly_get_verts 也分页
   （`mcpPaginate`）但**不回声 offset/limit**（`mcp_modifiers.ms:165-170`）。
3. **message 键可有可无**：scene_new 有 `message`（`mcp_scene.ms:125-127`），
   bridge_status/scene_info 是裸扁平 dict（`mcp_system.ms:21-36`），
   poly_get_stats 是 `{objects, message}`（`mcp_poly.ms:352-355`）。
4. **创建类返回三种形态**：`{created:true,message}`（scene_new）/
   `{object:nodeInfo,message}`（create_line，`mcp_objects.ms:152-154`）/
   `{class,name,assignedTo,message}`（mat_create_standard，`mcp_shading.ms:109-116`）。
5. **布尔结果直裸**：convert_to_editable_poly 返回
   `{applied,failures,message}`（`mcp_poly.ms:119-122`）——applied/failures 是
   名字数组，但键名没有复数一致性约束（对比 `assignedTo`/`applied`）。

### 3.4 错误码

1. **err.* 码不暴露给客户端**：桥接内部有 13 个 err key、218 处 `mcpFail`
   （【实测】统计），消息表在 `src/ms/mcp_core.ms:35-52`；但线上错误信封只有
   `{"ok":false,"error":{"kind":"error","message":<本地化文本>}}`
   （`src/ms/mcp_net.ms:81-93`）。**码丢了，只剩随语言变化的文本**——客户端无法
   稳定分支（例如"缺参数"与"类不存在"在英文里都是句子）。
2. **kind 只有三态且混层级**：parse_error / serialize_error（传输层）与
   error（一切 handler 失败，`mcp_net.ms:116-124`）共用 kind=error，
   无法区分"参数错"与"Max 内部异常"。
3. **未走 mcpFail 的失败**：部分工具用 MAXScript 运行时异常冒泡到分发器
   （`mcp_net.ms:152-158` 的 catch 分支），文本是 `getCurrentException()`，
   与 err 表的双语格式完全不同源。
4. **3 处 mcpFail 缺 a1 上下文**（`mcp_core.ms:407`、`mcp_objects.ms:546`、
   `mcp_modeling_ext.ms:538`），错误文本退化为无参数模板。

---

## 4. "元工具按需发现"方案评估

候选：`list_tools`（只读发现：返回工具名+分类+一句话）与
`enable_category`（会话内动态增删分类，工具列表随之变化）。

| 维度 | list_tools | enable_category |
| --- | --- | --- |
| 上下文节省 | 中（用 ~1-2k token 的索引替代 20-40k 的描述，但每次要用工具仍需读它的描述） | 高（按需只加载一个分类，~5-15k token） |
| 实现代价 | **低**。bridge_capabilities 已是原型（`mcp_system.ms:64-95`）；catalog 侧加一个返回 name/category/一句话的入口，估 0.5-1 天 | **中高**。需要服务端动态 profile 状态 + MCP `notifications/tools/list_changed` 推送；客户端对动态工具列表支持参差（部分客户端启动时缓存后不再刷新），估 2-3 天 + 兼容性测试 |
| 协议风险 | 无（纯只读，不动 tools/list） | 有（依赖客户端正确处理 list_changed；坏客户端会"看不到新工具"或"缓存陈旧"） |
| 失败模式 | 无状态，最坏多一次调用 | 会话状态机（启用了谁、重启后恢复什么）、与 --profile 启动参数的关系都需要定义 |
| 与现状关系 | 与静态 profile 正交，可立即上线 | 与静态 profile 功能重叠，引入第二套真相 |

**推荐：先做 `list_tools`，暂缓 `enable_category`。** 理由：full 档 9.6 万 token
的成本主要来自"一次性全量描述"，而 core 档瘦身到 ~2 万 token 后，剩余痛点是
"想用 core 外的工具时不知道它存在/长什么样"。`list_tools` 正好补这个缺口，
零协议风险。备选（若未来测量显示按需加载确实必要）：不做动态增删，而是把
`enable_category` 降级为**会话启动参数**（`--profile core,modeling` 的已有能力，
`catalog/schema.py:121-128` 的 PROFILES 就是干这个的），让客户端在连接时选档，
避免会话中动态变更。

---

## 5. P2 实施任务拆分（含验收标准）

> 以下任务均**不改 MAXScript 行为**，除 5.2/5.3 外均为 catalog/文档层改动；
> 每个任务独立可回滚，遵循仓库既有门禁（ms_check / registration_sync /
> verify / catalog_contract / e2e / offline_lint 全绿才提交）。

### 5.1 core 档落地（57 工具）
- 改动：`catalog/schema.py` PROFILES 增加显式 core 集合（按 2.1 清单），
  原 BASE_CATEGORIES 组合保留为 internal 名或直接替换；README/文档统计同步。
- 验收：`doc_alignment_audit` 重算的 profile 表与新 core 一致；core 档
  `--json` 机器报告字节数与本文 2.1 表偏差 < 5%；`catalog_contract_test`
  384 工具 0 违例。

### 5.2 delete_objects 补 confirm 门禁
- 改动：对齐 collapse_stack/mod_collapse 既有模式（catalog preset confirm +
  MAXScript 侧 confirm 检查，`err.confirm_required`）。
- 验收：缺 confirm 调用被拒且错误可分支；带 confirm 正常删除；
  live_matrix 增补一条 expect_error 用例（缺 confirm → 失败）。

### 5.3 错误码暴露（wire 层）
- 改动：`mcp_net.ms` mcpErrJson 增加 `code` 字段（err key 原样传出），
  Python `bridge.py` `_parse` 把 code 带进 `BridgeCommandError.detail`；
  handler 内 mcpFail 的 3 处缺 a1 的补上参数。
- 验收：缺参数/类不存在/对象不存在三种错误在客户端可凭 code 区分；
  `test_e2e`（MockBridge 链路）增断言；中英文消息文本不变（回归）。

### 5.4 list_tools 元工具
- 改动：catalog 增加 list_tools（name/category/一句话双语描述），MAXScript 侧
  复用 mcpRegistry 注册表（mcp_bridge 注册即出现），不进 undo 体系。
- 验收：`verify.py` 注册一致性通过（新命令有注册有 catalog 条目）；
  `catalog_contract_test` 覆盖其 schema；live_matrix 加一条用例
  （list_tools → count == 注册命令数）。

### 5.5 命名与参数一致性清理（分批，每批一个主题）
- 改动主题（按风险从低到高）：(a) 别名参数文档化（preset_class/setName 在
  描述中注明"等价于 class/name"）；(b) `type`→`superClass` 更名
  （list_objects，桥接侧兼容读取旧名一个版本）；(c) spline_* 与 poly_* 家族
  统一为 shape_*（或文档明确分裂理由）。
- 验收：每批提交后 `registration_sync_test` 零漂移 + `catalog_contract_test`
  全量 + 文档统计同步；更名批必须带旧名兼容期与 live_matrix 对应用例更新。

### 5.6 standard 档与文档
- 改动：按 2.3 增加 standard profile；README profile 表、docs/tools.txt 说明、
  CHANGELOG 记录分档策略与 token 数据。
- 验收：`doc_alignment_audit` 通过；三个档位的 token 估算表进 README（方法注明）。

### 5.7 live_matrix 扩充（P1 延续）
- 改动：cases 从 43 扩到 120+（覆盖 standard 档全部非危险工具 + 每渲染器一个
  材质创建器标记"不适用"除非本机装有该渲染器）。
- 验收：`--list` 用例数 ≥ 120；对 mock 的 self-test 仍全绿；实机通过后
  docs/LIVE_MATRIX.md 的"未验证"列归零于 standard 档范围。

---

## 6. 附：本提案的未确认事项

- token 估算为粗估（ASCII/4 + CJK/1），不同分词器差异可达 ±20%；结论
  （full ≈ 9.6 万 >> core ≈ 2 万）在误差内成立，但精确值【未确认】。
- `enable_category` 的客户端兼容性未经实测（本机 Claude Desktop 未安装），
  代价评估基于 MCP 规范语义【推测】。
- 5.5(c) 的家族更名影响面未做全量 grep 统计，动手前需补一次影响清单。
