/// 网易云扫码登录弹窗：二维码 + 轮询 801/802/803/800
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../state/auth_state.dart';
import '../state/player_state.dart';
import '../widgets/glass_card.dart';

class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key});

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

enum _QrStatus { loading, waiting, scanned, success, expired, error }

class _LoginDialogState extends State<LoginDialog> {
  String _unikey = '';
  String _qrimg = '';
  _QrStatus _status = _QrStatus.loading;
  String _message = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _fetchQr();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchQr() async {
    setState(() {
      _status = _QrStatus.loading;
      _message = '正在获取二维码…';
    });
    try {
      final r = await ApiService.loginQr();
      if (r.unikey.isEmpty || r.qrimg.isEmpty) {
        setState(() {
          _status = _QrStatus.error;
          _message = '获取二维码失败，请重试';
        });
        return;
      }
      _unikey = r.unikey;
      _qrimg = r.qrimg;
      setState(() {
        _status = _QrStatus.waiting;
        _message = '请使用网易云音乐 App 扫码登录';
      });
      _startPolling();
    } catch (e) {
      setState(() {
        _status = _QrStatus.error;
        _message = '获取二维码失败：$e';
      });
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) {
        _timer?.cancel();
        return;
      }
      try {
        final code = await ApiService.loginQrCheck(_unikey);
        switch (code) {
          case 800:
            if (mounted) {
              setState(() {
                _status = _QrStatus.expired;
                _message = '二维码已过期，请刷新';
              });
            }
            _timer?.cancel();
            break;
          case 801:
            // 等待扫码，状态不变
            break;
          case 802:
            if (mounted) {
              setState(() {
                _status = _QrStatus.scanned;
                _message = '已扫描，请在手机上确认登录';
              });
            }
            break;
          case 803:
            _timer?.cancel();
            if (mounted) {
              setState(() {
                _status = _QrStatus.success;
                _message = '登录成功';
              });
            }
            // 刷新全局登录态（内含延迟+重试，确保服务端已落盘）
            await context.read<AuthState>().onLoginSuccess();
            // 登录成功后拉取云端喜欢列表
            unawaited(context.read<PlayerState>().loadCloudFavorites());
            if (mounted) {
              await Future.delayed(const Duration(milliseconds: 200));
              if (mounted) Navigator.pop(context, true);
            }
            break;
          default:
            // 其他未知 code，保持当前状态
            break;
        }
      } catch (_) {
        // 单次轮询失败不中断，继续重试
      }
    });
  }

  /// 从 data:image/png;base64,xxxx 中提取纯 base64
  Uint8List? _decodeQr() {
    final raw = _qrimg;
    final comma = raw.indexOf(',');
    final b64 = comma >= 0 ? raw.substring(comma + 1) : raw;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        borderRadius: 24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFFE05A8A).withOpacity(0.22),
                    border:
                        Border.all(color: Colors.white.withOpacity(0.3), width: 1),
                  ),
                  child: const Icon(Icons.music_note,
                      color: Colors.white, size: 16),
                ),
                const SizedBox(width: 10),
                const Text(
                  '扫码登录',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '网易云音乐',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 22),
            // 二维码区
            _buildQrArea(),
            const SizedBox(height: 16),
            // 状态文案
            Text(
              _message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _status == _QrStatus.success
                    ? const Color(0xFF8FE0A0)
                    : (_status == _QrStatus.expired || _status == _QrStatus.error
                        ? const Color(0xFFE0A05A)
                        : Colors.white.withOpacity(0.7)),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            // 操作按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('取消',
                      style: TextStyle(color: Colors.white.withOpacity(0.55))),
                ),
                if (_status == _QrStatus.expired || _status == _QrStatus.error)
                  TextButton.icon(
                    onPressed: _fetchQr,
                    icon: const Icon(Icons.refresh,
                        color: Colors.white, size: 16),
                    label: const Text('刷新二维码',
                        style: TextStyle(color: Colors.white)),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrArea() {
    final size = 200.0;
    if (_status == _QrStatus.loading) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: CircularProgressIndicator(
            color: Colors.white.withOpacity(0.7),
            strokeWidth: 2.5,
          ),
        ),
      );
    }
    final bytes = _decodeQr();
    if (bytes == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Icon(Icons.broken_image,
              color: Colors.white.withOpacity(0.4), size: 48),
        ),
      );
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        // 毛玻璃圆盘底
        Container(
          width: size + 18,
          height: size + 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(0.10),
            border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.3),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
        ),
        // 二维码
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
        // 成功蒙层
        if (_status == _QrStatus.success)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                color: Colors.black.withOpacity(0.55),
                child: const Icon(Icons.check_circle,
                    color: Color(0xFF8FE0A0), size: 56),
              ),
            ),
          ),
      ],
    );
  }
}
