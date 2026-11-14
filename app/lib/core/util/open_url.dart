// Adresi telefonun varsayılan tarayıcısında açar.
import 'package:url_launcher/url_launcher.dart';

Future<bool> openExternal(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('https') || uri.isScheme('http'))) return false;
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
