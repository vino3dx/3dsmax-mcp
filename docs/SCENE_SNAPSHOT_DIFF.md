# 场景快照与差异（Stage 3 / 阶段 C）

`scene_snapshot` 回答一个问题：**刚才那一串操作，到底把场景改成了什么样？**

它的价值全在"证据"两个字上：只写真实读回的值，读不到的字段标 `unknown`，
无法证明的身份说"不确定"，绝不把猜测写进 diff。

代码：`src/python/maxmcp/scene_state.py`（构建/比较）、`src/python/maxmcp/server.py`
（`scene_snapshot` 工具、分页读取、快照缓存）。工具本身是 `local=true`，
没有新的 MAXScript 命令。

## 1. 快照怎么来的

```text
scene_snapshot
  -> list_objects 分页（每页 200，最多 40 页 / 5000 节点）
  -> get_selection（读不到就是 None，不是空数组）
  -> scene_state.build_snapshot(...)
```

```json
{
  "success": true,
  "snapshot_id": "snap-0001",
  "nodes": { "Box001": { "name": "Box001", "handle": 12, "class": "Box",
                          "position": [0,0,0], "rotation": [0,0,0], "scale": [1,1,1],
                          "material": "Material #1", "modifiers": [] } },
  "node_count": 1, "reported_count": 1,
  "selection": ["Box001"], "selection_read": true,
  "summary": { "count": 1, "classes": {...}, "materials": [...] },
  "complete": true, "truncated": false,
  "partial_nodes": [], "missing_fields": [], "handles_unique": true,
  "warnings": []
}
```

判定规则：

| 字段 | 规则 |
| --- | --- |
| `complete` | `truncated=false` **且** 无缺失字段 **且** 收集数 ≥ Max 报告数 **且** 选择集读到 |
| `truncated` | 页数/条数上限截断，或收集数 < `reported_count` |
| `partial_nodes` | 该节点有字段没读到，或**名称重复**（重名的第二个节点不会被覆盖，而是记在这里） |
| `missing_fields` | 整个快照里哪些字段本版 Max 没给（进入 `warnings[]`） |
| `handles_unique` | 所有节点都有正整数 handle 且互不相同；否则 handle 不能用来证明身份 |

缺失 ≠ 没有：字段没读到只进 `missing`，不会被当成 `null` 或"该属性不存在"。
`getHandleByAnim` 失败返回 0，`0` 一律视为"没有 handle"。

## 2. 差异有哪些分类

```json
{
  "added": ["Ground", "Wall"],
  "removed": ["OldBox"],
  "modified": [ { "name": "Cube", "fields": { "position": {"before": [...], "after": [...]} } } ],
  "renamed": [ { "from": "Box001", "to": "Box_Main", "handle": 12 } ],
  "identity_uncertain": [ { "name": "Box_Main", "candidates": ["Box001"],
                            "reason": "handle_missing", "message": "..." } ],
  "unknown": [ { "name": "Ball", "fields": ["material"] }, { "name": "<selection>", "fields": ["selection"] } ],
  "unchanged": 3,
  "complete": true,
  "counts": { "before": 5, "after": 6, "changed": 3, "selection_before": 0, "selection_after": 1 },
  "selection": { "added": ["Cube"], "removed": [], "unchanged": [], "read": true }
}
```

比较的字段是固定的 8 个：`name / handle / class / position / rotation / scale /
material / modifiers`。分类含义：

| 分类 | 含义 |
| --- | --- |
| `added` / `removed` | 名称在前后快照里只出现一次 |
| `modified` | 同名字段值不同；`fields` 给出 `{before, after}` |
| `renamed` | 同一个唯一 handle 换了名字（不是"删除+新增"） |
| `identity_uncertain` | 看起来像重命名，但**证不出来** |
| `unknown` | 有一侧没读到该字段，无法比较 |
| `unchanged` | 所有可比字段都相同 |

## 3. 三条容易做错的规则

### 3.1 重命名不能算成"删除 + 新增"

`Box001` 改名成 `Box_Main`，如果按名称比对，会得到 `removed:["Box001"]` +
`added:["Box_Main"]`——读起来像"删了一个又建了一个"，这是**不存在**的破坏性变化。
所以改名走 `_match_renames`：前后各有一个**唯一** handle 相同、且 class 仍然一致，
才认定为 `renamed`，同时在 `modified` 里留一条带 `previous_name` / `renamed:true` 的记录。

### 3.2 证不出来的身份就说证不出来

以下情况一律进 `identity_uncertain`，不做猜测：

| `reason` | 情况 |
| --- | --- |
| `handle_missing` | 新名字这一侧没有可用 handle（0 或缺失） |
| `handle_duplicated` | 同一 handle 出现在多个节点上 |
| `handle_not_in_before` | handle 在旧快照里找不到对应 |
| `class_mismatch` | handle 对得上，但 class 变了（可能是复用了 handle 的新对象） |

`identity_uncertain` 的条目**不会**同时出现在 `added`/`removed` — 它们是悬而未决，
不是已判定。调用方要么接受"确实删了一个又加了一个"，要么自己再查。

### 3.3 名称不是唯一身份

Max 允许两个对象同名。`list_objects` 会把两个都返回，但快照以名称为键，
所以第二个节点会被记进 `partial_nodes` 且 `complete=false`——**不会**静默覆盖成
"只有一个"。在这种场景里，名称无法定位对象，diff 只能说明"有个同名对象存在"。

## 4. 数值比较与容差

- 浮点用容差比较，默认 `1e-4`，可用 `tolerance` 参数调整。
- 旋转按欧拉角 360° 环绕比较（359° 与 -1° 是同一个朝向），仅在
  `compare_absolute` 这条绝对校验路径上使用；diff 里仍是数值比较。
- `null` / 缺失 / 非数字三者不可比 -> 进 `unknown`，不判"变了"也不判"没变"。

## 5. 基线：`baseline` 参数

```text
scene_snapshot                                  -> snap-0001（同时成为候选基线）
... 做一堆操作 ...
scene_snapshot {"baseline": "snap-0001"}        -> 返回本次快照 + diff
```

- 快照缓存是内存里的环形缓冲，最多 8 份（`MAX_SNAPSHOTS`），先进先出。
- 未知 id -> `success:false` + `invalid_arguments`，并在 `known` 里列出还有哪些 id。
- 进程重启后基线全部失效：**基线不能跨会话**。需要长期对比就自己保存
  `scene_snapshot` 返回的 `nodes` JSON（这就是"部分/完整快照"都能拿到的原因）。

## 6. 与工作流的关系

`workflow_run` 用同一套代码在前后各拍一次快照：

```text
before = snapshot()  ->  执行步骤  ->  after = snapshot()  ->  diff_documents(before, after)
```

- 任一快照失败 -> `diff: null` + `warnings[] = snapshot_unavailable`，**步骤照常执行**，
  只是没有前后对比（不因为没有对比就把工作流判失败）。
- `expect` 断言（`added_includes` / `count_delta` …）就是拿这个 diff 去核对的，
  没有 diff 时 `expectation.performed=false, passed=null`。
- 选择集未读到时，`diff.selection.read=false` 且 `unknown[]` 里有一条
  `<selection>`——"没读到选择集"不等于"选择集没变"。

## 7. 边界

- 快照只记录 8 个字段：几何体之外的属性（UV、材质参数、灯光强度、修改器参数）
  不在里面。要核对它们用 `verification` 的对应 kind（`material` / `modifier` /
  `payload_number`）或直接读 `get_object_info`。
- 快照不判"好不好"，只判"变没变"。目标是"把这个球移到 (50,0,20)"，由
  `verification.kind=transform` 判断，不由 diff 判断。
- 分页读取是有上限的：超 5000 节点会 `truncated:true`，diff 只能描述读到的那部分。
