/// Strict navigation policy for the embedded WebView.
///
/// Only HTTPS URLs on explicitly listed hostnames are permitted.
/// Hostnames are exact matches: add every trusted subdomain separately.
bool isAllowedWebUri(Uri uri, Set<String> allowedHosts) {
  if (uri.scheme.toLowerCase() != 'https') return false;
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return false;
  if (uri.hasPort && uri.port != 443) return false;

  final host = uri.host.toLowerCase();
  final normalizedHosts = allowedHosts.map((value) => value.toLowerCase());
  return normalizedHosts.contains(host);
}
