import 'package:flutter_test/flutter_test.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/boot/boot_config_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'provider key and default model survive fresh registry creation',
    () async {
      expect(faComfortEnabled, isTrue);
      const endpoint = 'https://example.invalid/comfort-test/v1';
      // Synthetic fixture; never an actual credential.
      const fixture = 'test-only-not-a-real-key';
      final env = MemoryExecutionEnv();
      final first = await ProviderRegistry.load(env);
      final provider = await first.add(
        name: 'Comfort test',
        baseUrl: endpoint,
        modelId: 'model-test',
      );
      first.rememberKey(provider.id, fixture);
      final sandbox =
          (await env.readTextFile('/providers.json')).valueOrNull ?? '';
      expect(sandbox.contains(fixture), isFalse);
      final connection = await LastConnectionStore.load(env);
      await connection.save(
        const LastConnection(
          providerKind: 'openai-completions',
          modelId: 'model-test',
          baseUrl: endpoint,
        ),
      );
      final otherEnv = MemoryExecutionEnv();
      final second = await ProviderRegistry.load(otherEnv);
      final saved = await LastConnectionStore.load(otherEnv);
      expect(second.keyFor(provider.id), fixture);
      expect(saved.connection?.modelId, 'model-test');
      final boot = restorableBootConfig(
        connection: saved.connection,
        registry: second,
        sessionKeysStore: null,
      );
      expect(boot?.modelId, 'model-test');
      expect(boot?.apiKey, fixture);
      second.rememberKey(provider.id, '');
      final cleared = await ProviderRegistry.load(MemoryExecutionEnv());
      expect(cleared.keyFor(provider.id), isNull);
      await cleared.remove(provider.id);
      faComfortWrite('connection', null);
      final removed = await ProviderRegistry.load(MemoryExecutionEnv());
      expect(removed.providers.where((p) => p.id == provider.id), isEmpty);
    },
    skip: !faComfortEnabled,
  );
}
