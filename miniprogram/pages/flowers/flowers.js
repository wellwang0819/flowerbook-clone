// 花册主页：筛选/排序/搜索/卡片/标记/批量/录入，轮询共享刷新
const app = getApp();
const sb = app.globalData.sb;

const SCORES = ['无', '9', '14', '21', '23', '25', '28', '30'];

Page({
  data: {
    guildName: '花册公会',
    me: null,
    view: 'all',            // all/own/cult/none
    score: '',              // '' 或 分数
    channel: '',            // '' 或渠道名
    search: '',
    sort: 'default',        // default/scoreDesc/scoreAsc/owners/name
    sortName: '默认',
    sortIdx: 0,
    channels: [],
    flowers: [],            // 渲染列表（已过滤排序）
    countTxt: '0/0',
    loading: true,
    batchMode: false,
    batchCount: 0,
    showInput: false,
    inputText: '',
    inputMode: 'own',       // own/cult
    inputHint: '✅ 已拥有',
    moreOpen: false
  },

  onLoad() {
    if (!app.globalData.me) {
      wx.reLaunch({ url: '/pages/login/login' });
      return;
    }
    this.setData({ me: app.globalData.me });
    this.bootstrap();
  },

  onShow() {
    // 返回本页时刷新（其他成员操作后）
    if (this._loaded && app.globalData.flowers.length) this.silentRefresh();
    // 页面停留时静默轮询（30s），与其他成员实时保持一致
    if (!this._timer) {
      this._timer = setInterval(() => {
        if (app.globalData.me) this.silentRefresh();
      }, 30000);
    }
  },

  onHide() {
    if (this._timer) { clearInterval(this._timer); this._timer = null; }
  },

  onUnload() {
    if (this._timer) { clearInterval(this._timer); this._timer = null; }
  },

  onPullDownRefresh() {
    this.silentRefresh().then(() => wx.stopPullDownRefresh());
  },

  async bootstrap() {
    await app.loadAll();
    this._loaded = true;
    this.setData({ guildName: app.globalData.guild ? app.globalData.guild.name : '花册公会' });
    const channels = [];
    app.globalData.flowers.forEach(f => {
      if (f.primary_channel && channels.indexOf(f.primary_channel) === -1) channels.push(f.primary_channel);
    });
    channels.sort();
    this.setData({ channels });
    this.renderFlowers();
    this.setData({ loading: false });
  },

  async silentRefresh() {
    const ok = await app.loadAll();
    if (ok) this.renderFlowers();
  },

  // ===== 数据层 =====
  filtered() {
    const g = app.globalData;
    const me = g.me;
    const ownSet = idx => { const s = g.ownersIndex[idx] || []; return s; };
    const cultSet = idx => g.cultIndex[idx] || [];
    return g.flowers.filter(f => {
      if (this.data.view === 'own' && ownSet(f.id).indexOf(me.id) === -1) return false;
      if (this.data.view === 'cult' && cultSet(f.id).indexOf(me.id) === -1) return false;
      if (this.data.view === 'none' && (ownSet(f.id).indexOf(me.id) !== -1 || cultSet(f.id).indexOf(me.id) !== -1)) return false;
      if (this.data.score && String(f.competition_score) !== this.data.score) return false;
      if (this.data.channel && f.primary_channel !== this.data.channel) return false;
      if (this.data.search && f.name.indexOf(this.data.search) === -1) return false;
      return true;
    });
  },

  sorted(list) {
    const s = this.data.sort;
    if (s === 'scoreDesc') return list.slice().sort((a, b) => b.competition_score - a.competition_score);
    if (s === 'scoreAsc') return list.slice().sort((a, b) => a.competition_score - b.competition_score);
    if (s === 'owners') return list.slice().sort((a, b) => (b.owners || []).length - (a.owners || []).length);
    if (s === 'name') return list.slice().sort((a, b) => a.name.localeCompare(b.name, 'zh'));
    return list;
  },

  renderFlowers() {
    const list = this.sorted(this.filtered());
    const me = app.globalData.me;
    const g = app.globalData;
    const cards = list.map(f => {
      const own = (g.ownersIndex[f.id] || []).indexOf(me.id) !== -1;
      const cult = (g.cultIndex[f.id] || []).indexOf(me.id) !== -1;
      const img = app.imgUrl(f.image_url);
      const priceTxt = f.price != null
        ? (f.currency && f.currency !== '元' ? f.currency : '') + (f.currency === '元' ? '￥' : '') + f.price + (f.currency === '元' ? '' : '')
        : '';
      return {
        id: f.id,
        name: f.name,
        score: f.competition_score || '',
        channel: f.primary_channel || '',
        img,
        noImg: !img,
        priceTxt,
        owners: (f.owners || []).slice(0, 3).map(o => o.member_name).join('、'),
        moreOwners: (f.owners || []).length > 3 ? '+' + ((f.owners || []).length - 3) : '',
        own, cult,
        badge: own ? 'own' : (cult ? 'cult' : '')
      };
    });
    this.setData({
      flowers: cards,
      countTxt: list.length + '/' + g.flowers.length,
      batchCount: this.data.batchMode ? cards.length : 0
    });
  },

  // ===== 筛选/排序 =====
  onViewTap(e) {
    this.setData({ view: e.currentTarget.dataset.k });
    this.renderFlowers();
  },
  onScoreTap(e) {
    const k = e.currentTarget.dataset.k;
    this.setData({ score: this.data.score === k ? '' : k });
    this.renderFlowers();
  },
  onChannelTap(e) {
    const k = e.currentTarget.dataset.k;
    this.setData({ channel: this.data.channel === k ? '' : k, moreOpen: false });
    this.renderFlowers();
  },
  toggleMore() { this.setData({ moreOpen: !this.data.moreOpen }); },
  onSearchInput(e) {
    this.setData({ search: e.detail.value });
    this.renderFlowers();
  },
  onSortChange(e) {
    const arr = ['default', 'scoreDesc', 'scoreAsc', 'owners', 'name'];
    const names = ['默认', '竞赛分↓', '竞赛分↑', '拥有人数', '花名A-Z'];
    const i = Number(e.detail.value);
    this.setData({ sort: arr[i] || 'default', sortName: names[i] || '默认', sortIdx: i });
    this.renderFlowers();
  },

  // ===== 标记 =====
  async setOwn(e) {
    const { id, st } = e.currentTarget.dataset;
    await this.applyStatus(id, st);
  },

  async applyStatus(flowerId, status) {
    const me = app.globalData.me;
    const g = app.globalData;
    const owned = (g.ownersIndex[flowerId] || []).indexOf(me.id) !== -1;
    const culting = (g.cultIndex[flowerId] || []).indexOf(me.id) !== -1;

    try {
      if (owned || culting) {
        // 已有记录：删除旧状态再写入新状态（或状态相同则撤销）
        if ((status === 'own' && owned) || (status === 'cult' && culting)) {
          await sb.del('flower_ownership', { flower_id: flowerId, member_id: me.id });
        } else {
          await sb.del('flower_ownership', { flower_id: flowerId, member_id: me.id });
          await sb.insert('flower_ownership', { flower_id: flowerId, member_id: me.id, status, guild_id: app.globalData.config.GUILD_ID });
        }
      } else {
        await sb.insert('flower_ownership', { flower_id: flowerId, member_id: me.id, status, guild_id: app.globalData.config.GUILD_ID });
      }
    } catch (err) {
      this.toast('操作失败：' + (err.message || err));
      return;
    }
    await this.silentRefresh();
  },

  // ===== 批量模式 =====
  toggleBatch() {
    this.setData({ batchMode: !this.data.batchMode, batchCount: this.data.batchMode ? 0 : this.data.flowers.length });
    this.renderFlowers();
  },
  onCardTap(e) {
    if (this.data.batchMode) this.toggleSelect(e);
  },
  toggleSelect(e) {
    const id = e.currentTarget.dataset.id;
    const sel = this.data._sel || {};
    sel[id] = sel[id] ? false : true;
    this.setData({ _sel: sel, batchCount: Object.keys(sel).filter(k => sel[k]).length });
  },
  async batchApply(e) {
    const st = e.currentTarget.dataset.st;
    const sel = this.data._sel || {};
    const ids = Object.keys(sel).filter(k => sel[k]);
    if (!ids.length) { this.toast('请先选择花朵'); return; }
    const me = app.globalData.me;
    let ok = 0, fail = 0;
    for (const fid of ids) {
      try {
        await sb.del('flower_ownership', { flower_id: fid, member_id: me.id });
        await sb.insert('flower_ownership', { flower_id: fid, member_id: me.id, status: st, guild_id: app.globalData.config.GUILD_ID });
        ok++;
      } catch (err) { fail++; }
    }
    this.setData({ batchMode: false, _sel: {}, batchCount: 0 });
    await this.silentRefresh();
    this.toast('批量完成：成功 ' + ok + '，失败 ' + fail);
  },

  // ===== 录入 =====
  openInput() { this.setData({ showInput: true, inputText: '', inputMode: 'own', inputHint: '✅ 已拥有' }); },
  closeInput() { this.setData({ showInput: false }); },
  setInputMode(e) {
    const k = e.currentTarget.dataset.k;
    this.setData({ inputMode: k, inputHint: k === 'own' ? '✅ 已拥有' : '🌱 待培育' });
  },
  onInputText(e) { this.setData({ inputText: e.detail.value }); },

  async submitInput() {
    const raw = this.data.inputText.trim();
    if (!raw) return;
    const names = raw.split(/[\s,，、;；]+/).map(s => s.trim()).filter(Boolean);
    if (!names.length) return;
    const me = app.globalData.me;
    const st = this.data.inputMode;
    const g = app.globalData;
    let ok = 0, miss = 0;
    for (const n of names) {
      const f = g.flowers.find(x => x.name === n);
      if (!f) { miss++; continue; }
      try {
        await sb.del('flower_ownership', { flower_id: f.id, member_id: me.id });
        await sb.insert('flower_ownership', { flower_id: f.id, member_id: me.id, status: st, guild_id: app.globalData.config.GUILD_ID });
        ok++;
      } catch (err) { miss++; }
    }
    this.setData({ showInput: false });
    await this.silentRefresh();
    this.toast('录入完成：成功 ' + ok + (miss ? '，未找到 ' + miss : ''));
  },

  // ===== 导航 =====
  goCompetition() { wx.navigateTo({ url: '/pages/competition/competition' }); },
  goMember() { wx.navigateTo({ url: '/pages/member/member' }); },
  logout() {
    wx.showModal({
      title: '退出登录',
      content: '确定退出当前账号吗？',
      success: r => {
        if (r.confirm) {
          app.globalData.me = null;
          wx.removeStorageSync('fb_me');
          wx.reLaunch({ url: '/pages/login/login' });
        }
      }
    });
  },

  toast(msg) {
    wx.showToast({ title: msg, icon: 'none', duration: 1800 });
  }
});
