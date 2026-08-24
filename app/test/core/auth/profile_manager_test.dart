import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iflixify/core/auth/profile_manager.dart';
import 'package:iflixify/core/data/database.dart';

void main() {
  late AppDatabase db;
  late ProfileManager manager;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    manager = ProfileManager.forTesting(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('ProfileManager', () {
    test('getProfiles returns empty list initially', () async {
      final profiles = await manager.getProfiles();
      expect(profiles, isEmpty);
    });

    test('getActiveProfile returns null initially', () async {
      final active = await manager.getActiveProfile();
      expect(active, isNull);
    });

    test('createProfile creates a profile with correct fields', () async {
      final profile = await manager.createProfile('Test User');

      expect(profile.id, isPositive);
      expect(profile.displayName, 'Test User');
      expect(profile.avatarColor, isPositive);
      expect(profile.isActive, isTrue); // First profile is active
      expect(profile.createdAt, isNotNull);
    });

    test('createProfile sets first profile as active', () async {
      final profile = await manager.createProfile('First');
      expect(profile.isActive, isTrue);
    });

    test('createProfile sets subsequent profiles as inactive', () async {
      await manager.createProfile('First');
      final second = await manager.createProfile('Second');
      expect(second.isActive, isFalse);
    });

    test('createProfile assigns different avatar colors', () async {
      final first = await manager.createProfile('First');
      final second = await manager.createProfile('Second');
      // Colors should be different (cycling through default colors)
      expect(first.avatarColor, isNot(equals(second.avatarColor)));
    });

    test('getProfiles returns all profiles sorted by creation date', () async {
      await manager.createProfile('First');
      await manager.createProfile('Second');
      await manager.createProfile('Third');

      final profiles = await manager.getProfiles();
      expect(profiles.length, 3);
      expect(profiles[0].displayName, 'First');
      expect(profiles[1].displayName, 'Second');
      expect(profiles[2].displayName, 'Third');
    });

    test('switchProfile changes active profile', () async {
      final first = await manager.createProfile('First');
      final second = await manager.createProfile('Second');

      // First is active by default.
      expect((await manager.getActiveProfile())?.id, first.id);

      // Switch to second.
      await manager.switchProfile(second.id);
      expect((await manager.getActiveProfile())?.id, second.id);

      // First should now be inactive.
      final profiles = await manager.getProfiles();
      final firstReloaded = profiles.firstWhere((p) => p.id == first.id);
      expect(firstReloaded.isActive, isFalse);
    });


    test('deleteProfile removes a non-active profile', () async {
      await manager.createProfile('First');
      final second = await manager.createProfile('Second');

      await manager.deleteProfile(second.id);

      final profiles = await manager.getProfiles();
      expect(profiles.length, 1);
      expect(profiles.first.displayName, 'First');
    });

    test('deleteProfile throws when trying to delete active profile', () async {
      final first = await manager.createProfile('First');
      await manager.createProfile('Second');

      expect(
        () => manager.deleteProfile(first.id),
        throwsA(isA<StateError>()),
      );
    });


    test('updateProfile changes display name', () async {
      final profile = await manager.createProfile('Old Name');
      await manager.updateProfile(profile.id, displayName: 'New Name');

      final profiles = await manager.getProfiles();
      final updated = profiles.firstWhere((p) => p.id == profile.id);
      expect(updated.displayName, 'New Name');
    });



    test('ensureDefaultProfile creates Profile 1 when none exist', () async {
      await manager.ensureDefaultProfile();

      final profiles = await manager.getProfiles();
      expect(profiles.length, 1);
      expect(profiles.first.displayName, 'Profile 1');
      expect(profiles.first.isActive, isTrue);
    });

    test('ensureDefaultProfile does not create if profiles exist', () async {
      await manager.createProfile('Existing');
      await manager.ensureDefaultProfile();

      final profiles = await manager.getProfiles();
      expect(profiles.length, 1);
      expect(profiles.first.displayName, 'Existing');
    });
  });
}
