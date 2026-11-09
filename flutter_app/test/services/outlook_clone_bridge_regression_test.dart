import 'package:fa/services/agent_service.dart';
import 'package:fa_office_agent/fa_office_agent.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AgentConfig config() => AgentConfig(
    providerKind: 'openai-completions',
    modelId: 'fixture-model',
    baseUrl: 'https://example.invalid/test/v1',
    apiKey: 'synthetic-test-key-not-a-real-credential',
  );
  void expectMailTools(AgentService service) {
    final names = service.toolsForTest.map((tool) => tool.name).toList();
    expect(names, containsAll([
      outlookReadCurrentItem,
      outlookReadAttachment,
      outlookInsertDraftBody,
    ]));
    expect(service.approval.overrideFor(outlookReadAttachment), ApprovalPolicy.prompt);
    expect(service.approval.overrideFor(outlookInsertDraftBody), ApprovalPolicy.prompt);
  }
  test('Office tools and write approval guards survive two new-chat clones', () async {
    final parent = await AgentService.create(
      config: config(),
      env: MemoryExecutionEnv(),
      officeApi: FakeOfficeContext(),
      watchExternalSessions: false,
    );
    addTearDown(parent.dispose);
    expectMailTools(parent);
    final first = parent.clone();
    addTearDown(first.dispose);
    expectMailTools(first);
    final second = first.clone();
    addTearDown(second.dispose);
    expectMailTools(second);
  });
  test('Non-Office VM services do not acquire mail tools by cloning', () async {
    final parent = await AgentService.create(
      config: config(),
      env: MemoryExecutionEnv(),
      watchExternalSessions: false,
    );
    addTearDown(parent.dispose);
    final child = parent.clone();
    addTearDown(child.dispose);
    expect(child.toolsForTest.any((tool) => tool.name == outlookReadCurrentItem), isFalse);
  });
}
