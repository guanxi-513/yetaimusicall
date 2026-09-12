/// 过渡动画设置（三级页）：封面飞入 / 推入转场 / 列表递进，三开关自由组合
library;

import 'package:flutter/material.dart';

import '../state/ui_settings.dart';

class TransitionSettingsPage extends StatelessWidget {
  const TransitionSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: uiStyle,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: bgBase,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: Icon(Icons.chevron_left, color: fgPrimary, size: 30),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              '过渡动画',
              style: TextStyle(
                color: fgPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: Text(
                    '开启后，打开歌单详情页时会播放对应过渡动画；全关则回到普通切换。',
                    style: TextStyle(color: fgTertiary, fontSize: 12, height: 1.6),
                  ),
                ),
                const SizedBox(height: 8),
                _buildCard(
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: transitionHero,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '封面飞入',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '点开歌单时，封面从列表飞入详情页头部',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setTransitionHero,
                      ),
                    ),
                    Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                    ValueListenableBuilder<bool>(
                      valueListenable: transitionPage,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '推入转场',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '打开详情页整页上滑淡入，背景模糊渐显',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setTransitionPage,
                      ),
                    ),
                    Divider(height: 1, color: fgPrimary.withOpacity(0.08)),
                    ValueListenableBuilder<bool>(
                      valueListenable: transitionStagger,
                      builder: (_, v, __) => SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: Text(
                          '列表递进',
                          style: TextStyle(color: fgPrimary, fontSize: 14),
                        ),
                        subtitle: Text(
                          '歌曲列表逐项上浮淡入',
                          style: TextStyle(color: fgTertiary, fontSize: 11),
                        ),
                        value: v,
                        activeTrackColor: const Color(0xFF1DB954),
                        activeThumbColor: fgPrimary,
                        inactiveTrackColor: fgPrimary.withOpacity(0.15),
                        onChanged: setTransitionStagger,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}
