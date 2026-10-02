// ================= Supabase REST 封装（小程序用） =================
// 通过 wx.request 直连 Supabase REST API：
//   - 读取：GET /rest/v1/{table}?select=*&field=eq.value
//   - 写  ：POST（insert）/ PATCH（update）/ DELETE
//   - RPC ：POST /rest/v1/rpc/{fn}
// 注意：小程序 wx.request 的域名需在公众平台配置合法域名（https://你的项目.supabase.co）
const config = require('./config.js');

function req(method, path, data) {
  return new Promise((resolve, reject) => {
    wx.request({
      url: config.SUPABASE_URL + path,
      method,
      data: data || undefined,
      header: {
        'apikey': config.SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + config.SUPABASE_ANON_KEY,
        'Content-Type': 'application/json'
      },
      success(res) {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(res.data);
        } else {
          reject(new Error((res.data && res.data.message) || ('HTTP ' + res.statusCode)));
        }
      },
      fail(err) {
        reject(new Error(err.errMsg || '网络请求失败'));
      }
    });
  });
}

function buildQuery(params) {
  const qs = [];
  if (params.select) qs.push('select=' + encodeURIComponent(params.select));
  const order = params.order;
  delete params.order;
  Object.keys(params).forEach(k => {
    const v = params[k];
    if (v === undefined || v === null || v === '') return;
    qs.push(encodeURIComponent(k) + '=eq.' + encodeURIComponent(v));
  });
  if (order) {
    const dir = order.endsWith('.desc') ? order : order + '.asc';
    qs.push('order=' + encodeURIComponent(dir));
  }
  return qs.join('&');
}

module.exports = {
  // 读表：sb.get('flowers', {select:'*'}) / {id:'一串红'} / {order:'created_at.desc'}
  get(table, params) {
    const q = buildQuery(Object.assign({ select: '*' }, params || {}));
    return req('GET', '/rest/v1/' + table + (q ? '?' + q : ''));
  },

  // 新增：sb.insert('flower_ownership', {flower_id, member_id, status})
  insert(table, data) {
    return req('POST', '/rest/v1/' + table, data);
  },

  // 更新：sb.update('competition_tasks', {done:true}, {id:'xxx'})
  update(table, data, filters) {
    const qs = Object.keys(filters || {}).map(k => encodeURIComponent(k) + '=eq.' + encodeURIComponent(filters[k]));
    return req('PATCH', '/rest/v1/' + table + '?' + qs.join('&'), data);
  },

  // 删除：sb.del('flower_ownership', {flower_id, member_id})
  del(table, filters) {
    const qs = Object.keys(filters || {}).map(k => encodeURIComponent(k) + '=eq.' + encodeURIComponent(filters[k]));
    return req('DELETE', '/rest/v1/' + table + '?' + qs.join('&'));
  },

  // RPC：sb.rpc('get_guild_home_data') 默认传 p_guild_id
  rpc(fn, body) {
    return req('POST', '/rest/v1/rpc/' + fn, body || { p_guild_id: config.GUILD_ID });
  },

  // 纯 JS SHA-256（小程序无 crypto.subtle）
  sha256Hex(input) {
    const utf8 = unescape(encodeURIComponent(input));
    const bytes = [];
    for (let i = 0; i < utf8.length; i++) bytes.push(utf8.charCodeAt(i) & 0xff);

    const K = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];

    // 补位
    const bitLen = bytes.length * 8;
    bytes.push(0x80);
    while (bytes.length % 64 !== 56) bytes.push(0);
    for (let i = 3; i >= 0; i--) bytes.push(Math.floor(bitLen / Math.pow(2, i * 8)) & 0xff);

    let h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a,
        h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

    const rotr = (x, n) => (x >>> n) | (x << (32 - n));
    const w = new Array(64);

    for (let off = 0; off < bytes.length; off += 64) {
      for (let i = 0; i < 16; i++) {
        w[i] = (bytes[off + i * 4] << 24) | (bytes[off + i * 4 + 1] << 16) |
               (bytes[off + i * 4 + 2] << 8) | bytes[off + i * 4 + 3];
      }
      for (let i = 16; i < 64; i++) {
        const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      let a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (let i = 0; i < 64; i++) {
        const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        const ch = (e & f) ^ (~e & g);
        const temp1 = (h + S1 + ch + K[i] + w[i]) | 0;
        const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const temp2 = (S0 + maj) | 0;
        h = g; g = f; f = e; e = (d + temp1) | 0;
        d = c; c = b; b = a; a = (temp1 + temp2) | 0;
      }
      h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0;
      h4 = (h4 + e) | 0; h5 = (h5 + f) | 0; h6 = (h6 + g) | 0; h7 = (h7 + h) | 0;
    }

    function toHex(x) {
      const s = (x >>> 0).toString(16);
      return s.length < 8 ? '00000000'.slice(s.length) + s : s;
    }
    return [h0, h1, h2, h3, h4, h5, h6, h7].map(toHex).join('');
  }
};
