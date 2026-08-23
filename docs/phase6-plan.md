# Phase 6 Plan: Google Play Publishing, Payments & Ad Integration

**App:** IPTVication (iflixify)
**Package:** `com.iflixify.iflixify`
**Current Version:** 6.2.0+1
**Date:** 2026-08-23

---

## Phase Overview

Phase 6 takes the app from development-complete to production-published on Google Play. It has four sub-phases:

| Sub-phase | Description | Effort | Dependencies |
|-----------|-------------|--------|--------------|
| **6A** | Google Play Store publishing | 2-3 days | None (can start immediately) |
| **6B** | Google Play payment finalization | 1-2 days | 6A.5 (keystore/signing) |
| **6C** | AdMob integration for free tier | 3-4 days | 6B.2 (product configured) |
| **6D** | Remaining P4 items (admin, webhooks, feature flags) | 2-3 days | 6B.2, 6C.1 |

**Total estimated effort:** 8-12 days

---

## 6A: Google Play Store Publishing

### 6A.1 -- Google Developer Account Setup

**Effort:** 30 minutes

1. Go to [play.google.com/console](https://play.google.com/console)
2. Sign in with a dedicated Google account (not personal)
3. Pay the $25 one-time registration fee
4. Complete developer identity verification (may require government ID)
5. Accept the Google Play Developer Distribution Agreement

**Notes:**
- Use an organization account if publishing as a business
- Keep the Google account secure with 2FA and recovery codes
- Verification can take 24-48 hours

### 6A.2 -- App Listing Preparation

**Effort:** 1-2 days

#### 6A.2.1 -- Store Listing Text

Prepare the following copy:

| Field | Requirement |
|-------|-------------|
| **App name** | "IPTVication" (max 30 chars) |
| **Short description** | Max 80 chars. Example: "Stream your IPTV playlists with a Netflix-style experience." |
| **Full description** | Max 4000 chars. Highlight: playlist import, EPG, favorites, multi-device, Pro features |
| **Category** | Entertainment |
| **Tags** | IPTV, streaming, media player, playlist, EPG |

#### 6A.2.2 -- Screenshots & Graphics

| Asset | Dimensions | Quantity |
|-------|-----------|----------|
| **Screenshots (phone)** | 1080x1920 or 1242x2208 | 2-8 (minimum 2) |
| **Screenshots (tablet)** | 1200x1920 (optional) | 2-8 |
| **Feature graphic** | 1024x500 | 1 (required) |
| **Hi-res icon** | 512x512 PNG | 1 (already have from P5) |

**Screenshots to capture:**
1. Home screen with content grid
2. Player screen with controls
3. EPG / channel guide
4. Favorites / watchlist
5. Settings / Pro upgrade screen
6. Import playlist flow

**Tools:** Use `flutter screenshot` or device capture, then compose in Canva or Figma.

#### 6A.2.3 -- Content Rating Questionnaire

**Effort:** 15 minutes

1. In Play Console: Policy > App content > Content rating
2. Complete the IARC questionnaire
3. Expected rating: PEGI 3 / E for Everyone (media player, no user-generated content)
4. Key answers: no violence, no gambling, no user interaction, no location sharing

#### 6A.2.4 -- Privacy Policy

**Effort:** 1-2 hours

1. Create a privacy policy page (host on your domain or use the admin panel)
2. Must cover:
   - What data is collected (email, playlist URLs, viewing history)
   - How data is stored (Supabase, encrypted)
   - Third-party services (Google AdMob, Sentry, Google Play Billing)
   - User rights (data deletion, export)
   - Contact information
3. URL must be publicly accessible and entered in Play Console under Policy > App content > Privacy policy

**Files to create:**
- `admin/app/privacy/page.tsx` (Next.js page in admin panel)
- Or host as a static page on Wasmer Edge

### 6A.3 -- APK/AAB Signing Configuration

**Effort:** 1-2 hours

#### 6A.3.1 -- Generate Upload Keystore

```bash
keytool -genkey -v \
  -keystore ~/upload-keystore.jks \
  -keyalg RSA -keysize 2048 \
  -validity 10000 \
  -alias upload \
  -storepass <YOUR_PASSWORD> \
  -keypass <YOUR_PASSWORD> \
  -dname "CN=IPTVication, OU=Development, O=YourOrg, L=City, ST=State, C=US"
```

**CRITICAL:** Back up this keystore and password securely. Losing it means you cannot update your app.

#### 6A.3.2 -- Create key.properties

Create `android/key.properties` (add to .gitignore):

```properties
storePassword=<password>
keyPassword=<password>
keyAlias=upload
storeFile=<path-to>/upload-keystore.jks
```

#### 6A.3.3 -- Update build.gradle.kts

Modify `android/app/build.gradle.kts`:

```kotlin
import java.util.Properties

// Load keystore properties
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    // ... existing config ...

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}
```

#### 6A.3.4 -- Build the AAB

```bash
flutter build appbundle --release
```

Output: `build/app/outputs/bundle/release/app-release.aab`

**Files to modify:**
- `/app/android/app/build.gradle.kts`
- `/app/android/key.properties` (new, gitignored)
- `/app/.gitignore` (add key.properties)

### 6A.4 -- Upload to Google Play Console

**Effort:** 1-2 hours

1. Create a new app in Play Console
2. Fill in store listing (6A.2)
3. Set pricing: Free
4. Select countries/regions for distribution
5. Upload the AAB under Release > Production (or testing track first)
6. Complete the content rating questionnaire (6A.2.3)
7. Declare data safety (data collection practices)
8. Submit for review

### 6A.5 -- Testing Track Progression

**Effort:** 3-5 days (mostly waiting for review)

| Track | Purpose | Duration |
|-------|---------|----------|
| **Internal testing** | Team testing, up to 100 testers | 1-2 days |
| **Closed testing** | Beta testers, up to 2000 | 2-3 days |
| **Open testing** | Public beta, anyone can join | 3-7 days |
| **Production** | Live on Play Store | Review: 3-7 days |

**Steps:**
1. Upload AAB to Internal testing track first
2. Add internal testers by email
3. Test purchase flow, ad display, all features
4. Promote to Closed testing with a larger group
5. Collect feedback, fix issues
6. Promote to Open testing (optional)
7. Promote to Production

**First-time app review can take 7-14 days.** Plan accordingly.

### 6A.6 -- Store Listing Optimization (ASO)

**Effort:** 1-2 hours

- Use keywords naturally in title and description
- Include "IPTV" prominently (high search volume)
- A/B test store listing experiments (Play Console feature)
- Respond to all reviews
- Maintain 4.0+ rating
- Regular updates (Play favors actively maintained apps)

---

## 6B: Google Play Payment Setup

### 6B.1 -- Configure In-App Product in Play Console

**Effort:** 30 minutes

1. Play Console > Monetize > Products > In-app products
2. Click "Create product"
3. Product ID: `pro_lifetime` (must match `PurchaseService._proProductId`)
4. Name: "IPTVication Pro - Lifetime"
5. Description: "Unlock all Pro features: unlimited playlists, no ads, priority support"
6. Price: $8.99 USD
7. Tax: "This product is subject to tax" (check local requirements)
8. Status: Active

**Verify:** The product ID `pro_lifetime` in Play Console must exactly match the constant in `purchase_service.dart`.

### 6B.2 -- Verify Existing Purchase Flow

**Effort:** 2-4 hours

The app already has `PurchaseService` and `EntitlementService`. Verify:

1. `PurchaseService.initialize()` is called at app startup
2. `buyPro()` triggers the Google Play payment sheet
3. `_onPurchaseUpdate` handles all purchase states:
   - `purchased` -- grant entitlement, call `completePurchase()`
   - `pending` -- show loading indicator
   - `error` -- show error message
   - `restored` -- re-grant entitlement
4. `EntitlementService.refreshTier()` updates after successful purchase
5. Supabase `profiles.tier` is updated to `'pro'` on purchase

**Files to verify:**
- `/app/lib/core/purchase/purchase_service.dart`
- `/app/lib/core/entitlement/entitlement_service.dart`
- `/app/lib/features/settings/activate_pro_screen.dart`

### 6B.3 -- Server-Side Receipt Validation (Recommended)

**Effort:** 1-2 days

Currently the app validates purchases client-side. For production, add server-side validation:

#### Option A: Supabase Edge Function (Recommended)

Create a Supabase Edge Function that:
1. Receives the purchase token from the client
2. Calls Google Play Developer API to verify the purchase
3. Updates the user's tier in the `profiles` table
4. Returns success/failure to the client

**Files to create:**
- `supabase/functions/validate-purchase/index.ts`

**Setup:**
1. Create a Google Play service account in Google Cloud Console
2. Grant it "Finance" permission in Play Console > Users and permissions
3. Store the service account JSON as a Supabase secret

#### Option B: Webhook-Based (See 6D)

Google Play can send real-time developer notifications (RTDN) to a webhook endpoint.

### 6B.4 -- Testing with License Testers

**Effort:** 1-2 hours

1. Play Console > Setup > License testing
2. Add test Google accounts (up to 400)
3. License testers can purchase without being charged
4. Test all scenarios:
   - Fresh purchase
   - Restore purchase (reinstall)
   - Cancelled purchase (should not grant)
   - Network failure during purchase
   - Already owned (re-purchase attempt)

### 6B.5 -- Billing Library Compliance

**Effort:** 1 hour (verification)

Ensure compliance with Google Play Billing policies:

- [ ] User can see the price before purchasing
- [ ] Purchase confirmation is shown after successful payment
- [ ] "Restore purchases" option is available
- [ ] No misleading descriptions of what Pro includes
- [ ] Subscription terms are clear (lifetime = one-time, not recurring)
- [ ] Refund policy is documented

### 6B.6 -- Future: Subscription Model (Optional)

If switching from one-time to subscription later:

| Tier | Price | Period |
|------|-------|--------|
| Pro Monthly | $2.99 | /month |
| Pro Yearly | $19.99 | /year |
| Pro Lifetime | $8.99 | one-time (legacy) |

This would require:
- New subscription product IDs in Play Console
- `PurchaseService` changes to handle subscriptions
- Grace period / account hold logic
- Server-side subscription status checks

**Not in scope for Phase 6** -- document for future reference.

---

## 6C: Ad Integration for Free Version

### 6C.1 -- AdMob Account & App Setup

**Effort:** 1-2 hours

1. Create an AdMob account at [admob.google.com](https://admob.google.com)
2. Add the app (link to Play Console listing once published)
3. Create ad units:
   - **Interstitial ad unit** (for content change ads)
   - Note: Do NOT create banner ads (not in scope per requirements)
4. Record the ad unit IDs

**Ad Unit IDs:**

| Type | Production ID | Test ID |
|------|--------------|---------|
| Interstitial | `ca-app-pub-XXXXX/YYYYY` | `ca-app-pub-3940256099942544/1033173712` |

### 6C.2 -- Package Integration

**Effort:** 2-4 hours

#### 6C.2.1 -- Add Dependency

In `pubspec.yaml`, add:

```yaml
dependencies:
  google_mobile_ads: ^5.3.0
```

#### 6C.2.2 -- Android Configuration

In `android/app/build.gradle.kts`, add to `dependencies`:

```kotlin
implementation("com.google.android.gms:play-services-ads:23.3.0")
```

In `android/app/src/main/AndroidManifest.xml`, add inside `<application>`:

```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY"/>
```

**CRITICAL:** The APPLICATION_ID is your AdMob app ID (different from ad unit IDs). Using test IDs during development is mandatory.

#### 6C.2.3 -- iOS Configuration (Future)

Not in scope for Android-only Phase 6, but note for future:
- Add `GADApplicationIdentifier` to `Info.plist`
- Add `SKAdNetworkItems` to `Info.plist`

### 6C.3 -- Ad Service Implementation

**Effort:** 1-2 days

Create a new service to manage ad lifecycle:

**File to create:** `/app/lib/core/ads/ad_service.dart`

```dart
// Pseudocode structure
class AdService {
  // Singleton or provided via dependency injection
  InterstitialAd? _interstitialAd;
  bool _isAdLoaded = false;
  DateTime? _lastAdShown;
  int _adsShownInSession = 0;

  // Configuration
  static const Duration _minIntervalBetweenAds = Duration(minutes: 3);
  static const int _maxAdsPerSession = 10;
  static const int _maxAdsPerHour = 5;

  /// Initialize the AdMob SDK. Call once at app startup.
  Future<void> initialize() async {
    await MobileAds.instance.initialize();
    _loadInterstitialAd();
  }

  /// Pre-load the next interstitial ad.
  void _loadInterstitialAd() {
    InterstitialAd.load(
      adUnitId: _getAdUnitId(),
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _interstitialAd = ad;
          _isAdLoaded = true;
        },
        onAdFailedToLoad: (error) {
          _isAdLoaded = false;
          // Retry after delay
          Future.delayed(const Duration(seconds: 30), _loadInterstitialAd);
        },
      ),
    );
  }

  /// Show an interstitial ad if conditions are met.
  /// Returns true if an ad was shown.
  Future<bool> showAdIfNeeded({
    required bool isPro,
    required AdPlacement placement,
  }) async {
    // Never show ads to Pro users
    if (isPro) return false;

    // Check frequency caps
    if (!_canShowAd()) return false;

    // Show the ad
    if (_isAdLoaded && _interstitialAd != null) {
      // Set callbacks before showing
      _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdDismissedFullScreenContent: (ad) {
          ad.dispose();
          _interstitialAd = null;
          _isAdLoaded = false;
          _loadInterstitialAd(); // Pre-load next
        },
        onAdFailedToShowFullScreenContent: (ad, error) {
          ad.dispose();
          _interstitialAd = null;
          _isAdLoaded = false;
          _loadInterstitialAd();
        },
      );

      await _interstitialAd!.show();
      _lastAdShown = DateTime.now();
      _adsShownInSession++;
      return true;
    }

    return false;
  }

  bool _canShowAd() {
    // Check minimum interval
    if (_lastAdShown != null) {
      final elapsed = DateTime.now().difference(_lastAdShown!);
      if (elapsed < _minIntervalBetweenAds) return false;
    }

    // Check session limit
    if (_adsShownInSession >= _maxAdsPerSession) return false;

    return true;
  }

  String _getAdUnitId() {
    if (kDebugMode) {
      // Google test interstitial ID
      return 'ca-app-pub-3940256099942544/1033173712';
    }
    return 'ca-app-pub-XXXXXXXXXXXXXXXX/YYYYYYYYYY'; // Production
  }

  void dispose() {
    _interstitialAd?.dispose();
  }
}
```

### 6C.4 -- Ad Placement Logic

**Effort:** 4-8 hours

#### 6C.4.1 -- Placement Rules

| Trigger | Show Ad? | Notes |
|---------|----------|-------|
| First video play (after onboarding) | YES | One-time per install |
| Channel/content change | YES | Subject to frequency cap |
| App resume from background | NO | Too intrusive |
| Browsing / scrolling | NO | No banner ads |
| Pro user | NEVER | All ads suppressed |

#### 6C.4.2 -- Integration Points

**File to modify:** `/app/lib/features/player/` (player screen)

In the player screen, call `AdService.showAdIfNeeded()` at these points:

1. **First play after onboarding:**
   - Track `hasPlayedFirstVideo` in SharedPreferences
   - Show interstitial before the first video starts playing
   - After the ad, set `hasPlayedFirstVideo = true`

2. **Content change (channel/episode switch):**
   - Call `showAdIfNeeded()` when user selects a new channel or episode
   - The frequency cap in AdService handles throttling

**Files to modify:**
- `/app/lib/features/player/` -- add ad trigger calls
- `/app/lib/features/home/` -- potentially for content selection triggers
- `/app/lib/features/browse/` -- channel browsing triggers

### 6C.5 -- "Remove Ads" Upgrade Prompt

**Effort:** 2-4 hours

When an ad is about to show (or instead of showing), optionally show an upgrade prompt:

**File to create:** `/app/lib/core/ads/upgrade_prompt.dart`

Design:
- Show a dialog: "Upgrade to Pro to remove ads forever"
- Include price ($8.99) and benefits list
- "Upgrade Now" button -> navigates to `ActivateProScreen`
- "Maybe Later" button -> dismisses, shows the ad
- Show this prompt at most once per day (SharedPreferences tracking)

**File to modify:** `/app/lib/features/settings/activate_pro_screen.dart`
- Ensure it's accessible from the upgrade prompt

### 6C.6 -- GDPR Consent Management

**Effort:** 4-8 hours

Required for EU users. Use Google's User Messaging Platform (UMP) SDK.

#### 6C.6.1 -- Add UMP Dependency

In `android/app/build.gradle.kts`:

```kotlin
implementation("com.google.android.ump:user-messaging-platform:3.0.0")
```

#### 6C.6.2 -- Consent Flow

**File to create:** `/app/lib/core/ads/consent_service.dart`

```dart
// Pseudocode
class ConsentService {
  Future<void> requestConsent() async {
    final params = ConsentRequestParameters(
      consentDebugSettings: ConsentDebugSettings(
        debugGeography: kDebugMode
            ? DebugGeography.debugGeographyEea
            : DebugGeography.debugGeographyDisabled,
        testDeviceIds: ['YOUR_TEST_DEVICE_HASHED_ID'],
      ),
    );

    await UserMessagingPlatform.instance.requestConsentInfoUpdate(params);

    final status = await UserMessagingPlatform.instance.getConsentStatus();
    if (status == ConsentStatus.required) {
      await UserMessagingPlatform.instance.loadAndShowConsentFormIfRequired();
    }
  }
}
```

**Call before `AdService.initialize()`** -- ads must not load until consent is resolved.

#### 6C.6.3 -- Consent State Management

- Store consent status in SharedPreferences
- If user denies consent: show only non-personalized ads (or no ads)
- Re-check consent periodically (UMP handles this)

### 6C.7 -- Test Ad Units for Development

**Effort:** 30 minutes

Always use test IDs during development. Google test IDs:

| Ad Type | Test Ad Unit ID |
|---------|----------------|
| Interstitial | `ca-app-pub-3940256099942544/1033173712` |
| Banner (if needed later) | `ca-app-pub-3940256099942544/6300978111` |
| Rewarded (if needed later) | `ca-app-pub-3940256099942544/5224354917` |

**Register test devices** in AdMob console to avoid policy violations.

### 6C.8 -- Ad Frequency Capping Summary

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Min interval between ads | 3 minutes | Prevents ad fatigue |
| Max ads per session | 10 | Reasonable for a media app |
| Max ads per hour | 5 | Industry standard |
| First play ad | Once per install | Introduces ads gently |
| Upgrade prompt | Once per day | Not annoying |

---

## 6D: Remaining P4 Items

### 6D.1 -- Admin Panel Finalization

**Effort:** 1-2 days

The admin panel exists at `/admin` (Next.js on Wasmer Edge). Finalize:

1. **User management dashboard:**
   - View all users with tier status
   - Manually upgrade/downgrade users
   - View purchase history

2. **Content management:**
   - Featured content curation
   - Category management

3. **Analytics dashboard:**
   - Active users (daily/weekly/monthly)
   - Pro conversion rate
   - Ad revenue (from AdMob reports)
   - Playlist import statistics

4. **Deployment:**
   - Verify Wasmer Edge deployment is stable
   - Set up custom domain (if not done)
   - Configure environment variables

**Files to modify:**
- `/admin/app/` -- various pages
- `/edge/` -- Wasmer configuration

### 6D.2 -- Google Play Webhook for Receipt Validation

**Effort:** 1 day

Set up Real-Time Developer Notifications (RTDN):

1. **Create a Google Cloud Pub/Sub topic:**
   ```bash
   gcloud pubsub topics create google-play-developer-notifications
   ```

2. **Configure in Play Console:**
   - Play Console > Monetize > Monetization setup
   - Enable "Real-time developer notifications"
   - Link the Pub/Sub topic

3. **Create a webhook endpoint** (Supabase Edge Function or admin panel API route):
   - Receives purchase/subscription status changes
   - Validates the notification signature
   - Updates user tier in Supabase

**Files to create:**
- `supabase/functions/play-webhook/index.ts`
- Or: `admin/app/api/webhooks/google-play/route.ts`

### 6D.3 -- Feature Flags for Ad Control

**Effort:** 4-8 hours

Add feature flags to control ad behavior remotely without an app update:

#### Option A: Supabase-Based (Simple)

Create a `feature_flags` table in Supabase:

```sql
CREATE TABLE feature_flags (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Seed values
INSERT INTO feature_flags (key, value) VALUES
  ('ads_enabled', '{"enabled": true}'),
  ('ad_frequency_cap', '{"max_per_session": 10, "min_interval_seconds": 180}'),
  ('show_upgrade_prompt', '{"enabled": true, "max_per_day": 1}');
```

**File to create:** `/app/lib/core/config/feature_flag_service.dart`

```dart
class FeatureFlagService {
  // Fetch flags from Supabase on app start
  // Cache locally with TTL (e.g., 1 hour)
  // Provide typed accessors:
  bool get adsEnabled => ...;
  int get maxAdsPerSession => ...;
  Duration get minAdInterval => ...;
}
```

#### Option B: Firebase Remote Config (More Robust)

If Firebase is already in the stack, use Remote Config for:
- Instant flag updates
- A/B testing support
- Gradual rollout

**Not recommended** if Firebase is not already a dependency (adds complexity).

### 6D.4 -- Sentry Integration Verification

**Effort:** 1-2 hours

Verify Sentry is properly configured for production:

1. Confirm DSN is set in release builds
2. Test error reporting with a deliberate crash
3. Set up release tracking (tie to app version)
4. Configure alert rules (email/Slack for new issues)
5. Verify source maps are uploaded for symbolicated stack traces

**File to verify:** `/app/lib/main.dart` (Sentry initialization)

---

## Dependencies Between Tasks

```
6A.1 (Account) ──────────────────────────────────┐
6A.2 (Listing) ──────────────────────────────────┤
6A.3 (Signing) ──> 6B.2 (Verify purchases) ──> 6B.3 (Receipt validation)
     │                                              │
     └──> 6A.4 (Upload) ──> 6A.5 (Testing)        │
                           │                        │
                           └──> 6B.4 (License testers)
                                    │
                                    └──> 6C.1 (AdMob setup)
                                         │
                                         └──> 6C.2-6C.7 (Ad implementation)
                                                  │
                                                  └──> 6D.3 (Feature flags)

6D.1 (Admin) ─── can run in parallel with 6C
6D.2 (Webhook) ── depends on 6B.2
6D.4 (Sentry) ── can run in parallel
```

**Critical path:** 6A.1 -> 6A.3 -> 6A.4 -> 6A.5 -> 6B.4 -> 6C.1 -> 6C.2-6C.7

---

## Files to Create

| File | Purpose |
|------|---------|
| `android/key.properties` | Keystore credentials (gitignored) |
| `lib/core/ads/ad_service.dart` | AdMob lifecycle management |
| `lib/core/ads/consent_service.dart` | GDPR consent flow |
| `lib/core/ads/upgrade_prompt.dart` | "Remove Ads" dialog |
| `lib/core/config/feature_flag_service.dart` | Remote feature flags |
| `supabase/functions/validate-purchase/index.ts` | Server-side receipt validation |
| `supabase/functions/play-webhook/index.ts` | RTDN webhook handler |
| `admin/app/privacy/page.tsx` | Privacy policy page |

## Files to Modify

| File | Changes |
|------|---------|
| `pubspec.yaml` | Add `google_mobile_ads` dependency |
| `android/app/build.gradle.kts` | Signing config, ads SDK dependency |
| `android/app/src/main/AndroidManifest.xml` | AdMob app ID meta-data |
| `.gitignore` | Add `key.properties` |
| `lib/main.dart` | Initialize AdService, ConsentService |
| `lib/features/player/` | Add ad trigger calls on content change |
| `lib/features/settings/activate_pro_screen.dart` | Link from upgrade prompt |
| `lib/core/purchase/purchase_service.dart` | Verify production readiness |
| `lib/core/entitlement/entitlement_service.dart` | Verify Pro check in ad flow |

---

## Testing Checklist

### 6A -- Publishing
- [ ] AAB builds successfully with release signing
- [ ] App installs and runs from the signed AAB
- [ ] Store listing text is accurate and typo-free
- [ ] Screenshots show current UI
- [ ] Privacy policy URL is accessible
- [ ] Content rating is appropriate
- [ ] Data safety declaration is accurate

### 6B -- Payments
- [ ] `pro_lifetime` product appears in Play Console
- [ ] Purchase flow completes successfully with test account
- [ ] Pro tier is granted after purchase
- [ ] Pro tier persists across app restarts
- [ ] Restore purchases works after reinstall
- [ ] Already-owned purchase is handled gracefully
- [ ] Network failure during purchase shows appropriate error
- [ ] License testers are not charged

### 6C -- Ads
- [ ] AdMob SDK initializes without errors
- [ ] Test interstitial ad loads and displays
- [ ] First video play shows an interstitial (one-time)
- [ ] Content change shows interstitial (subject to frequency cap)
- [ ] Pro users see NO ads
- [ ] Frequency cap prevents ad spam (3-min interval)
- [ ] Session limit prevents excessive ads (max 10)
- [ ] "Remove Ads" prompt shows once per day
- [ ] Upgrade prompt navigates to Pro purchase screen
- [ ] GDPR consent form appears for EU users
- [ ] Consent denial results in no personalized ads
- [ ] Ad dismissal allows content to continue
- [ ] No ads shown during active playback
- [ ] No ads shown on app resume from background

### 6D -- Remaining P4
- [ ] Admin panel shows user list with tiers
- [ ] Admin can manually upgrade/downgrade users
- [ ] Webhook receives and processes purchase notifications
- [ ] Feature flags can disable ads remotely
- [ ] Sentry captures errors in release builds

---

## Rollback Plan

### If ads cause user complaints:
1. Use feature flag `ads_enabled = false` to disable ads remotely
2. No app update required (flag fetched on app start)
3. Investigate and adjust frequency caps
4. Re-enable gradually

### If payment flow breaks:
1. Revert `PurchaseService` to last known working version
2. Users who already purchased retain Pro (stored in Supabase)
3. New purchases temporarily unavailable (communicate via in-app message)
4. Fix and re-deploy

### If app is rejected by Google Play:
1. Review rejection reason carefully
2. Common issues:
   - Metadata policy violations (screenshots, description)
   - Content policy violations (IPTV content concerns)
   - Privacy policy issues
   - Ads policy violations
3. Fix the specific issue and resubmit
4. Appeal if the rejection is incorrect

### If keystore is lost:
1. **This is unrecoverable.** You cannot update the app.
2. Prevention: store keystore in a password manager or secure vault
3. Worst case: publish as a new app with a different package name
4. Google offers "Play App Signing" which stores the signing key on Google's servers -- use this for the upload key

---

## Timeline Summary

| Week | Tasks |
|------|-------|
| **Week 1** | 6A.1-6A.3 (Account, listing, signing), 6B.1 (Product setup), 6C.1 (AdMob account) |
| **Week 2** | 6A.4-6A.5 (Upload, testing tracks), 6B.2-6B.4 (Payment verification), 6C.2-6C.3 (Ad service) |
| **Week 3** | 6C.4-6C.7 (Ad placement, consent, testing), 6D.1-6D.3 (Admin, webhooks, flags) |
| **Week 4** | Final testing, production release, monitoring |

**Note:** Google Play review for first-time apps can take 7-14 days. Submit early and work on 6C/6D while waiting.

---

## Key Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Google Play rejects IPTV app | Medium | High | Ensure compliance with content policies; IPTV players are allowed but piracy facilitation is not |
| AdMob account suspended | Low | High | Follow all AdMob policies strictly; use test IDs in development |
| Keystore lost | Low | Critical | Use Play App Signing; backup keystore in multiple secure locations |
| Payment flow fails in production | Low | High | Thorough testing with license testers; server-side validation |
| GDPR consent blocks EU users | Medium | Medium | Implement UMP SDK properly; offer non-personalized ads as fallback |
| Ad fatigue causes uninstalls | Medium | Medium | Conservative frequency caps; feature flags for quick adjustment |

---

## Next Steps After Phase 6

- **Phase 7 (Future):** Android TV optimization, Fire TV certification
- **Phase 8 (Future):** iOS version, Apple App Store publishing
- **Phase 9 (Future):** Subscription model, family sharing, cloud sync
