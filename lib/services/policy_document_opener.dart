import 'package:flutter/widgets.dart';

import 'policy_document_opener_io.dart'
    if (dart.library.html) 'policy_document_opener_web.dart' as implementation;

Future<bool> openPolicyDocument(BuildContext context, {required String assetPath}) {
  return implementation.openPolicyDocument(context, assetPath: assetPath);
}
