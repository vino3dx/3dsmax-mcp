# Core 工具契约（离线基线）

本文定义 Python MCP 层对核心场景操作的稳定边界。它描述请求校验、错误和结果的共性；不把离线 fake bridge 的结果当作真实 Max 证据。

## 兼容名称

仓库当前使用更具体的工具名，以下是面向 Agent 的能力映射：

| 能力 | 当前工具 | 说明 |
| --- | --- | --- |
| create_object | `create_box`、`create_sphere` 等 | 保留按类型的旧接口；不要假设存在未注册的泛化工具 |
| transform_object | `transform_object` | 以对象名/对象列表和变换参数调用 |
| duplicate_object | `clone_objects` | 旧接口保留，返回值仍需结合场景读回 |
| delete_object | `delete_objects` | 破坏性操作；由客户端确认目标和保存策略 |
| apply_modifier | `mod_add` / `mod_set_param` | 通用入口；`mod_*` 是兼容薄包装 |
| assign_material | `mat_assign` | 先用 `mat_create_standard` 或 `mat_list` 确认材质 |

## 统一响应边界

变更工具在 `core` profile 中经过 Scene Runtime 时，结果至少包含：

```json
{
  "success": true,
  "operation": "create_box",
  "operation_id": "op-00000001",
  "changed": true,
  "warnings": [],
  "failures": [],
  "verification": {
    "performed": true,
    "passed": true,
    "detail": {}
  }
}
```

`success:false` 必须同时有 `failures`。常见失败类型为 `not_running`、`timeout`、`protocol_error`、`command_error`、`operation_failed` 和 `verification_failed`。桥接不可用时 MCP 响应必须带 `isError:true`，不得包装成成功结果。

## 离线证据边界

本契约可由 Python 静态测试、协议测试和 fake bridge 测试验证。对象是否真的创建、变换、复制、删除，修改器/材质是否真的落到 Max 场景，以及截图是否真实生成，必须由真实 Max live case 读回确认。
