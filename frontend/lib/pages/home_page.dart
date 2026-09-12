/// 首页：毛玻璃导航栏 + 四个子页（每日推荐 / 搜索 / 榜单 / 我的歌单）
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../state/auth_state.dart';
import '../state/player_state.dart';
import '../state/ui_settings.dart';
import 'charts_page.dart';
import 'login_dialog.dart';
import 'playlists_page.dart';
import 'recommend_view.dart';
import 'search_page.dart';
import 'transition_settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  /// 记录上次登录态，检测到变化时同步云收藏集合：
  /// - 登录（含 App 启动时 cookie 恢复登录）→ 拉取网易云喜欢列表，
  ///   使"我喜欢的音乐"歌单内歌曲默认点亮爱心、点一下直接取消云端喜欢
  /// - 退出登录 → 清空云端喜欢集合
  bool? _lastLoggedIn;
  bool? _lastQQLoggedIn;

  static const _titles = ['推荐', '搜索', '榜单', '我的'];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthState>();
    final player = context.read<PlayerState>();
    if (auth.loggedIn && _lastLoggedIn != true) {
      _lastLoggedIn = true;
      player.loadCloudFavorites();
    } else if (!auth.loggedIn && _lastLoggedIn != false) {
      _lastLoggedIn = false;
      player.clearCloudFavorites();
    }
    // QQ 登录态切换：登录后拉取「我喜欢」songId 集合，退出后清空
    if (auth.qqLoggedIn && _lastQQLoggedIn != true) {
      _lastQQLoggedIn = true;
      player.loadQqFavorites();
    } else if (!auth.qqLoggedIn && _lastQQLoggedIn != false) {
      _lastQQLoggedIn = false;
      player.clearQqFavorites();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          // 顶部毛玻璃导航栏
          _GlassNavBar(
            labels: _titles,
            tabIndex: _tab,
            onTabChanged: (i) => setState(() => _tab = i),
            avatarUrl: auth.user?.avatar,
            anyLoggedIn:
                auth.loggedIn ||
                auth.kugouLoggedIn ||
                auth.qqLoggedIn ||
                auth.sodaLoggedIn,
            onAvatarTap: () => _showSettings(context),
          ),
          // 内容区
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                RecommendView(),
                SearchPage(),
                ChartsPage(),
                // 传入可见状态：切回「我的」时强制刷新收藏/历史
                PlaylistsPage(isActive: _tab == 3),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showDialog(context: context, builder: (_) => _SettingsDialog());
  }
}

/// 顶部毛玻璃导航栏：App 标题 + 分段切换 + 头像/设置入口
class _GlassNavBar extends StatelessWidget {
  final List<String> labels;
  final int tabIndex;
  final ValueChanged<int> onTabChanged;
  final String? avatarUrl;
  final bool anyLoggedIn;
  final VoidCallback onAvatarTap;

  _GlassNavBar({
    required this.labels,
    required this.tabIndex,
    required this.onTabChanged,
    required this.avatarUrl,
    required this.anyLoggedIn,
    required this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(16, 10, 16, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.30),
            blurRadius: 20,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isLight
                  ? [const Color(0xFFFFFFFF), const Color(0xFFFDFDFA)]
                  : [fgPrimary.withOpacity(0.16), fgPrimary.withOpacity(0.06)],
            ),
            border: Border.all(
              color: isLight
                  ? const Color(0xFFE4E3DD)
                  : fgPrimary.withOpacity(0.25),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              // App 标题
              Text(
                '液态音乐',
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              // 分段切换
              ...List.generate(labels.length, (i) {
                final selected = tabIndex == i;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: GestureDetector(
                    onTap: () => onTabChanged(i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? fgPrimary.withOpacity(0.28)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(
                          color: selected
                              ? fgPrimary.withOpacity(0.4)
                              : fgPrimary.withOpacity(0.12),
                        ),
                      ),
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          color: selected
                              ? fgPrimary
                              : fgPrimary.withOpacity(0.55),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              }),
              const Spacer(),
              // 头像 / 设置入口
              GestureDetector(
                onTap: onAvatarTap,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fgPrimary.withOpacity(0.14),
                    border: Border.all(
                      color: fgPrimary.withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                  child: (avatarUrl != null && avatarUrl!.isNotEmpty)
                      ? ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: avatarUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => Icon(
                              Icons.person,
                              color: fgPrimary.withOpacity(0.85),
                              size: 18,
                            ),
                            errorWidget: (_, __, ___) => Icon(
                              Icons.person,
                              color: fgPrimary.withOpacity(0.85),
                              size: 18,
                            ),
                          ),
                        )
                      : Icon(
                          // 已有任一音源登录 → 用户图标；否则设置图标
                          anyLoggedIn ? Icons.person : Icons.settings,
                          color: fgPrimary.withOpacity(0.85),
                          size: 18,
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 设置弹窗：用户信息/登录/退出 + 修改 API 基础地址
class _SettingsDialog extends StatefulWidget {
  _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: AppConfig.apiBaseUrl);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    return AlertDialog(
      backgroundColor: bgElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: fgPrimary.withOpacity(0.15)),
      ),
      title: Text('设置', style: TextStyle(color: fgPrimary)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 用户信息 / 登录区
            _buildUserSection(auth),
            SizedBox(height: 16),
            Text('音源服务地址', style: TextStyle(color: fgSecondary, fontSize: 13)),
            SizedBox(height: 8),
            TextField(
              controller: _controller,
              style: TextStyle(color: fgPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'http://10.0.2.2:41831',
                hintStyle: TextStyle(color: fgPrimary.withOpacity(0.35)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: fgPrimary.withOpacity(0.25)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: fgSecondary),
                ),
              ),
            ),
            SizedBox(height: 10),
            Text(
              '· 模拟器访问电脑：http://10.0.2.2:41831\n'
              '· 真机访问电脑：http://<电脑局域网IP>:41831\n'
              '· 服务器部署：http://<服务器公网IP>:41831',
              style: TextStyle(color: fgTertiary, fontSize: 11, height: 1.6),
            ),
            SizedBox(height: 20),
            // ---- 自定义界面 ----
            Text('自定义界面', style: TextStyle(color: fgSecondary, fontSize: 13)),
            SizedBox(height: 8),
            // 界面风格预设
            ValueListenableBuilder<UiStyle>(
              valueListenable: uiStyle,
              builder: (_, style, __) => Column(
                children: [
                  _StyleOption(
                    title: '液态玻璃',
                    desc: '封面模糊 + 实时毛玻璃 + 青绿光效',
                    selected: style == UiStyle.glass,
                    onTap: () => setUiStyle(UiStyle.glass),
                  ),
                  _StyleOption(
                    title: '极简暗色',
                    desc: '纯黑背景 + 扁平卡片，无模糊无光效',
                    selected: style == UiStyle.plain,
                    onTap: () => setUiStyle(UiStyle.plain),
                  ),
                  _StyleOption(
                    title: '暗色透明',
                    desc: '封面模糊 + 详情页透明透出下层',
                    selected: style == UiStyle.transparent,
                    onTap: () => setUiStyle(UiStyle.transparent),
                  ),
                  _StyleOption(
                    title: '极简白色',
                    desc: '暖白背景 + 黑字，无玻璃无模糊',
                    selected: style == UiStyle.white,
                    onTap: () => setUiStyle(UiStyle.white),
                  ),
                ],
              ),
            ),
            SizedBox(height: 8),
            ValueListenableBuilder<bool>(
              valueListenable: songCardBlur,
              builder: (_, blur, __) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '歌曲卡片毛玻璃',
                  style: TextStyle(color: fgPrimary, fontSize: 14),
                ),
                subtitle: Text(
                  '开启后歌曲卡片带背景模糊；关闭可提升列表滚动性能',
                  style: TextStyle(color: fgTertiary, fontSize: 11),
                ),
                value: blur,
                activeTrackColor: Color(0xFF1DB954),
                activeThumbColor: fgPrimary,
                inactiveTrackColor: fgPrimary.withOpacity(0.15),
                onChanged: setSongCardBlur,
              ),
            ),
            // 过渡动画三级设置入口
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '过渡动画',
                style: TextStyle(color: fgPrimary, fontSize: 14),
              ),
              subtitle: Text(
                '封面飞入 · 页面推入 · 列表递进',
                style: TextStyle(color: fgTertiary, fontSize: 11),
              ),
              trailing: Icon(
                Icons.chevron_right,
                color: fgPrimary.withOpacity(0.6),
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const TransitionSettingsPage(),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('关闭', style: TextStyle(color: fgSecondary)),
        ),
        TextButton(
          onPressed: () {
            final url = _controller.text.trim();
            if (url.isNotEmpty) AppConfig.saveApiBaseUrl(url);
            Navigator.pop(context);
          },
          child: Text('保存', style: TextStyle(color: fgPrimary)),
        ),
      ],
    );
  }

  Widget _buildUserSection(AuthState auth) {
    if (auth.checking ||
        auth.kugouChecking ||
        auth.qqChecking ||
        auth.sodaChecking) {
      return Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              color: fgSecondary,
              strokeWidth: 2,
            ),
          ),
          SizedBox(width: 10),
          Text('检查登录状态…', style: TextStyle(color: fgSecondary, fontSize: 13)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- 网易云账号 ----
        if (auth.loggedIn && auth.user != null)
          _buildNeteaseRow(auth)
        else
          _buildNeteaseLoginEntry(),
        // ---- 酷狗账号 ----
        SizedBox(height: 12),
        if (auth.kugouLoggedIn)
          _buildKugouRow(auth)
        else
          _buildKugouLoginEntry(),
        // ---- QQ 账号 ----
        SizedBox(height: 12),
        if (auth.qqLoggedIn) _buildQQRow(auth) else _buildQQLoginEntry(),
        // ---- 汽水账号 ----
        SizedBox(height: 12),
        if (auth.sodaLoggedIn) _buildSodaRow(auth) else _buildSodaLoginEntry(),
      ],
    );
  }

  /// 网易云已登录：头像 + 昵称 + 退出
  Widget _buildNeteaseRow(AuthState auth) {
    final u = auth.user!;
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: fgPrimary.withOpacity(0.4), width: 1),
          ),
          child: ClipOval(
            child: u.avatar.isEmpty
                ? Icon(Icons.person, color: fgPrimary.withOpacity(0.7))
                : CachedNetworkImage(
                    imageUrl: u.avatar,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Icon(Icons.person, color: fgPrimary.withOpacity(0.7)),
                    errorWidget: (_, __, ___) =>
                        Icon(Icons.person, color: fgPrimary.withOpacity(0.7)),
                  ),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                u.nickname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 2),
              Text(
                '已登录网易云音乐',
                style: TextStyle(
                  color: fgPrimary.withOpacity(0.5),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: () async {
            await auth.logout();
            // 清空云端收藏集合
            context.read<PlayerState>().clearCloudFavorites();
          },
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Color(0xFFE05A8A).withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Color(0xFFE05A8A).withOpacity(0.4)),
            ),
            child: Text(
              '退出登录',
              style: TextStyle(
                color: Color(0xFFE05A8A),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 网易云未登录：扫码登录入口
  Widget _buildNeteaseLoginEntry() {
    return GestureDetector(
      onTap: () async {
        // 不先关闭设置弹窗，直接在上面叠加登录弹窗
        // 避免 Navigator.pop 后 context 分离导致 showDialog 失败
        final result = await showDialog<bool>(
          context: context,
          builder: (_) => LoginDialog(source: 'netease'),
        );
        // 登录成功后关闭设置弹窗
        if (result == true && mounted) {
          Navigator.pop(context);
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Color(0xFF6C4FE0).withOpacity(0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: fgPrimary.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.qr_code_2, color: fgPrimary.withOpacity(0.9), size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '扫码登录网易云音乐',
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: fgPrimary.withOpacity(0.5),
              size: 14,
            ),
          ],
        ),
      ),
    );
  }

  /// 酷狗已登录：图标 + 用户ID + 退出（酷狗接口无昵称/头像，展示用户ID）
  Widget _buildKugouRow(AuthState auth) {
    final uid = auth.kugouUserId;
    final name = uid.isEmpty ? '酷狗音乐' : '酷狗用户 $uid';
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: fgPrimary.withOpacity(0.4), width: 1),
          ),
          child: ClipOval(
            child: Icon(
              Icons.graphic_eq,
              color: fgPrimary.withOpacity(0.85),
              size: 22,
            ),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 2),
              Text(
                '已登录酷狗音乐',
                style: TextStyle(color: fgSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: () => auth.kugouLogout(),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Color(0xFFE05A8A).withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Color(0xFFE05A8A).withOpacity(0.4)),
            ),
            child: Text(
              '退出登录',
              style: TextStyle(
                color: Color(0xFFE05A8A),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 酷狗未登录：扫码登录入口
  Widget _buildKugouLoginEntry() {
    return GestureDetector(
      onTap: () async {
        final result = await showDialog<bool>(
          context: context,
          builder: (_) => LoginDialog(source: 'kugou'),
        );
        if (result == true && mounted) {
          Navigator.pop(context);
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Color(0xFF4FA0E0).withOpacity(0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: fgPrimary.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.qr_code_2, color: fgPrimary.withOpacity(0.9), size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '扫码登录酷狗音乐',
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: fgPrimary.withOpacity(0.5),
              size: 14,
            ),
          ],
        ),
      ),
    );
  }

  /// QQ 已登录：图标 + 用户ID + 退出（QQ 接口未返回昵称/头像，展示用户ID）
  Widget _buildQQRow(AuthState auth) {
    final uid = auth.qqUserId;
    final name = uid.isEmpty ? 'QQ音乐' : 'QQ用户 $uid';
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: fgPrimary.withOpacity(0.4), width: 1),
          ),
          child: ClipOval(
            child: Icon(
              Icons.music_note,
              color: fgPrimary.withOpacity(0.85),
              size: 22,
            ),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 2),
              Text(
                '已登录QQ音乐',
                style: TextStyle(color: fgSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: () => auth.qqLogout(),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Color(0xFFE05A8A).withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Color(0xFFE05A8A).withOpacity(0.4)),
            ),
            child: Text(
              '退出登录',
              style: TextStyle(
                color: Color(0xFFE05A8A),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// QQ 未登录：扫码登录入口
  Widget _buildQQLoginEntry() {
    return GestureDetector(
      onTap: () async {
        final result = await showDialog<bool>(
          context: context,
          builder: (_) => LoginDialog(source: 'qq'),
        );
        if (result == true && mounted) {
          Navigator.pop(context);
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Color(0xFF12B7F5).withOpacity(0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: fgPrimary.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.qr_code_2, color: fgPrimary.withOpacity(0.9), size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '扫码登录QQ音乐',
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: fgPrimary.withOpacity(0.5),
              size: 14,
            ),
          ],
        ),
      ),
    );
  }

  /// 汽水已登录：头像 + 昵称 + 退出（昵称/头像来自 /soda/status 的 user）
  Widget _buildSodaRow(AuthState auth) {
    final u = auth.sodaUser;
    final name = (u != null && u.nickname.isNotEmpty) ? u.nickname : '汽水音乐';
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: fgPrimary.withOpacity(0.4), width: 1),
          ),
          child: ClipOval(
            child: u != null && u.avatar.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: u.avatar,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Icon(Icons.person, color: fgPrimary.withOpacity(0.7)),
                    errorWidget: (_, __, ___) => Icon(
                      Icons.water_drop_outlined,
                      color: fgPrimary.withOpacity(0.7),
                    ),
                  )
                : Icon(
                    Icons.water_drop,
                    color: fgPrimary.withOpacity(0.85),
                    size: 22,
                  ),
          ),
        ),
        SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 2),
              Text(
                '已登录汽水音乐',
                style: TextStyle(color: fgSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: () => auth.sodaLogout(),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: Color(0xFFE05A8A).withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Color(0xFFE05A8A).withOpacity(0.4)),
            ),
            child: Text(
              '退出登录',
              style: TextStyle(
                color: Color(0xFFE05A8A),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 汽水未登录：扫码登录入口
  Widget _buildSodaLoginEntry() {
    return GestureDetector(
      onTap: () async {
        final result = await showDialog<bool>(
          context: context,
          builder: (_) => LoginDialog(source: 'soda'),
        );
        if (result == true && mounted) {
          Navigator.pop(context);
        }
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Color(0xFF46C9B6).withOpacity(0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: fgPrimary.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.qr_code_2, color: fgPrimary.withOpacity(0.9), size: 22),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '扫码登录汽水音乐',
                style: TextStyle(
                  color: fgPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.arrow_forward_ios,
              color: fgPrimary.withOpacity(0.5),
              size: 14,
            ),
          ],
        ),
      ),
    );
  }
}

/// 界面风格选项行（设置弹窗「自定义界面」）
class _StyleOption extends StatelessWidget {
  final String title;
  final String desc;
  final bool selected;
  final VoidCallback onTap;

  _StyleOption({
    required this.title,
    required this.desc,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        margin: EdgeInsets.only(bottom: 6),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? Color(0xFF1DB954).withOpacity(0.15)
              : fgPrimary.withOpacity(0.06),
          border: Border.all(
            color: selected ? Color(0xFF1DB954) : fgPrimary.withOpacity(0.10),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            // 选中圆点
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? Color(0xFF1DB954) : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? Color(0xFF1DB954)
                      : fgPrimary.withOpacity(0.35),
                  width: 1.5,
                ),
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: fgPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(color: fgTertiary, fontSize: 10.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
