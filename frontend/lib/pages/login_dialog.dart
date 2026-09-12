/// 扫码登录弹窗（三音源）：顶部「网易云 / 酷狗 / QQ」切换，各自独立扫码流程
///
/// - 网易云：/login/qr + /login/qr/check 轮询 801/802/803/800
/// - 酷狗：/kugou/login/qr + /kugou/login/qr/check 轮询 status 1/2/4/0，
///   成功时后端返回完整登录态 cookie 串（ApiService 整串保存）
/// - QQ：/qq/login/qr + /qq/login/qr/check 轮询 status 1/2/4/0，
///   成功时后端返回完整登录态 cookie 串（ApiService 整串保存）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../state/ui_settings.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../services/api_service.dart';
import '../state/auth_state.dart';
import '../state/player_state.dart';
import '../widgets/glass_card.dart';

class LoginDialog extends StatefulWidget {
  /// 初始音源：'netease'（网易云）| 'kugou'（酷狗）| 'qq'（QQ音乐）
  final String source;
  const LoginDialog({super.key, this.source = 'netease'});

  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

enum _QrStatus { loading, waiting, scanned, success, expired, error }

class _LoginDialogState extends State<LoginDialog> {
  late String _source; // 'netease' | 'kugou' | 'qq'
  String _unikey = '';
  String _qrimg = '';
  int _ptqrtoken = 0; // QQ 扫码轮询用
  _QrStatus _status = _QrStatus.loading;
  String _message = '';
  Timer? _timer;
  bool _isLoading = false; // 汽水一键导入进行中

  @override
  void initState() {
    super.initState();
    _source = widget.source;
    _fetchQr();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _isKugou => _source == 'kugou';
  bool get _isQQ => _source == 'qq';
  bool get _isSoda => _source == 'soda';

  /// 当前音源扫码提示文案
  String get _scanHint => switch (_source) {
    'kugou' => '请使用酷狗音乐 App 扫码登录',
    'qq' => '请使用 QQ 音乐 App 扫码登录',
    'soda' => '请使用汽水音乐 App 扫码登录',
    _ => '请使用网易云音乐 App 扫码登录',
  };

  /// 切换音源：重置状态并重新取二维码
  void _switchSource(String s) {
    if (_source == s) return;
    _timer?.cancel();
    setState(() {
      _source = s;
      _isLoading = false;
    });
    _fetchQr();
  }

  Future<void> _fetchQr() async {
    // 汽水：扫码已被平台风控拦截，不显示二维码，改用一键导入 PC 登录态
    if (_isSoda) {
      setState(() {
        _status = _QrStatus.waiting;
        _message = '汽水音乐扫码已被平台风控拦截，请使用一键导入 PC 登录态';
      });
      return;
    }
    setState(() {
      _status = _QrStatus.loading;
      _message = '正在获取二维码…';
    });
    try {
      if (_isKugou) {
        final r = await ApiService.kugouLoginQr();
        if (r.key.isEmpty || r.qrimg.isEmpty) {
          setState(() {
            _status = _QrStatus.error;
            _message = '获取二维码失败，请重试';
          });
          return;
        }
        _unikey = r.key;
        _qrimg = r.qrimg;
      } else if (_isQQ) {
        final r = await ApiService.qqLoginQr();
        if (r.qrsig.isEmpty || r.img.isEmpty) {
          setState(() {
            _status = _QrStatus.error;
            _message = '获取二维码失败，请重试';
          });
          return;
        }
        _unikey = r.qrsig;
        _ptqrtoken = r.ptqrtoken;
        _qrimg = r.img;
      } else if (_isSoda) {
        final r = await ApiService.sodaLoginQr();
        if (r.key.isEmpty || (r.qrImage.isEmpty && r.qrUrl.isEmpty)) {
          setState(() {
            _status = _QrStatus.error;
            _message = '获取二维码失败，请重试';
          });
          return;
        }
        _unikey = r.key;
        // 优先展示真正的二维码图片（qr_image，data:image base64）；
        // qr_url 是扫码内容网页，不能当图片加载，仅作备用
        _qrimg = r.qrImage.isNotEmpty ? r.qrImage : r.qrUrl;
      } else {
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
      }
      setState(() {
        _status = _QrStatus.waiting;
        _message = _scanHint;
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
        if (_isKugou) {
          await _pollKugou();
        } else if (_isQQ) {
          await _pollQQ();
        } else if (_isSoda) {
          await _pollSoda();
        } else {
          await _pollNetease();
        }
      } catch (_) {
        // 单次轮询失败不中断，继续重试
      }
    });
  }

  // ---------- 网易云轮询（801/802/803/800） ----------

  Future<void> _pollNetease() async {
    final result = await ApiService.loginQrCheck(_unikey);
    switch (result.code) {
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
        // 保存登录态：先 clear 再写入，确保多设备各用各的账号，互不覆盖
        if (result.cookie.isNotEmpty) {
          await ApiService.setNeteaseCookie(result.cookie);
        }
        if (mounted) {
          setState(() {
            _status = _QrStatus.success;
            _message = '登录成功';
          });
        }
        // 刷新全局登录态（内含延迟+重试，确保服务端已落盘）
        await context.read<AuthState>().onLoginSuccess();
        // 登录成功后拉取云端喜欢列表
        // ignore: unawaited_futures
        context.read<PlayerState>().loadCloudFavorites();
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: 200));
          if (mounted) Navigator.pop(context, true);
        }
        break;
      default:
        break;
    }
  }

  // ---------- 酷狗轮询（status 1/2/4/0） ----------

  Future<void> _pollKugou() async {
    final status = await ApiService.kugouLoginCheck(_unikey);
    switch (status) {
      case 0:
        if (mounted) {
          setState(() {
            _status = _QrStatus.expired;
            _message = '二维码已过期，请刷新';
          });
        }
        _timer?.cancel();
        break;
      case 1:
        // 等待扫码，状态不变
        break;
      case 2:
        if (mounted) {
          setState(() {
            _status = _QrStatus.scanned;
            _message = '已扫描，请在手机上确认登录';
          });
        }
        break;
      case 4:
        _timer?.cancel();
        if (mounted) {
          setState(() {
            _status = _QrStatus.success;
            _message = '登录成功';
          });
        }
        // cookie 已由 ApiService.kugouLoginCheck 整串保存，刷新登录态
        await context.read<AuthState>().onKugouLoginSuccess();
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: 200));
          if (mounted) Navigator.pop(context, true);
        }
        break;
      default:
        break;
    }
  }

  // ---------- QQ 轮询（status 0/1/2/4） ----------

  Future<void> _pollQQ() async {
    final status = await ApiService.qqLoginCheck(_unikey, _ptqrtoken);
    switch (status) {
      case 0:
        if (mounted) {
          setState(() {
            _status = _QrStatus.expired;
            _message = '二维码已过期，请刷新';
          });
        }
        _timer?.cancel();
        break;
      case 1:
        // 等待扫码，状态不变
        break;
      case 2:
        if (mounted) {
          setState(() {
            _status = _QrStatus.scanned;
            _message = '已扫描，请在手机上确认登录';
          });
        }
        break;
      case 4:
        _timer?.cancel();
        if (mounted) {
          setState(() {
            _status = _QrStatus.success;
            _message = '登录成功';
          });
        }
        // cookie 已由 ApiService.qqLoginCheck 整串保存，刷新登录态
        await context.read<AuthState>().onQQLoginSuccess();
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: 200));
          if (mounted) Navigator.pop(context, true);
        }
        break;
      default:
        break;
    }
  }

  // ---------- 汽水轮询（status 0/1/2/4，need_sms 需短信） ----------

  Future<void> _pollSoda() async {
    final r = await ApiService.sodaLoginQrCheck(_unikey);
    // 需短信验证的账号：暂不支持，直接停止轮询
    if (r.needSms) {
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _status = _QrStatus.error;
          _message = '该账号需短信验证，当前暂不支持，请用 App 扫码登录';
        });
      }
      return;
    }
    switch (r.status) {
      case 0:
        if (mounted) {
          setState(() {
            _status = _QrStatus.expired;
            _message = '二维码已过期，请刷新';
          });
        }
        _timer?.cancel();
        break;
      case 1:
        // 等待扫码，状态不变
        break;
      case 2:
        if (mounted) {
          setState(() {
            _status = _QrStatus.scanned;
            _message = '已扫描，请在手机上确认登录';
          });
        }
        break;
      case 4:
        _timer?.cancel();
        if (mounted) {
          setState(() {
            _status = _QrStatus.success;
            _message = '登录成功';
          });
        }
        // cookie 已由 ApiService.sodaLoginQrCheck 整串保存，刷新登录态
        await context.read<AuthState>().onSodaLoginSuccess();
        if (mounted) {
          await Future.delayed(Duration(milliseconds: 200));
          if (mounted) Navigator.pop(context, true);
        }
        break;
      default:
        break;
    }
  }

  // ---------- 汽水一键导入 PC 登录态 ----------

  Future<void> _oneClickSodaLogin() async {
    setState(() => _isLoading = true);
    try {
      await ApiService.sodaLoginLocal();
      // 成功：cookie 已由 sodaLoginLocal 保存，刷新汽水登录态后关闭弹窗
      await context.read<AuthState>().onSodaLoginSuccess();
      if (mounted) {
        setState(() => _isLoading = false);
        Navigator.pop(context, true);
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _status = _QrStatus.error;
        _message = e is ApiException ? e.message : '一键导入失败：$e';
      });
    }
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
      insetPadding: EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: GlassCard(
        padding: EdgeInsets.fromLTRB(24, 28, 24, 20),
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
                    color: Color(0xFFE05A8A).withOpacity(0.22),
                    border: Border.all(
                      color: fgPrimary.withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    Icons.music_note,
                    color: fgPrimary,
                    size: 16,
                  ),
                ),
                SizedBox(width: 10),
                Text(
                  '扫码登录',
                  style: TextStyle(
                    color: fgPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            // 音源切换（四入口）
            Row(
              children: [
                _sourceTab('网易云', 'netease'),
                SizedBox(width: 8),
                _sourceTab('酷狗', 'kugou'),
                SizedBox(width: 8),
                _sourceTab('QQ', 'qq'),
                SizedBox(width: 8),
                _sourceTab('汽水', 'soda'),
              ],
            ),
            SizedBox(height: 6),
            // 二维码区
            _buildQrArea(),
            SizedBox(height: 16),
            // 状态文案
            Text(
              _message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _status == _QrStatus.success
                    ? Color(0xFF8FE0A0)
                    : (_status == _QrStatus.expired ||
                              _status == _QrStatus.error
                          ? Color(0xFFE0A05A)
                          : fgPrimary.withOpacity(0.7)),
                fontSize: 13,
                height: 1.5,
              ),
            ),
            SizedBox(height: 18),
            // 操作按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(
                    '取消',
                    style: TextStyle(color: fgPrimary.withOpacity(0.55)),
                  ),
                ),
                if (_status == _QrStatus.expired || _status == _QrStatus.error)
                  TextButton.icon(
                    onPressed: _fetchQr,
                    icon: Icon(
                      Icons.refresh,
                      color: fgPrimary,
                      size: 16,
                    ),
                    label: Text(
                      '刷新二维码',
                      style: TextStyle(color: fgPrimary),
                    ),
                    style: TextButton.styleFrom(
                      backgroundColor: fgPrimary.withOpacity(0.14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: fgPrimary.withOpacity(0.3)),
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

  /// 音源切换按钮：选中白色高亮胶囊，未选中半透明
  Widget _sourceTab(String label, String value) {
    final selected = _source == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => _switchSource(value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            gradient: selected
                ? LinearGradient(
                    colors: [
                      fgPrimary.withOpacity(0.26),
                      fgPrimary.withOpacity(0.10),
                    ],
                  )
                : null,
            color: selected ? null : fgPrimary.withOpacity(0.07),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected
                  ? fgPrimary.withOpacity(0.4)
                  : fgPrimary.withOpacity(0.14),
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? fgPrimary : fgPrimary.withOpacity(0.55),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQrArea() {
    final size = 200.0;
    // 汽水：不渲染二维码，显示一键导入 PC 登录态按钮
    if (_isSoda) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            const Icon(Icons.laptop_windows, size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              '汽水音乐扫码已被平台风控拦截',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const Text(
              '请使用电脑端一键导入登录态',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _isLoading ? null : _oneClickSodaLogin,
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt),
              label: Text(_isLoading ? '正在导入…' : '一键导入 PC 登录态'),
            ),
            const SizedBox(height: 8),
            const Text(
              '要求：电脑上运行后端 + 汽水 PC 客户端已登录',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      );
    }
    if (_status == _QrStatus.loading) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: CircularProgressIndicator(
            color: fgPrimary.withOpacity(0.7),
            strokeWidth: 2.5,
          ),
        ),
      );
    }
    final qr = _buildQrImage(size);
    if (qr == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Icon(
            Icons.broken_image,
            color: fgPrimary.withOpacity(0.4),
            size: 48,
          ),
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
            color: fgPrimary.withOpacity(0.10),
            border: Border.all(color: fgPrimary.withOpacity(0.3), width: 1),
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
        ClipRRect(borderRadius: BorderRadius.circular(16), child: qr),
        // 成功蒙层
        if (_status == _QrStatus.success)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                color: Colors.black.withOpacity(0.55),
                child: const Icon(
                  Icons.check_circle,
                  color: Color(0xFF8FE0A0),
                  size: 56,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 构造二维码 widget：汽水 qr_url 是 http 图片地址 → Image.network；
  /// 其余音源是 data:image base64 → 解码后 Image.memory。解析失败返回 null。
  Widget? _buildQrImage(double size) {
    final raw = _qrimg;
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: raw,
        width: size,
        height: size,
        fit: BoxFit.contain,
        httpHeaders: kImageHttpHeaders,
        placeholder: (_, __) => SizedBox(
          width: size,
          height: size,
          child: Center(
            child: CircularProgressIndicator(
              color: fgPrimary.withOpacity(0.5),
              strokeWidth: 2,
            ),
          ),
        ),
        errorWidget: (_, __, ___) => Container(
          color: fgPrimary.withOpacity(0.10),
          child: Icon(
            Icons.broken_image,
            color: fgPrimary.withOpacity(0.4),
            size: 48,
          ),
        ),
      );
    }
    final bytes = _decodeQr();
    if (bytes == null) return null;
    return Image.memory(
      bytes,
      width: size,
      height: size,
      fit: BoxFit.contain,
      gaplessPlayback: true,
    );
  }
}


