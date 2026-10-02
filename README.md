# 花园世界公会花册 · 复刻版

多人在线实时共享的花册系统：网页端 + 微信小程序端，共用同一个 Supabase 后端。
参考「黄枫谷百花园」在线花册的交互设计复刻，公会名与成员信息已清洗为占位，部署后自行设置。

## 目录结构

```
flowerbook-clone/
├── index.html                 # 网页前端（单文件 SPA，含全部样式与逻辑）
├── assets/flower-images/      # 574 张花朵图片（webp/png/jpg）
├── db/setup.sql               # Supabase 建库脚本（表 + RLS + RPC + 578 朵花种子数据）
├── miniprogram/               # 微信小程序完整工程
│   ├── app.js / app.json / app.wxss / project.config.json / sitemap.json
│   ├── utils/config.js        # ← 在这里填写你的 Supabase URL 与 anon key
│   ├── utils/supabase.js      # REST 封装（登录 / 拉取 / 标记 / 录入 / 竞赛）
│   └── pages/                 # login / flowers / member / competition
└── README.md
```

## 一、搭建后端（Supabase，约 5 分钟）

1. 打开 https://supabase.com 注册并登录（免费套餐即可，个人/公会使用绰绰有余）。
2. 新建项目：取个名字（如 `flower-guild`），选离你近的区域，设置数据库密码并**记好**。
3. 项目创建完成后，左侧菜单 **SQL Editor → New query**，把 `db/setup.sql` 全文粘贴进去，点 **Run**。
4. 左侧 **Project Settings → API**，复制两样东西：
   - **Project URL**（形如 `https://xxxx.supabase.co`）
   - **anon / public key**（形如 `eyJhbGci...`，这是公开客户端密钥，可放心放在前端）
   - 在 **Project Settings → Realtime** 确认 Postgres Changes 已启用（默认开启）。

## 二、配置网页端

1. 用编辑器打开 `index.html`，找到文件顶部：

   ```js
   const SUPABASE_URL = 'https://nkdeekkhhxyutmowcypr.supabase.co';
   const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5rZGVla2toaHh5dXRtb3djeXByIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA4ODkxNjgsImV4cCI6MjEwNjQ2NTE2OH0.CamasD8QxSjGfxH_LhZeR7ruESXkGdqXHhDE1DhvP0U';
   ```

   替换为你的 Project URL 与 anon key。
2. 本地预览：双击 `index.html`（需与 `assets/` 同级）或起任意静态服务。
3. 部署上线（任选其一）：
   - **GitHub Pages**：把整个 `flowerbook-clone` 目录推到一个仓库，Settings → Pages → 选分支 → 获得公网链接，成员即可访问。
   - **Vercel / Netlify**：导入目录直接发布。

> 本项目当前已部署于 GitHub Pages：**https://wellwang0819.github.io/flowerbook-clone/**（图片走相对路径，`IMG_BASE` 无需设置）。

## 三、配置微信小程序

1. 注册小程序账号：https://mp.weixin.qq.com （个人/组织均可，需实名）。
2. 下载微信开发者工具：https://developers.weixin.qq.com/miniprogram/dev/devtools/download.html
3. 导入工程：选择 `miniprogram/` 目录（AppID 用你自己的，或点「测试号」）。
4. 编辑 `miniprogram/utils/config.js`，填入同样的 Supabase URL 与 anon key。
5. **重要**：小程序 `wx.request` 要求配置合法域名。登录微信公众平台 → 开发管理 → 开发设置 → 服务器域名，把 `https://nkdeekkhhxyutmowcypr.supabase.co` 加进 **request 合法域名**（需 HTTPS；开发阶段可在开发者工具勾选「不校验合法域名」）。
6. **花朵图片（可选）**：小程序自身不打包 574 张图片（主包体积限制），通过 `config.js` 的 `IMG_BASE` 加载网页端静态资源。网页端部署到 GitHub Pages 后，把 `IMG_BASE` 填为 `https://wellwang0819.github.io/flowerbook-clone`；不填则卡片显示 🌸 占位，功能不受影响。
7. **实时刷新机制**：网页端用 Supabase Realtime 推送（成员操作后自动刷新）；小程序端因域名/连接限制采用「下拉刷新 + 每次进入页面自动拉取 + 页面停留时静默轮询」保证多端数据一致。若需小程序端也走 Realtime 推送，可基于 `utils/supabase.js` 的 REST 封装另接 `wx.connectSocket`（详见微信文档，本工程未默认开启）。
8. 编译预览即可使用。

## 默认账号（部署后请立即修改）

| 成员 | 密码 | 角色 |
|---|---|---|
| 会长·花语 | `admin123` | 管理员 |
| 副会长·月影 | `1234` | 管理员 |
| 理事·晨星 / 菁英·清风 / 成员·山茶 / 成员·远岫 | `1234` | 普通成员 |

**修改公会名**：Supabase 控制台 → Table Editor → `guilds` 表 → 修改 `name` 字段。
**修改/新增成员**：`guild_members` 表 → 增删改行；`password_hash` 填 `sha256(密码)` 的十六进制值（如密码 `1234` → `03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4`）。
**成员名即登录昵称**：改 `name` 后，登录下拉会同步显示新名字。

## 功能清单

- 登录：选择昵称 + 密码（密码为 sha256 哈希比对）
- 花册：578 朵花 · 图片 · 竞赛分 · 渠道 · 价格/货币/花瓶 · 拥有者列表
- 筛选：视图（全部/已拥有/待培育/未拥有）、竞赛分（无/9/14/21/23/25/28/30）、渠道、花名搜索
- 排序：默认 / 竞赛分 ↓↑ / 拥有人数 ↓↑ / 花名 A-Z
- 标记：单朵标记「已拥有 / 待培育 / 取消」，长按/勾选批量标记，批量录入（textarea 一次多朵）
- 实时同步：任何成员标记/录入后，网页端通过 Supabase Realtime 自动刷新，无需手动刷新
- 成员菜单：全体成员聚合视图（按有人拥有/有人待培育/全员未拥有筛选）、成员列表、退出登录
- 竞赛任务：添加任务、标记完成/未完成、操作日志（谁在何时做了什么）

## 数据说明

- 花朵目录：578 朵（含竞赛分、渠道、来源），与参考站一致
- 价格/货币/花瓶：来自你本地《鲜花名册_含图片_已补充.xlsx》按花名匹配补齐；无法匹配的留空
- 获取方式（如「活动获取」「密令获取」）：存在 `order_exp` 字段，卡片上有展示
- 图片：574 张（webp/png/jpg，来自本地图包 + 参考站公开图）；4 朵（毓秀兰结 / 清栀玉露 / 竹韵华灯 / 芳翎昭锦）参考站也无图，前端以 🌸 兜底
- 初始拥有关系为空：部署后由成员各自标记，或管理员在录入中批量录入
- 竞赛任务 / 日志：初始为空，由成员共同维护

## 安全提示

- 本项目面向熟人小公会，登录密码为「展示层」校验（anon key 可写库），不建议存放敏感信息。
- 若需严格权限：可在 Supabase 开启邮箱/魔棒认证，将 RLS 策略改为 `auth.uid() = member_id` 后放开写权限（可在 `db/setup.sql` 基础上自行调整）。
- 参考站的 Supabase URL / anon key 仅为数据参考，本项目不依赖参考站任何资源运行。

## 常见问题

**Q：网页端连不上后端 / 白屏？**
检查 `index.html` 顶部 URL/key 是否填对；打开浏览器 F12 看 Network 里 `supabase.co` 请求是否 200。

**Q：小程序报「url 不在合法域名列表」？**
按上文第 5 步配置 request 合法域名；开发阶段可临时勾选「不校验合法域名」。

**Q：多人同时标记会冲突吗？**
不会。标记操作是原子的 `insert`/`delete`（带唯一约束），Realtime 会推送给所有在线端。

**Q：图片不显示？**
确认 `index.html` 与 `assets/` 同级；部署时整目录上传，别只传单个 HTML。
