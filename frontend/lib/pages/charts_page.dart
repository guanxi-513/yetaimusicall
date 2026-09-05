/// 榜单页：固定榜单列表（玻璃卡片网格），点击进歌单详情
library;

import 'package:flutter/material.dart';

import '../config.dart';
import 'playlist_detail_page.dart';
import '../widgets/glass_card.dart';

class ChartsPage extends StatefulWidget {
  const ChartsPage({super.key});

  @override
  State<ChartsPage> createState() => _ChartsPageState();
}

class _ChartsPageState extends State<ChartsPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Text(
              '排行榜',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Text(
              '云音乐官方榜单，每日更新',
              style: TextStyle(
                color: Colors.white.withOpacity(0.45),
                fontSize: 12,
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.92,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final chart = AppConfig.kCharts[i];
                return _ChartCard(chart: chart);
              },
              childCount: AppConfig.kCharts.length,
            ),
          ),
        ),
      ],
    );
  }
}

class _ChartCard extends StatelessWidget {
  final BoardChart chart;
  const _ChartCard({required this.chart});

  @override
  Widget build(BuildContext context) {
    // 用榜单名首字 + 渐变色块作占位封面（详情页会展示真实封面）
    return GlassCard(
      borderRadius: 20,
      padding: EdgeInsets.zero,
      onTap: () {
        Navigator.of(context).push(
          PageRouteBuilder(
            opaque: false,
            transitionDuration: const Duration(milliseconds: 300),
            pageBuilder: (_, anim, __) => SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
              child: PlaylistDetailPage(
                id: chart.id,
                title: chart.name,
              ),
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 占位封面区
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _chartColors(chart.name),
                ),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    chart.name.characters.first,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 44,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Positioned(
                    top: 10,
                    right: 12,
                    child: Text(
                      chart.name,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 底部信息
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
            ),
            child: Text(
              chart.desc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 按榜单名分配渐变色
  List<Color> _chartColors(String name) {
    const palettes = [
      [Color(0xFF6C4FE0), Color(0xFF8C3F6B)],
      [Color(0xFF3A6FE0), Color(0xFF1A4C8C)],
      [Color(0xFFE05A8A), Color(0xFF6C2E5A)],
      [Color(0xFF2E8C6B), Color(0xFF1A5A4C)],
      [Color(0xFFB07A2E), Color(0xFF6C4A1A)],
      [Color(0xFF8C4FE0), Color(0xFF3A2E8C)],
      [Color(0xFFE0634A), Color(0xFF6C2E22)],
      [Color(0xFF4FA0C8), Color(0xFF2E5A6C)],
    ];
    final idx = name.hashCode.abs() % palettes.length;
    return palettes[idx];
  }
}
