// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Backend wiring of [AgentService].
extension AgentServiceWiring on AgentService {
  /// Selects the backend stream function.
  ///
  /// HTTP credentials are resolved when each request starts, so updating
  /// the provider key does not require recreating this stream function.
  StreamFunction _streamFunctionFor(AgentConfig config) {
    if (config.providerKind == webLlmProviderKind) {
      return webLlmStreamFunction(createWebLlmService());
    }

    if (config.providerKind == transformersJsProviderKind) {
      return transformersJsStreamFunction(createTransformersJsService());
    }

    return decorateAuthErrors(
      (model, context, {cancelToken}) {
        final registry = _providerRegistry;
        final provider = registry?.byBaseUrl(config.baseUrl);

        final currentKey = provider == null
            ? config.apiKey
            : (registry?.keyFor(provider.id) ?? config.apiKey);

        // CodeMie carries cookie authentication in model.headers.
        // Do not add bearer authentication for that provider.
        final usesCookieAuth = isCodeMieProvider(config.baseUrl);

        if (!usesCookieAuth &&
            provider != null &&
            provider.requiresKey &&
            currentKey.trim().isEmpty) {
          throw StateError(
            'API key missing for the selected provider. '
            'Enter it in provider settings and save.',
          );
        }

        return providerStreamFunction(
          config.providerKind,
          usesCookieAuth ? '' : currentKey,
          sessionId: () => _session?.cachedId,
        )(model, context, cancelToken: cancelToken);
      },
      () => _connectionDisplayName(
        _providerRegistry,
        config.baseUrl,
      ),
    );
  }

  /// Attaches secret-redaction hooks and the layered redaction pipeline.
  void _attachRedactor(
    SecretRedactor? redactor, [
    Map<String, String> bootSecrets = const {},
  ]) {
    if (bootSecrets.isNotEmpty) {
      _bootSecrets = bootSecrets;
    }

    if (redactor == null) return;

    attachSecretRedactor(_agent, redactor);

    if (_yamlRedactConfig is RedactionConfig &&
        !_yamlRedactConfig!.enabled) {
      return;
    }

    _redactionPipeline ??= RedactionPipeline(
      registeredSecrets: [
        for (final value in bootSecrets.values)
          if (value.length >= SecretRedactor.minValueLength) value,
      ],
      config: _yamlRedactConfig ?? const RedactionConfig(),
    );

    attachRedactionPipeline(_agent, _redactionPipeline!);
  }

  /// Registers a secret in both redaction systems.
  void _registerRedactionSecret(String name, String value) {
    _redactor?.register(name, value);
    _redactionPipeline?.registerSecret(value);
  }

  /// Attaches the approval gate.
  ///
  /// When no approval prompt handler is installed, deny by default.
  void _attachApproval() {
    approval.prompt = (request) {
      final handler = approvalPromptHandler;
      if (handler == null) return ApprovalDecision.deny;

      return handler(request);
    };

    attachApproval(_agent, approval);
  }

  /// Registered tool names in registration order.
  @visibleForTesting
  List<String> get registeredToolNamesForTest => [
    for (final tool in _agent.state.tools) tool.name,
  ];

  /// Registered tools exposed to tests.
  @visibleForTesting
  List<Tool> get toolsForTest => _agent.state.tools;

  /// Live system prompt exposed to tests.
  @visibleForTesting
  String get systemPromptForTest => _agent.state.systemPrompt;

  /// Live secrets environment exposed to tests.
  @visibleForTesting
  SecretsExecutionEnv? get secretsEnvForTest => _secretsEnv;

  /// Redactor exposed to tests.
  @visibleForTesting
  SecretRedactor? get redactorForTest => _redactor;

  /// Current consent for third-party skill discovery.
  SkillsAccess get skillsAccess => _skillsAccess;

  /// Composes the base prompt and additional context sections.
  String _composeSystemPrompt(AgentConfig config) {
    final base = _effectiveAgentSystemPrompt(config, _redactor);

    final parts = [
      base,
      ?_projectMountNote(),
      if (_promptSuffix.isNotEmpty) _promptSuffix,
      if (_memorySection.isNotEmpty) _memorySection,
      if (_messagingSection().isNotEmpty) _messagingSection(),
    ];

    return parts.join('\n\n');
  }

  /// Agent messaging prompt section.
  String _messagingSection() {
    final manager = _subagentManager;

    if (manager == null ||
        manager.messaging == null ||
        manager.mailboxPrefix.isEmpty) {
      return '';
    }

    return appMessagingSectionPrompt.replaceAll(
      '{{mailbox}}',
      manager.mailboxOf(manager.selfId),
    );
  }

  /// Refreshes the memory section when its content changes.
  Future<void> _refreshMemorySection() async {
    final controller = _memoryController;
    final config = _config;

    if (controller == null || config == null) return;

    final section = await controller.formatPromptSection();
    if (section == _memorySection) return;

    _memorySection = section;
    _agent.state.systemPrompt = _composeSystemPrompt(config);
  }

  /// Describes the mounted project folder, when present.
  String? _projectMountNote() {
    var env = this.env;

    if (env is SecretsExecutionEnv) {
      env = env.delegate;
    }

    if (env is! ProjectMountEnv) return null;

    final root = env.mountedRoot;
    if (root == null) return null;

    return 'A project folder is mounted at $projectMountSegment '
        '(host: $root). File tools take $projectMountSegment/... paths; '
        'shell commands work on the host path directly (cd $root).';
  }

  /// Recomposes the prompt after the project-folder mount changes.
  void refreshProjectMountPrompt() {
    final config = _config;

    if (config != null) {
      _agent.state.systemPrompt = _composeSystemPrompt(config);
    }
  }

  /// Resolves the memory LLM slot at call time.
  HarnessLlmSlot? _resolveMemoryLlmSlot() {
    final role = _taskRolesResolver?.resolveRole(smolModelRole);
    if (role != null) return role;

    return (
      model: _agent.state.model,
      stream: _agent.streamFunction,
    );
  }

  /// Routes ask-tool questions to the installed handler.
  Future<List<AskAnswer>?> _answerAskQuestions(
    List<AskQuestion> questions,
  ) async {
    final handler = askHandler;
    if (handler == null) return null;

    return handler(questions);
  }

  /// Routes secret requests to the host prompt handler.
  Future<RequestSecretResult?> _handleSecretRequest(
    String name,
    String reason,
  ) async {
    final handler = secretRequestHandler;
    if (handler == null) return null;

    final result = await handler(name, reason);
    if (result == null) return null;

    return acceptSecretGrant(result);
  }

  /// Snapshot of host secrets available to the running environment.
  Map<String, String> hostSecrets() =>
      _secretsEnv?.secretsSnapshot() ?? const {};

  /// Reconciles saved key changes with the running secrets environment.
  void _reconcileSessionKeySecrets() {
    final env = _secretsEnv;
    final store = _sessionKeys;

    if (env == null || store == null) return;

    final savedNames = store.names.toSet();

    for (final name in _storeSecretNames.difference(savedNames).toList()) {
      env.revokeSecret(name);
      _storeSecretNames.remove(name);
    }

    for (final name in savedNames) {
      final value = store.valueOf(name);
      if (value == null || value.isEmpty) continue;

      if (env.secretsSnapshot()[name] == value) continue;

      env.addSecrets({name: value});
      _registerRedactionSecret(name, value);
      _storeSecretNames.add(name);
    }
  }

  /// Persists and activates a credential granted through the host prompt.
  Future<RequestSecretResult> acceptSecretGrant(
    RequestSecretResult result,
  ) async {
    await _sessionKeys?.set(result.name, result.value);

    _secretsEnv?.addSecrets({result.name: result.value});
    _registerRedactionSecret(result.name, result.value);

    return RequestSecretResult(
      name: result.name,
      value: result.value,
      persisted: _sessionKeys != null,
    );
  }

  /// User-selected tool availability.
  ToolsConfig get toolsConfig => _toolsAvailability.config;

  /// Active backend model ID.
  String get agentModelId => _agent.state.model.id;

  /// Agent network controller.
  AgentNetworkController get agentNetwork =>
      _agentNetwork ?? (throw StateError('agentNetwork before initialize()'));
}
