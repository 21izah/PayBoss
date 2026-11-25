// lib/controllers/airtime/airtime_controller.dart
//
// GetX (simple state manager) version of AirtimeProvider — use with
// GetBuilder<AirtimeController>(builder: (c) => ...).
//
// Plain fields + update(), exactly like notifyListeners() in the
// ChangeNotifier version and like your LoginController.
//   • status enums for loading providers and purchasing
//   • 24h cache for the networks list (GetStorage)
//   • mock API simulation (MockAirtimeResponses)
//   • never fires two purchases for one tap

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

// >>> Adjust these paths to match your project structure. <<<
import '../../models/airtime/getAllProvidersModel.dart';
import '../../models/airtime/getMobileProvidersModel.dart';
import '../../providers/airtime/mock_airtime_responses.dart';

enum AirtimeProviderStatus { initial, loading, loaded, error }

enum AirtimePurchaseStatus { initial, processing, success, error }

class AirtimeController extends GetxController {
  final _box = GetStorage();
  static const _mobileProvidersKey = 'mobileProviders';
  static const _mobileProvidersTimestampKey = 'mobileProvidersTimestamp';
  static const _cacheDuration = Duration(hours: 24);

  // ── Status ─────────────────────────────────────────────────────────────────
  AirtimeProviderStatus _providerStatus = AirtimeProviderStatus.initial;
  AirtimePurchaseStatus _purchaseStatus = AirtimePurchaseStatus.initial;
  String? _providerError;
  String? _purchaseError;
  Map<String, dynamic>? _purchaseTransaction;

  AirtimeProviderStatus get providerStatus => _providerStatus;
  AirtimePurchaseStatus get purchaseStatus => _purchaseStatus;
  String? get providerError => _providerError;
  String? get purchaseError => _purchaseError;
  Map<String, dynamic>? get purchaseTransaction => _purchaseTransaction;

  bool get isLoadingProviders => _providerStatus == AirtimeProviderStatus.loading;
  bool get isPurchasing => _purchaseStatus == AirtimePurchaseStatus.processing;
  bool get isLoading => isLoadingProviders || isPurchasing;

  // ── Data (replaces the Riverpod StateProviders) ────────────────────────────
  GetAllProvider? _allServices;
  GetMobileProviderModel? _mobileProviders;

  GetAllProvider? get allServices => _allServices;
  GetMobileProviderModel? get mobileProviders => _mobileProviders;

  /// The list of networks, empty until loaded.
  List<ProviderData> get networks => _mobileProviders?.data?.data ?? const [];

  /// Service id for AIRTIME, once getAllProviders() has run.
  String? get airtimeServiceId => _allServices?.getIdByIdentifier('AIRTIME');

  // ── Selected network ───────────────────────────────────────────────────────
  String? _selectedProvider;
  String? _selectedProviderId;
  String? _selectedIcon;
  int _selectedIndex = 0;

  String? get selectedProvider => _selectedProvider;
  String? get selectedProviderId => _selectedProviderId;
  String? get selectedIcon => _selectedIcon;
  int get selectedIndex => _selectedIndex;

  /// Selected network as a model, or null.
  ProviderData? get selectedNetwork {
    for (final p in networks) {
      if (p.sId == _selectedProviderId) return p;
    }
    return null;
  }

  void selectProvider({
    required int index,
    required String? name,
    required String? id,
    required String? icon,
  }) {
    _selectedIndex = index;
    _selectedProvider = name;
    _selectedProviderId = id;
    _selectedIcon = icon;
    update();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  String _friendlyError(Object e, String fallback) {
    if (e is StateError) return e.message;
    return fallback;
  }

  /// Saves in the background — the UI never waits on storage.
  void _saveToCache(Map<String, dynamic> response) {
    unawaited(
      Future(() async {
        await _box.write(_mobileProvidersKey, jsonEncode(response));
        await _box.write(_mobileProvidersTimestampKey, DateTime.now().toIso8601String());
      }).catchError((Object e) {
        debugPrint('⚠️ Airtime cache write failed: $e');
      }),
    );
  }

  void _clearCache() {
    _box.remove(_mobileProvidersKey);
    _box.remove(_mobileProvidersTimestampKey);
  }

  GetMobileProviderModel? _loadFromCache() {
    try {
      final raw = _box.read(_mobileProvidersKey);
      final timestamp = _box.read(_mobileProvidersTimestampKey);
      if (raw is! String || timestamp is! String) return null;
      final age = DateTime.now().difference(DateTime.parse(timestamp));
      if (age.isNegative || age >= _cacheDuration) {
        _clearCache();
        return null;
      }
      return GetMobileProviderModel.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      _clearCache();
      return null;
    }
  }

  // ── GET /services ──────────────────────────────────────────────────────────
  Future<void> getAllProviders() async {
    _providerStatus = AirtimeProviderStatus.loading;
    _providerError = null;
    update();
    try {
      await Future.delayed(const Duration(milliseconds: 1200));
      final response = MockAirtimeResponses.allServices;
      if (response['success'] != true) {
        throw StateError(response['message']?.toString() ?? 'Failed to load services');
      }
      _allServices = GetAllProvider.fromJson(response);
      _providerStatus = AirtimeProviderStatus.loaded;
    } catch (e) {
      _providerStatus = AirtimeProviderStatus.error;
      _providerError = _friendlyError(e, 'Failed to load services');
    } finally {
      update();
    }
  }

  // ── GET /airtime/providers ─────────────────────────────────────────────────
  /// Loads networks (MTN, Airtel, …). Uses the 24h cache unless [forceRefresh].
  /// Picks the first network if nothing valid is selected yet.
  Future<void> getMobileProviders({bool forceRefresh = false}) async {
    _providerStatus = AirtimeProviderStatus.loading;
    _providerError = null;
    update();
    try {
      final cached = forceRefresh ? null : _loadFromCache();
      if (cached != null) {
        _mobileProviders = cached;
      } else {
        await Future.delayed(const Duration(milliseconds: 1200));
        final response = MockAirtimeResponses.mobileProviders;
        if (response['success'] != true) {
          throw StateError(response['message']?.toString() ?? 'Failed to load networks');
        }
        _mobileProviders = GetMobileProviderModel.fromJson(response);
        _saveToCache(response); // state first, storage in the background
      }

      final list = networks;
      if (list.isNotEmpty && !list.any((p) => p.sId == _selectedProviderId)) {
        final first = list.first;
        _selectedIndex = 0;
        _selectedProvider = first.name;
        _selectedProviderId = first.sId;
        _selectedIcon = first.logoUrl;
      }
      _providerStatus = AirtimeProviderStatus.loaded;
    } catch (e) {
      _providerStatus = AirtimeProviderStatus.error;
      _providerError = _friendlyError(e, 'Failed to load networks');
    } finally {
      update();
    }
  }

  // ── POST purchase ──────────────────────────────────────────────────────────
  Future<void> purchaseAirtime({
    required String phoneNumber,
    required double amount,
    String? providerId, // send this to the real endpoint; the mock ignores it
  }) async {
    if (isPurchasing) return; // never fire two debits for one tap

    _purchaseStatus = AirtimePurchaseStatus.processing;
    _purchaseError = null;
    _purchaseTransaction = null;
    update();
    try {
      await Future.delayed(const Duration(seconds: 2));
      final response = MockAirtimeResponses.purchaseAirtime;
      final envelope = response['data'] as Map<String, dynamic>?;
      if (response['success'] != true || envelope?['statusCode'] != 200) {
        throw StateError(response['message']?.toString() ?? 'Airtime purchase failed');
      }
      final transaction = envelope?['data'];
      if (transaction is! Map<String, dynamic> || transaction['status'] != 'successful') {
        throw StateError('Transaction was not successful');
      }
      _purchaseTransaction = transaction;
      _purchaseStatus = AirtimePurchaseStatus.success;
    } catch (e) {
      _purchaseStatus = AirtimePurchaseStatus.error;
      _purchaseError = _friendlyError(e, 'Airtime purchase failed. Please try again.');
    } finally {
      update();
    }
  }

  void resetPurchaseStatus() {
    _purchaseStatus = AirtimePurchaseStatus.initial;
    _purchaseError = null;
    _purchaseTransaction = null;
    update();
  }

  Future<void> purchaseAirtimeWithBiometric() async {}
}
