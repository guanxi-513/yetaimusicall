/// 首页：毛玻璃导航栏 + 四个子页（每日推荐 / 搜索 / 榜单 / 我的歌单）
library;

import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../state/auth_state.dart';
import '../state/player_state.dart';
import 'charts_page.dart';
import 'login_dialog.dart';
import 'playlists_page.dart';
import 'recommend_view.dart';
import 'search_page.dart';

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
            onAvatarTap: () => _showSettings(context),
          ),
          // 内容区
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                const RecommendView(),
                const SearchPage(),
                const ChartsPage(),
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
    showDialog(context: context, builder: (_) => const _SettingsDialog());
  }
}

/// 顶部毛玻璃导航栏：App 标题 + 分段切换 + 头像/设置入口
class _GlassNavBar extends StatelessWidget {
  final List<String> labels;
  final int tabIndex;
  final ValueChanged<int> onTabChanged;
  final String? avatarUrl;
  final VoidCallback onAvatarTap;

  const _GlassNavBar({
    required this.labels,
    required this.tabIndex,
    required this.onTabChanged,
    required this.avatarUrl,
    required this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.30),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.16),
                  Colors.white.withOpacity(0.06),
                ],
              ),
              border: Border.all(color: Colors.white.withOpacity(0.25), width: 1),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
                // App 标题
                const Text(
                  '液态音乐',
                  style: TextStyle(
                    color: Colors.white,
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
                            horizontal: 9, vertical: 6),
                        decoration: BoxDecoration(
                          color: selected
                              ? Colors.white.withOpacity(0.28)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: selected
                                ? Colors.white.withOpacity(0.4)
                                : Colors.white.withOpacity(0.12),
                          ),
                        ),
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            color: selected
                                ? Colors.white
                                : Colors.white.withOpacity(0.55),
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
                      color: Colors.white.withOpacity(0.14),
                      border: Border.all(
                          color: Colors.white.withOpacity(0.3), width: 1),
                    ),
                    child: (avatarUrl != null && avatarUrl!.isNotEmpty)
                        ? ClipOval(
                            child: CachedNetworkImage(
                              imageUrl: avatarUrl!,
                              fit: BoxFit.cover,
                              placeholder: (_, __) => Icon(Icons.person,
                                  color: Colors.white.withOpacity(0.85),
                                  size: 18),
                              errorWidget: (_, __, ___) => Icon(Icons.person,
                                  color: Colors.white.withOpacity(0.85),
                                  size: 18),
                            ),
                          )
                        : Icon(Icons.settings,
                            color: Colors.white.withOpacity(0.85), size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置弹窗：用户信息/登录/退出 + 修改 API 基础地址
class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

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
      backgroundColor: const Color(0xFF251B3D),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withOpacity(0.2)),
      ),
      title: const Text('设置', style: TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 用户信息 / 登录区
            _buildUserSection(auth),
            const SizedBox(height: 16),
            const Text(
              '音源服务地址',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'http://10.0.2.2:41831',
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.25)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white70),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '· 模拟器访问电脑：http://10.0.2.2:41831\n'
              '· 真机访问电脑：http://<电脑局域网IP>:41831\n'
              '· 服务器部署：http://<服务器公网IP>:41831',
              style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.6),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭', style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () {
            final url = _controller.text.trim();
            if (url.isNotEmpty) AppConfig.saveApiBaseUrl(url);
            Navigator.pop(context);
          },
          child: const Text('保存', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }

  Widget _buildUserSection(AuthState auth) {
    if (auth.checking) {
      return const Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                color: Colors.white70, strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Text('检查登录状态…',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
        ],
      );
    }
    if (auth.loggedIn && auth.user != null) {
      final u = auth.user!;
      return Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border:
                  Border.all(color: Colors.white.withOpacity(0.4), width: 1),
            ),
            child: ClipOval(
              child: u.avatar.isEmpty
                  ? Icon(Icons.person, color: Colors.white.withOpacity(0.7))
                  : CachedNetworkImage(
                      imageUrl: u.avatar,
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          Icon(Icons.person, color: Colors.white.withOpacity(0.7)),
                      errorWidget: (_, __, ___) => Icon(Icons.person,
                          color: Colors.white.withOpacity(0.7)),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  u.nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '已登录网易云音乐',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.5), fontSize: 11),
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFE05A8A).withOpacity(0.18),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFFE05A8A).withOpacity(0.4)),
              ),
              child: const Text(
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
    // 未登录
    return GestureDetector(
      onTap: () async {
        // 不先关闭设置弹窗，直接在上面叠加登录弹窗
        // 避免 Navigator.pop 后 context 分离导致 showDialog 失败
        final result = await showDialog<bool>(
          context: context,
          builder: (_) => const LoginDialog(),
        );
        // 登录成功后关闭设置弹窗
        if (result == true && mounted) {
          Navigator.pop(context);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF6C4FE0).withOpacity(0.16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.25)),
        ),
        child: Row(
          children: [
            Icon(Icons.qr_code_2, color: Colors.white.withOpacity(0.9), size: 22),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '扫码登录网易云音乐',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios,
                color: Colors.white.withOpacity(0.5), size: 14),
          ],
        ),
      ),
    );
  }
}
