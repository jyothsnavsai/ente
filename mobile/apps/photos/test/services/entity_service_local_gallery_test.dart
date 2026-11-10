import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";
import "package:photos/app_mode.dart";
import "package:photos/gateways/entity/entity_gateway.dart";
import "package:photos/gateways/entity/models/type.dart";
import "package:photos/services/entity_service.dart";
import "package:photos/settings/local_settings.dart";
import "package:shared_preferences/shared_preferences.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test("local gallery entity sync never requests the gateway", () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await LocalSettings(preferences).setAppMode(AppMode.localGallery);
    final service = EntityService(preferences, EntityGateway(Dio()));

    expect(await service.syncEntity(EntityType.cgroup), 0);
    await service.syncEntities();
    await expectLater(
      service.getOrCreateEntityKey(EntityType.cgroup),
      throwsA(isA<StateError>()),
    );
  });
}
