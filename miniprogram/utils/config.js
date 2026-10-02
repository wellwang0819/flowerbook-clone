// ================= 小程序配置（部署时修改） =================
// 与网页端共用同一个 Supabase 项目，值从 Supabase 控制台
// Project Settings → API 中复制
module.exports = {
  // Supabase 项目 URL
  SUPABASE_URL: 'https://nkdeekkhhxyutmowcypr.supabase.co',

  // anon / public key（公开客户端密钥，可放心放在前端）
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5rZGVla2toaHh5dXRtb3djeXByIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA4ODkxNjgsImV4cCI6MjEwNjQ2NTE2OH0.CamasD8QxSjGfxH_LhZeR7ruESXkGdqXHhDE1DhvP0U',

  // 公会 id（与 db/setup.sql 中的 guilds.id 一致，默认即可）
  GUILD_ID: '00000000-0000-0000-0000-000000000001',

  // 花朵图片的静态资源根地址（部署网页端后得到）
  // 例如：GitHub Pages 部署后为 https://你的用户名.github.io/flowerbook-clone
  // 留空则卡片不显示图片（显示占位）
  IMG_BASE: ''
};
