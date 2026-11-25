// lib/controllers/data/data_controller.dart

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';

import '../../models/data/getDataBundlesModel.dart';
import '../../models/data/getDataProvidersModel.dart';
import '../../models/data/purchaseDataModel.dart';
import '../../providers/data/mock_data_responses.dart';

enum DataProviderStatus { initial, loading, loaded, error }

enum DataBundleStatus { initial, loading, loaded, error }

enum DataPurchaseStatus { initial, processing, success, error }

enum BundleCategory { all, daily, weekly, monthly, others }

class DataController extends GetxController {
  final _box = GetStorage();
  static const _dataProvidersKey = 'dataProviders';
  static const _dataProvidersTimestampKey = 'dataProvidersTimestamp';
  static const _bundlesKeyPrefix = 'dataBundles_'; // + providerId
  static const _bundlesTimestampKeyPrefix = 'dataBundlesTimestamp_'; // + providerId
  static const _cacheDuration = Duration(hours: 24);

  // ── Status ─────────────────────────────────────────────────────────────────
  DataProviderStatus _providerStatus = DataProviderStatus.initial;
  DataBundleStatus _bundleStatus = DataBundleStatus.initial;
  DataPurchaseStatus _purchaseStatus = DataPurchaseStatus.initial;
  String? _providerError;
  String? _bundleError;
  String? _purchaseError;
  PurchaseDataModel? _purchaseResult;

  DataProviderStatus get providerStatus => _providerStatus;
  DataBundleStatus get bundleStatus => _bundleStatus;
  DataPurchaseStatus get purchaseStatus => _purchaseStatus;
  String? get providerError => _providerError;
  String? get bundleError => _bundleError;
  String? get purchaseError => _purchaseError;

  /// Full purchase response (reference, transaction.createdAt, amounts …).
  PurchaseDataModel? get purchaseResult => _purchaseResult;

  bool get isLoadingProviders => _providerStatus == DataProviderStatus.loading;
  bool get isLoadingBundles => _bundleStatus == DataBundleStatus.loading;
  bool get isPurchasing => _purchaseStatus == DataPurchaseStatus.processing;
  bool get isLoading => isLoadingProviders || isLoadingBundles || isPurchasing;

  // ── Networks (replaces the getDataProviderModel StateProvider) ─────────────
  GetDataProviderModel? _providersModel;
  GetDataProviderModel? get providersModel => _providersModel;
  List<ProviderData> get networks => _providersModel?.data?.data ?? const [];

  // ── Selected network ───────────────────────────────────────────────────────
  String? _selectedProvider;
  String? _selectedProviderId;
  String? _selectedIcon;
  int _selectedIndex = 0;

  String? get selectedProvider => _selectedProvider;
  String? get selectedProviderId => _selectedProviderId;
  String? get selectedIcon => _selectedIcon;
  int get selectedIndex => _selectedIndex;

  /// Selects a network and loads its bundles (memory → cache → API).
  /// Clears the selected bundle — plans don't carry across networks.
  Future<void> selectProvider({required int index, required ProviderData provider}) async {
    final changed = provider.sId != _selectedProviderId;
    _selectedIndex = index;
    _selectedProvider = provider.name;
    _selectedProviderId = provider.sId;
    _selectedIcon = provider.logoUrl;
    if (changed) {
      _selectedBundle = null;
      _activeCategory = BundleCategory.all;
      _bundleSearchQuery = '';
    }
    update();
    if (provider.sId != null) await getDataBundles(providerId: provider.sId!);
  }

  // ── Bundles, filters, selection ────────────────────────────────────────────
  final Map<String, List<Data01>> _bundlesByProvider = {};
  final Map<String, GroupedProducts> _groupedByProvider = {};

  /// Requests already running, by providerId. A tap during the prefetch
  /// waits on the same request instead of firing a second one.
  final Map<String, Future<GetDataBundleModel>> _inFlight = {};

  List<String> _knownProviderIds = const [];

  /// True once every network's plans are in memory.
  bool get allBundlesLoaded =>
      _knownProviderIds.isNotEmpty && _knownProviderIds.every(_bundlesByProvider.containsKey);

  BundleCategory _activeCategory = BundleCategory.all;
  String _bundleSearchQuery = '';
  Data01? _selectedBundle;

  BundleCategory get activeCategory => _activeCategory;
  String get bundleSearchQuery => _bundleSearchQuery;
  Data01? get selectedBundle => _selectedBundle;

  /// All bundles for the selected network.
  List<Data01> get allBundles => _bundlesByProvider[_selectedProviderId] ?? const [];

  /// Selected network's plans as a model (replaces the getDataBundleModel
  /// StateProvider). Null until that network's plans have loaded.
  GetDataBundleModel? get selectedBundleModel {
    final id = _selectedProviderId;
    final bundles = id == null ? null : _bundlesByProvider[id];
    if (bundles == null) return null;
    return GetDataBundleModel(
      success: true,
      data: Data(data: bundles, groupedProducts: _groupedByProvider[id]),
    );
  }

  List<Data01> _bundlesIn(BundleCategory category) {
    final grouped = _groupedByProvider[_selectedProviderId];
    switch (category) {
      case BundleCategory.all:
        return allBundles;
      case BundleCategory.daily:
        return grouped?.daily ?? const [];
      case BundleCategory.weekly:
        return grouped?.weekly ?? const [];
      case BundleCategory.monthly:
        return grouped?.monthly ?? const [];
      case BundleCategory.others:
        return grouped?.others ?? const [];
    }
  }

  /// Bundles for the active tab, narrowed by the search box.
  List<Data01> get filteredBundles {
    final base = _bundlesIn(_activeCategory);
    final q = _bundleSearchQuery.trim().toLowerCase();
    if (q.isEmpty) return base;
    return base.where((b) {
      final name = b.validity?.toLowerCase() ?? '';
      return name.contains(q) || b.amount.toStringAsFixed(0).contains(q);
    }).toList();
  }

  /// Count per tab — handy for hiding empty tabs or showing badges.
  int countFor(BundleCategory category) => _bundlesIn(category).length;

  void selectCategory(BundleCategory category) {
    _activeCategory = category;
    update();
  }

  void searchBundles(String query) {
    _bundleSearchQuery = query;
    update();
  }

  void clearBundleSearch() {
    _bundleSearchQuery = '';
    update();
  }

  void selectBundle(Data01 bundle) {
    _selectedBundle = bundle;
    update();
  }

  bool isBundleSelected(Data01 bundle) =>
      _selectedBundle != null && _selectedBundle!.bundleCode == bundle.bundleCode;

  void clearSelectedBundle() {
    _selectedBundle = null;
    update();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  String _friendlyError(Object e, String fallback) {
    if (e is StateError) return e.message;
    return fallback;
  }

  /// Returns the decoded JSON for [key] if it's younger than 24h, else null
  /// (and clears it).
  Map<String, dynamic>? _readCache(String key, String timestampKey) {
    try {
      final raw = _box.read(key);
      final timestamp = _box.read(timestampKey);
      if (raw is! String || timestamp is! String) return null;
      final age = DateTime.now().difference(DateTime.parse(timestamp));
      if (age.isNegative || age >= _cacheDuration) {
        unawaited(_clearCache(key, timestampKey));
        return null;
      }
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      unawaited(_clearCache(key, timestampKey));
      return null;
    }
  }

  Future<void> _writeCache(String key, String timestampKey, Map<String, dynamic> json) async {
    await _box.write(key, jsonEncode(json));
    await _box.write(timestampKey, DateTime.now().toIso8601String());
  }

  /// Saves to storage in the background. The UI never waits on disk I/O;
  /// a failed write only loses the cache.
  void _writeCacheInBackground(String key, String timestampKey, Map<String, dynamic> json) {
    unawaited(
      _writeCache(key, timestampKey, json).catchError((Object e) {
        debugPrint('⚠️ Cache write failed for $key: $e');
      }),
    );
  }

  Future<void> _clearCache(String key, String timestampKey) async {
    await _box.remove(key);
    await _box.remove(timestampKey);
  }

  void _storeBundles(String providerId, GetDataBundleModel model) {
    final bundles = model.data?.data ?? <Data01>[];
    _bundlesByProvider[providerId] = bundles;
    _groupedByProvider[providerId] =
        model.data?.groupedProducts ?? GroupedProducts.fromFlatList(bundles);
    // Rebuild the moment any network's plans land, whichever method fetched them.
    update();
  }

  // ── GET /bill-payments/services/{dataServiceId}/categories ─────────────────
  /// Loads networks. Uses the 24h cache unless [forceRefresh] is true.
  Future<void> getDataProviders({bool forceRefresh = false}) async {
    _providerStatus = DataProviderStatus.loading;
    _providerError = null;
    update();
    try {
      final cached = forceRefresh ? null : _readCache(_dataProvidersKey, _dataProvidersTimestampKey);
      if (cached != null) {
        _providersModel = GetDataProviderModel.fromJson(cached);
      } else {
        await Future.delayed(const Duration(milliseconds: 1200));
        final response = MockDataResponses.dataProviders;
        if (response['success'] != true) {
          throw StateError(response['message']?.toString() ?? 'Failed to load networks');
        }
        _providersModel = GetDataProviderModel.fromJson(response);
        _writeCacheInBackground(_dataProvidersKey, _dataProvidersTimestampKey, response);
      }
      _knownProviderIds = networks.map((p) => p.sId).whereType<String>().toList();
      _providerStatus = DataProviderStatus.loaded;
    } catch (e) {
      _providerStatus = DataProviderStatus.error;
      _providerError = _friendlyError(e, 'Failed to load networks');
    } finally {
      update();
    }
  }

  // ── GET /bill-payments/categories/{providerId}/products ────────────────────

  /// Fetches one network's plans: storage (24h) → API. Stores them in memory.
  /// Doesn't touch status — callers decide what the screen should show.
  /// Concurrent calls for the same network share one request.
  Future<GetDataBundleModel> _fetchBundles(String providerId, {bool forceRefresh = false}) {
    final running = _inFlight[providerId];
    if (running != null) return running;

    Future<GetDataBundleModel> run() async {
      final bundlesKey = '$_bundlesKeyPrefix$providerId';
      final timestampKey = '$_bundlesTimestampKeyPrefix$providerId';

      final cached = forceRefresh ? null : _readCache(bundlesKey, timestampKey);
      if (cached != null) {
        final model = GetDataBundleModel.fromJson(cached);
        _storeBundles(providerId, model);
        return model;
      }

      await Future.delayed(const Duration(milliseconds: 900));
      final response = MockDataResponses.bundlesFor(providerId);
      if (response['success'] != true) {
        throw StateError(response['message']?.toString() ?? 'Failed to load data plans');
      }
      final model = GetDataBundleModel.fromJson(response);
      _storeBundles(providerId, model); // memory first → screen updates now
      _writeCacheInBackground(bundlesKey, timestampKey, response); // disk later
      return model;
    }

    final future = run().whenComplete(() => _inFlight.remove(providerId));
    _inFlight[providerId] = future;
    return future;
  }

  /// Loads plans for EVERY network in parallel (Future.wait), so switching
  /// networks afterwards is instant. Already-loaded networks are skipped
  /// unless [forceRefresh]. One network failing doesn't stop the others.
  Future<void> getAllDataBundles({bool forceRefresh = false}) async {
    _knownProviderIds = networks.map((p) => p.sId).whereType<String>().toList();
    if (_knownProviderIds.isEmpty) return;

    final toLoad = forceRefresh
        ? _knownProviderIds
        : _knownProviderIds.where((id) => !_bundlesByProvider.containsKey(id)).toList();
    if (toLoad.isEmpty) return; // everything already in memory

    final selectedMissing = _selectedProviderId != null && toLoad.contains(_selectedProviderId);
    if (selectedMissing) {
      _bundleStatus = DataBundleStatus.loading;
      _bundleError = null;
      update();
    }

    final errors = <String, String>{};
    await Future.wait(
      toLoad.map((id) async {
        try {
          await _fetchBundles(id, forceRefresh: forceRefresh);
        } catch (e) {
          errors[id] = _friendlyError(e, 'Failed to load data plans');
        }
      }),
    );

    // Reflect the result for whichever network is on screen now.
    final selected = _selectedProviderId;
    if (selected != null && toLoad.contains(selected)) {
      if (errors.containsKey(selected) && !_bundlesByProvider.containsKey(selected)) {
        _bundleStatus = DataBundleStatus.error;
        _bundleError = errors[selected];
      } else {
        _bundleStatus = DataBundleStatus.loaded;
        _bundleError = null;
      }
    }
    update();
  }

  /// Loads plans for one network: memory → in-flight request → storage → API.
  /// If the user switches network mid-load, the late result is still stored
  /// but doesn't change the status of the network now on screen.
  Future<void> getDataBundles({required String providerId, bool forceRefresh = false}) async {
    if (!forceRefresh && _bundlesByProvider.containsKey(providerId)) {
      if (providerId == _selectedProviderId) {
        _bundleStatus = DataBundleStatus.loaded;
        _bundleError = null;
        update();
      }
      return; // instant — already loaded (e.g. by getAllDataBundles)
    }

    _bundleStatus = DataBundleStatus.loading;
    _bundleError = null;
    update();
    try {
      await _fetchBundles(providerId, forceRefresh: forceRefresh);
      if (providerId == _selectedProviderId) {
        _bundleStatus = DataBundleStatus.loaded;
      }
    } catch (e) {
      if (providerId == _selectedProviderId) {
        _bundleStatus = DataBundleStatus.error;
        _bundleError = _friendlyError(e, 'Failed to load data plans');
      }
    } finally {
      update();
    }
  }

  // ── POST /bill-payments/data ────────────────────────────────────────────────
  /// Buys the currently selected bundle on the selected network.
  Future<void> purchaseData({
    required String phoneNumber,
    String? transactionPin, // the real endpoint needs this; the mock ignores it
  }) async {
    if (isPurchasing) return; // never fire two debits for one tap

    _purchaseStatus = DataPurchaseStatus.processing;
    _purchaseError = null;
    _purchaseResult = null;
    update();
    try {
      final bundle = _selectedBundle;
      final providerId = _selectedProviderId;
      if (providerId == null) throw StateError('Select a network to continue');
      if (bundle == null || bundle.bundleCode == null) {
        throw StateError('Select a data plan to continue');
      }

      // Real request body, for when this goes live:
      // {
      //   "serviceCategoryId": providerId,
      //   "bundleCode": bundle.bundleCode,
      //   "channel": "MOBILE",
      //   "amount": bundle.amount,
      //   "phoneNumber": phoneNumber,
      //   "transactionPin": transactionPin,
      // }  + header 'Idempotency-Key' (one per purchase attempt)

      await Future.delayed(const Duration(seconds: 2));
      final response = MockDataResponses.purchaseData;
      if (response['success'] != true) {
        throw StateError(response['message']?.toString() ?? 'Data purchase failed');
      }
      final result = PurchaseDataModel.fromJson(response);
      final status = result.data?.status?.toLowerCase();
      if (status == 'failed' || status == 'reversed') {
        throw StateError('Transaction was not successful');
      }

      _purchaseResult = result;
      _purchaseStatus = DataPurchaseStatus.success;
    } catch (e) {
      _purchaseStatus = DataPurchaseStatus.error;
      _purchaseError = _friendlyError(e, 'Data purchase failed. Please try again.');
    } finally {
      update();
    }
  }

  void resetPurchaseStatus() {
    _purchaseStatus = DataPurchaseStatus.initial;
    _purchaseError = null;
    _purchaseResult = null;
    update();
  }

  /// Wipes networks + every cached bundle list (memory and storage).
  Future<void> clearAllDataCache() async {
    await _clearCache(_dataProvidersKey, _dataProvidersTimestampKey);
    // Every per-network bundle key, including ones not loaded this session.
    final bundleKeys = (_box.getKeys() as Iterable)
        .whereType<String>()
        .where((k) => k.startsWith(_bundlesKeyPrefix) || k.startsWith(_bundlesTimestampKeyPrefix))
        .toList();
    for (final k in bundleKeys) {
      await _box.remove(k);
    }
    _providersModel = null;
    _bundlesByProvider.clear();
    _groupedByProvider.clear();
    _knownProviderIds = const [];
    _selectedBundle = null;
    _bundleStatus = DataBundleStatus.initial;
    update();
  }
}
