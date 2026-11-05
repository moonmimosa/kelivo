import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/core/models/assistant.dart';

void main() {
  test('Nianlun assistant settings survive JSON and backup serialization', () {
    const assistant = Assistant(
      id: 'assistant-1',
      name: 'Default assistant',
      nianlunEnabled: true,
      nianlunBaseUrl: 'https://example.test/nianlun-test',
      nianlunToken: 'test-token',
      nianlunWindowId: 'window-1',
    );

    final restored = Assistant.fromJson(assistant.toJson());

    expect(restored.nianlunEnabled, isTrue);
    expect(restored.nianlunBaseUrl, assistant.nianlunBaseUrl);
    expect(restored.nianlunToken, assistant.nianlunToken);
    expect(restored.nianlunWindowId, assistant.nianlunWindowId);
  });

  test('older assistant records default to Nianlun disabled', () {
    final assistant = Assistant.fromJson({'id': 'legacy', 'name': 'Legacy'});

    expect(assistant.nianlunEnabled, isFalse);
    expect(assistant.nianlunBaseUrl, isEmpty);
    expect(assistant.nianlunToken, isEmpty);
    expect(assistant.nianlunWindowId, isEmpty);
  });
}
