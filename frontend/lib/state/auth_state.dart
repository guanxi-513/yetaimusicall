/// 三音源登录状态（Provider ChangeNotifier）
///
/// 网易云、酷狗、QQ 三组完全独立的登录态，互不覆盖、可同时登录：
/// - 网易云：`loggedIn` / `user`（/status 轮询）
/// - 酷狗：`kugouLoggedIn` / `kugouUserId`（/kugou/status，登录态在客户端 cookie）
/// - QQ：`qqLoggedIn` / `qqUserId`（/qq/status，登录态在客户端 cookie）
library;

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';

import '../models/app_user.dart';
import '../services/api_service.dart';

class AuthState extends ChangeNotifier {
  // ---------- 网易云 ----------
  bool _loggedIn = false;
  bool _checking = true;
  AppUser? _user;

  bool get loggedIn => _loggedIn;
  bool get checking => _checking;
  AppUser? get user => _user;

  // ---------- 酷狗 ----------
  bool _kugouLoggedIn = false;
  bool _kugouChecking = true;
  String _kugouUserId = '';

  bool get kugouLoggedIn => _kugouLoggedIn;
  bool get kugouChecking => _kugouChecking;
  String get kugouUserId => _kugouUserId;

  // ---------- QQ ----------
  bool _qqLoggedIn = false;
  bool _qqChecking = true;
  String _qqUserId = '';

  bool get qqLoggedIn => _qqLoggedIn;
  bool get qqChecking => _qqChecking;
  String get qqUserId => _qqUserId;

  // ---------- 汽水音乐 ----------
  bool _sodaLoggedIn = false;
  bool _sodaChecking = true;
  AppUser? _sodaUser;

  bool get sodaLoggedIn => _sodaLoggedIn;
  bool get sodaChecking => _sodaChecking;
  AppUser? get sodaUser => _sodaUser;

  AuthState() {
    _init();
  }

  Future<void> _init() async => refresh();

  /// 拉取三个音源的登录状态（cookie 均由客户端保存并随请求回传）
  Future<void> refresh() async {
    _checking = true;
    _kugouChecking = true;
    _qqChecking = true;
    _sodaChecking = true;
    notifyListeners();

    // 网易云
    try {
      final s = await ApiService.status();
      _loggedIn = s.loggedIn;
      _user = s.user;
    } catch (_) {
      _loggedIn = false;
      _user = null;
    }

    // 酷狗（本地无 cookie 时必然未登录，跳过网络请求）
    try {
      if (ApiService.kugouCookie.isEmpty) {
        _kugouLoggedIn = false;
        _kugouUserId = '';
      } else {
        final s = await ApiService.kugouStatus();
        _kugouLoggedIn = s.loggedIn;
        _kugouUserId = s.userid;
      }
    } catch (_) {
      _kugouLoggedIn = false;
      _kugouUserId = '';
    }

    // QQ（本地无 cookie 时必然未登录，跳过网络请求）
    try {
      if (ApiService.qqCookie.isEmpty) {
        _qqLoggedIn = false;
        _qqUserId = '';
      } else {
        final s = await ApiService.qqStatus();
        _qqLoggedIn = s.loggedIn;
        _qqUserId = s.userid;
      }
    } catch (_) {
      _qqLoggedIn = false;
      _qqUserId = '';
    }

    // 汽水（本地无 cookie 时必然未登录，跳过网络请求）
    try {
      if (ApiService.sodaCookie.isEmpty) {
        _sodaLoggedIn = false;
        _sodaUser = null;
      } else {
        final s = await ApiService.sodaStatus();
        _sodaLoggedIn = s.loggedIn;
        _sodaUser = s.user;
      }
    } catch (_) {
      _sodaLoggedIn = false;
      _sodaUser = null;
    }

    _checking = false;
    _kugouChecking = false;
    _qqChecking = false;
    _sodaChecking = false;
    notifyListeners();
  }

  /// 网易云登录成功后调用，刷新用户信息
  ///
  /// 服务端在 803 响应时可能尚未完全落盘登录态，
  /// 因此先等待片刻再调 /status，如果仍为 false 则重试。
  Future<void> onLoginSuccess() async {
    await Future.delayed(const Duration(milliseconds: 400));
    await refresh();
    // 重试最多 2 次（总等待 ~1.6s + 网络）
    for (int i = 0; i < 2 && !_loggedIn; i++) {
      await Future.delayed(const Duration(milliseconds: 600));
      await refresh();
    }
  }

  /// 酷狗登录成功后调用（cookie 已由 ApiService.kugouLoginCheck 整串保存）
  Future<void> onKugouLoginSuccess() async {
    await refresh();
    // 短重试（酷狗登录态在客户端 cookie，一般一次即成功）
    for (int i = 0; i < 2 && !_kugouLoggedIn; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      await refresh();
    }
  }

  /// QQ 登录成功后调用（cookie 已由 ApiService.qqLoginCheck 整串保存）
  Future<void> onQQLoginSuccess() async {
    await refresh();
    // 短重试（QQ 登录态在客户端 cookie，一般一次即成功）
    for (int i = 0; i < 2 && !_qqLoggedIn; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      await refresh();
    }
  }

  /// 网易云退出登录：先尝试服务端登出，再本地清空并重新拉取状态
  Future<void> logout() async {
    await ApiService.logout();
    _loggedIn = false;
    _user = null;
    notifyListeners();
    unawaited(refresh());
  }

  /// 酷狗退出登录：清客户端本地 cookie（不影响网易云/QQ）
  Future<void> kugouLogout() async {
    await ApiService.kugouLogout();
    _kugouLoggedIn = false;
    _kugouUserId = '';
    notifyListeners();
  }

  /// QQ 退出登录：清客户端本地 cookie（不影响网易云/酷狗）
  Future<void> qqLogout() async {
    await ApiService.qqLogout();
    _qqLoggedIn = false;
    _qqUserId = '';
    notifyListeners();
  }

  /// 汽水登录成功后调用（cookie 已由 ApiService.sodaLoginQrCheck 整串保存）
  Future<void> onSodaLoginSuccess() async {
    await refresh();
    // 短重试（汽水登录态在客户端 cookie，一般一次即成功）
    for (int i = 0; i < 2 && !_sodaLoggedIn; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      await refresh();
    }
  }

  /// 汽水退出登录：清客户端本地 cookie（不影响其他音源）
  Future<void> sodaLogout() async {
    await ApiService.sodaLogout();
    _sodaLoggedIn = false;
    _sodaUser = null;
    notifyListeners();
  }
}
