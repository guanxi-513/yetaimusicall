/// 网易云登录状态（Provider ChangeNotifier）
///
/// 管理：登录态、用户信息、二维码登录流程、退出登录
library;

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';

import '../models/app_user.dart';
import '../services/api_service.dart';

class AuthState extends ChangeNotifier {
  bool _loggedIn = false;
  bool _checking = true;
  AppUser? _user;

  bool get loggedIn => _loggedIn;
  bool get checking => _checking;
  AppUser? get user => _user;

  AuthState() {
    _init();
  }

  Future<void> _init() async => refresh();

  /// 拉取 /status，判断当前是否已登录（cookie 由服务端保存）
  Future<void> refresh() async {
    _checking = true;
    notifyListeners();
    try {
      final s = await ApiService.status();
      _loggedIn = s.loggedIn;
      _user = s.user;
    } catch (_) {
      _loggedIn = false;
      _user = null;
    }
    _checking = false;
    notifyListeners();
  }

  /// 登录成功后调用，刷新用户信息
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

  /// 退出登录：先尝试服务端登出，再本地清空并重新拉取状态
  Future<void> logout() async {
    await ApiService.logout();
    _loggedIn = false;
    _user = null;
    notifyListeners();
    unawaited(refresh());
  }
}
