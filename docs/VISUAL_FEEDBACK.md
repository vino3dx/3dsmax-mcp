# 视觉反馈链路（Visual Feedback）

目标：让 Agent **看到**场景，而不是只收到 `{"ok": true}`。一条可靠的链路必须保证
"返回的确实是图片字节"，并且在图片不可用时报错，而不是只给一个文件路径。

## 1. 链路

```text
3ds Max 视口 / 渲染
  └─ mcp_vision.ms
       vision_capture  -> 抓活动视口，长边压到 max_edge（默认 800）
       vision_views    -> 依次切视图各抓一张，返回多张独立图
       vision_preview  -> 低分辨率渲染预览
       写临时位图 -> dotNet 编码 -> base64
       ↓
     {"count":1, "views":[...], "_images":[{"label":"perspective","data":"<base64>","mime":"image/jpeg"}]}
  └─ bridge（TCP，ASCII only）
  └─ server._split_images
       1. 找到 `_images`（顶层，或 runtime 信封里的 `data` / `result`）
       2. 每个条目 -> _image_bytes：base64 严格解码 / 读文件（白名单）/ 大小检查
       3. _validate_image_bytes：用文件头判定真实类型，声明的 MIME 只是提示
       4. 生成 MCP image content block
  └─ MCP content[]
       [ {"type":"text","text":"{...images 元数据...}"},
         {"type":"image","data":"<base64>","mimeType":"image/png"} ]
```

文本块始终保留：即使客户端不能渲染图片，也能看到 `images[].label` /
`mimeType` / `base64Chars` 以及 `image_errors`。

## 2. 校验规则（服务端）

| 规则 | 行为 |
| --- | --- |
| base64 | `base64.b64decode(..., validate=True)`；非法 -> `corrupt_image` |
| 空字节 | `empty image payload` -> 计入 `image_errors` |
| 文件头 | PNG `89 50 4E 47 0D 0A 1A 0A`、JPEG `FF D8 FF`、WEBP `RIFF....WEBP`；不匹配 -> `corrupt_image` |
| MIME | 以字节嗅探结果为准；声明 `text/plain` 但字节是 PNG -> 输出 `image/png` |
| 单图大小 | > 8 MiB -> 拒绝（`image_too_large` 语义） |
| 单响应总量 | base64 累计 > 12 MiB -> 后续图片被拒绝并记录原因 |
| 文件路径 | 必须解析到允许的截图根目录（默认：系统临时目录 + `~/.3dsmax-mcp`）；可用 `MAXMCP_IMAGE_ROOTS`（`os.pathsep` 分隔）或配置项 `image_roots` 追加 |
| 路径越权 | 目录白名单之外 -> `image path is outside the allowed screenshot roots` |
| 原始文件 | 只读，不修改、不覆盖任何截图文件 |

若某一张图失败：该图不产生 image block，但会在文本块的 `image_errors` 中出现，
并且整个工具结果标记 `isError: true`（部分成功不会伪装成成功）。

## 3. 配置

```bash
# 追加允许的截图目录（Windows 用 ; 分隔）
set MAXMCP_IMAGE_ROOTS=D:\shots;E:\render\previews
```

`~/.3dsmax-mcp/config.json` 中对应字段：

```json
{ "image_roots": ["D:\\shots"] }
```

## 4. 已知限制

- 只做文件头级别校验，不完整解码像素（无 PIL 依赖）；"文件头正确但数据截断"的图仍会通过。
- 不做自动压缩/重编码：缩放由 `mcp_vision.ms` 在生成阶段完成（`max_edge`），服务器不修改原图。
- `_images` 里的 `path` 形式目前只用于兼容/测试；生产路径应传 base64 `data`。
- **未在真实 3ds Max 上验证**：视口截图的实际编码格式、多视图批量返回、渲染预览图的体积。
  若真实输出与文件头不匹配，会被判为 `corrupt_image` —— 这是有意为之（宁可报错，不发垃圾字节）。

## 5. 测试

`test/static/image_result_test.py`（扩充）与 `test/static/vision_result_test.py`：

- 正常 PNG / JPEG 文件与内联 base64
- 文件不存在、空文件、损坏字节
- 声明 MIME 与字节不符（纠正为真实类型）
- 超大文件（>8 MiB）、单响应预算超限
- 路径越权与 `..` 解析
- 文本 + 图片混合返回
- runtime 信封内嵌 `_images`
- MCP `image` content block 的 JSON 序列化与 base64 往返

这些测试**不**证明"3ds Max 真的截到了正确的画面"，只证明"拿到字节之后的处理是对的"。
真实视口验证仍属于 `docs/OVERNIGHT_ACCEPTANCE.md` 的待验收项。
