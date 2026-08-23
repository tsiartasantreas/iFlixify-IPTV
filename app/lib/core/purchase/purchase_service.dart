import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import '../data/supabase_client.dart';
import '../entitlement/entitlement_service.dart';

/// Manages Google Play Billing for Pro upgrade.
///
/// Product ID: `pro_lifetime` (non-consumable one-time purchase).
class PurchaseService {
  PurchaseService({EntitlementService? entitlementService})
      : _entitlement = entitlementService;

  final EntitlementService? _entitlement;
  final InAppPurchase _iap = InAppPurchase.instance;

  static const String _proProductId = 'pro_lifetime';

  StreamSubscription<List<PurchaseDetails>>? _subscription;
  ProductDetails? _proProduct;
  bool _isAvailable = false;
  bool _purchasePending = false;
  String? _purchaseError;

  bool get isAvailable => _isAvailable;
  bool get isPurchasePending => _purchasePending;
  String? get purchaseError => _purchaseError;
  ProductDetails? get proProduct => _proProduct;

  /// Initialize the purchase service. Call once at app startup.
  Future<void> initialize() async {
    _isAvailable = await _iap.isAvailable();
    if (!_isAvailable) return;

    // Listen for purchase updates
    _subscription = _iap.purchaseStream.listen(
      _onPurchaseUpdate,
      onDone: () => _subscription?.cancel(),
      onError: (error) => debugPrint('[PurchaseService] Stream error: $error'),
    );

    // Load product details
    await _loadProducts();
  }

  Future<void> _loadProducts() async {
    final response = await _iap.queryProductDetails({_proProductId});
    if (response.error != null) {
      debugPrint('[PurchaseService] Product query error: ${response.error}');
      return;
    }
    if (response.productDetails.isNotEmpty) {
      _proProduct = response.productDetails.first;
    }
  }

  /// Start the Pro upgrade purchase flow.
  Future<void> buyPro() async {
    if (_proProduct == null) {
      _purchaseError = 'Product not available. Please try again later.';
      return;
    }

    _purchasePending = true;
    _purchaseError = null;

    final purchaseParam = PurchaseParam(productDetails: _proProduct!);
    await _iap.buyNonConsumable(purchaseParam: purchaseParam);
  }

  /// Restore previous purchases (for reinstall scenarios).
  Future<void> restorePurchases() async {
    await _iap.restorePurchases();
  }

  void _onPurchaseUpdate(List<PurchaseDetails> purchaseDetailsList) {
    for (final purchase in purchaseDetailsList) {
      _handlePurchase(purchase);
    }
  }

  Future<void> _handlePurchase(PurchaseDetails purchase) async {
    if (purchase.status == PurchaseStatus.purchased ||
        purchase.status == PurchaseStatus.restored) {
      // Verify with Supabase and upgrade tier
      await _verifyAndUpgrade(purchase);
    } else if (purchase.status == PurchaseStatus.error) {
      _purchaseError = purchase.error?.message ?? 'Purchase failed';
      _purchasePending = false;
    } else if (purchase.status == PurchaseStatus.canceled) {
      _purchasePending = false;
    }

    // Complete the purchase (required for non-consumable)
    if (purchase.pendingCompletePurchase) {
      await _iap.completePurchase(purchase);
    }
  }

  Future<void> _verifyAndUpgrade(PurchaseDetails purchase) async {
    try {
      final supabase = SupabaseService.client;
      final user = supabase.auth.currentUser;
      if (user == null) {
        _purchaseError = 'Please sign in first';
        _purchasePending = false;
        return;
      }

      // Update tier in Supabase
      await supabase.from('profiles').update({
        'tier': 'pro',
      }).eq('id', user.id);

      // Refresh entitlement cache
      await _entitlement?.refreshTier();

      _purchasePending = false;
      debugPrint('[PurchaseService] Pro upgrade successful');
    } catch (e) {
      _purchaseError = 'Failed to activate Pro: $e';
      _purchasePending = false;
    }
  }

  void dispose() {
    _subscription?.cancel();
  }
}
