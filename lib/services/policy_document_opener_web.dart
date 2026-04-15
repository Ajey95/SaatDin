import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

Future<bool> openPolicyDocument(BuildContext context, {required String assetPath}) async {
  final uri = Uri.parse(assetPath);
  return launchUrl(uri, webOnlyWindowName: '_blank');
}
