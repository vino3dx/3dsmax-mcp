# 示例提示词 / Example prompts

直接粘给 Cursor、Claude 或任何接了 `3dsmax-mcp` 的客户端。
每条都写得足够具体，方便验证 AI 是否真的调用了正确的工具。

---

## 1. 建模：硬表面基础件

> 创建一个 100×100×20 的盒子当作底座，在它上方建一个半径 30 的球体，
> 球体中心抬高到 Z=50。球体加 TurboSmooth 2 级，底座不要平滑。
> 把两个对象放进一个名为 `Prop_Base` 的组。

预期工具：`create_box`、`create_sphere`、`transform_object`、`mod_turbosmooth`、`group_objects`。

---

## 2. 建模：可编辑多边形造型

> 建一个 4 段×4 段×4 段的盒子，转成可编辑多边形，选中顶部所有面向上挤出 15，
> 再对挤出的面做 3 的倒角。最后用 `optimize` 减掉 40% 的面。

预期工具：`create_box`、`convert_to_editable_poly`、`poly_select_faces`、`poly_extrude_faces`、`poly_bevel_faces`、`poly_optimize`。

---

## 3. 材质：PBR 金属

> 新建一个 Physical Material，命名 `M_Metal_Brushed`，
> 基础色 0.72 灰、金属度 1.0、粗糙度 0.28。赋给名字里包含 `_Metal` 的所有对象。

预期工具：`mat_create_physical`、`mat_set_pbr`、`find_objects`、`mat_assign`。

---

## 4. 材质：批量替换贴图路径

> 场景里所有材质的漫反射贴图路径现在指向 `D:\old_tex\`，
> 全部改成 `D:\new_tex\`，只改路径，别动文件名。

预期工具：`mat_list`、`mat_get`、`mat_get_map_slot`、`mat_set_property`。

---

## 5. 渲染：三点布光 + 静帧

> 给当前场景摆一个标准三点布光（主光 45° 前上方、补光对侧较弱、背后一盏轮廓光），
> 建一个物理相机对准原点，设置渲 1920×1080、V-Ray 引擎、采样 128，
> 输出到 `D:\renders\` 下以场景名命名。

预期工具：`light_create_spot`、`light_create_omni`、`light_create_directional`、
`cam_create_physical`、`cam_align_to_view`、`render_set_engine`、`render_set_resolution`、`render_set_output`、`render_still`。

---

## 6. 动画：曲线与缓动

> 让选中的对象在 0 帧位于原点、30 帧沿 Z 抬到 200、60 帧落回原点，
> 30 帧处要慢入慢出。把整段动画设为循环。

预期工具：`anim_set_keys`、`anim_ease`、`anim_set_out_of_range`。

---

## 7. 绑定：骨骼 + 自动蒙皮

> 给 `Character_Body` 这个网格建一套骨架：脊椎 4 节、左右手臂各 3 节、
> 左右腿各 3 节。绑好之后加 Skin 修改器并自动计算权重，
> 权重阈值 0.02，最多影响 4 根骨骼。

预期工具：`rig_create_bone_chain`、`rig_skin_add`、`rig_skin_auto_weight`、`rig_skin_set_weight`。

---

## 8. 绑定：IK 腿

> 给左腿骨骼链加一个 IK 解算器，末端目标放在脚的位置，启用 IK。

预期工具：`rig_set_ik_chain`、`rig_ik_goal`、`rig_ik_enable`。

---

## 9. 流水线：烘焙法线

> 场景里有高模 `SM_Wall_High` 和低模 `SM_Wall_Low`，位置重合。
> 把高模细节烘焙成法线贴图给低模，输出 2048×2048 到 `D:\bake\normal_wall.png`。

预期工具：`bake_normals`、`bake_set_output`（需要投影包裹，可能配合 `mod_add` 加 Projection）。

---

## 10. 流水线：导出到 UE5

> 把选中的对象导出成 FBX 到 `D:\export\prop.fbx`，
> 用 UE5 预设，单位厘米，勾上嵌入贴图，转成 Y-up。

预期工具：`select_objects`、`export_engine_preset` 或 `export_fbx` + 对应参数。

---

## 11. 场景整理：审计与清理

> 列出场景里所有面数超过 5 万的对象，按面数从大到小排序。
> 再找出所有贴图丢失的材质。

预期工具：`list_objects`、`get_object_info`、`find_missing_assets`、`scene_statistics`。

---

## 12. 场景整理：图层重排

> 把所有名字以 `SM_` 开头的对象移到新图层 `StaticMesh`，
> 以 `SK_` 开头的移到 `Skeletal`，删除空的旧图层。

预期工具：`find_objects`、`move_objects_to_new_layer`、`list_layers`、`delete_layer`。

---

## 13. 换机器：贴图重链

> 这个工程是从另一台机器拷过来的，贴图全断了。
> 显示所有丢失的资源，然后全部重链到 `D:\ProjectX\textures\`。

预期工具：`find_missing_assets`、`relink_assets`。

---

## 14. 逃生舱：没工具覆盖的操作用 MAXScript

> 帮我写一段 MAXScript：统计当前场景里所有 VRayLight，按类型分组输出数量，
> 然后执行它。

预期工具：`execute_maxscript`。

---

## 15. 组合任务：一步撤销

> 接下来这一串操作请在一步里完成，我要能一次性撤销：
> 建三个球体并排放在 X = -50 / 0 / 50，都赋同一个 `M_Debug` 材质，
> 然后把它们冻结。

预期工具：`begin_undo` → 上述操作 → `end_undo`。

---

## 16. 验收自检

> 跑一次桥接自检，告诉我有没有失败的项，以及当前的 Max 版本、命令数量和语言。

预期工具：`bridge_selftest`、`bridge_status`、`bridge_capabilities`、`get_max_version`。

---

## 提示词写法建议

- **点名对象**用工具能找到的方式：名字、通配符、`selection`、图层。含糊的"那个盒子"AI 只能猜。
- **要数量**就说数字。"高一点"不如"抬高 50 单位"。
- **要可撤销**就明说。默认每次调用是一个撤销步；整段合成一步要用 `begin_undo` / `end_undo`。
- **批量操作先说范围**。"所有以 SM_ 开头的"比"所有网格"更安全。
- **不确定工具是否存在**，直接问：「列出和烘焙相关的工具」。AI 会调 `tools/list` 或 `bridge_capabilities`。
- **中文工具描述**：默认语言是 `zh`。要英文就说 `set_language` 切到 `en`。
