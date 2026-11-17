import 'package:flutter_test/flutter_test.dart';
import 'package:link_scanner/security_policy.dart';

void main() {
  const hosts = {'example.com', 'www.example.com'};

  test('allows HTTPS on an explicitly allowed host', () {
    expect(
      isAllowedWebUri(Uri.parse('https://example.com/path'), hosts),
      isTrue,
    );
  });

  test('allows explicit standard HTTPS port', () {
    expect(
      isAllowedWebUri(Uri.parse('https://example.com:443/'), hosts),
      isTrue,
    );
  });

  test('rejects plain HTTP', () {
    expect(
      isAllowedWebUri(Uri.parse('http://example.com/'), hosts),
      isFalse,
    );
  });

  test('rejects unlisted hostnames and suffix tricks', () {
    expect(
      isAllowedWebUri(Uri.parse('https://evil-example.com/'), hosts),
      isFalse,
    );
    expect(
      isAllowedWebUri(Uri.parse('https://example.com.evil.test/'), hosts),
      isFalse,
    );
    expect(
      isAllowedWebUri(Uri.parse('https://sub.example.com/'), hosts),
      isFalse,
    );
  });

  test('rejects user-info URL tricks', () {
    expect(
      isAllowedWebUri(
        Uri.parse('https://example.com@evil.test/'),
        hosts,
      ),
      isFalse,
    );
  });

  test('rejects non-standard ports', () {
    expect(
      isAllowedWebUri(Uri.parse('https://example.com:8443/'), hosts),
      isFalse,
    );
  });

  test('rejects non-HTTPS schemes', () {
    expect(
      isAllowedWebUri(Uri.parse('javascript:alert(1)'), hosts),
      isFalse,
    );
  });
}
