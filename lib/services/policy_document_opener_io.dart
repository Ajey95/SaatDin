import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

Future<bool> openPolicyDocument(BuildContext context, {required String assetPath}) async {
  try {
    final data = await rootBundle.load(assetPath);
    final tempDir = await getTemporaryDirectory();
    final fileName = assetPath.split('/').last;
    final targetFile = File('${tempDir.path}/$fileName');
    await targetFile.writeAsBytes(data.buffer.asUint8List(), flush: true);

    final result = await OpenFilex.open(targetFile.path, type: 'application/pdf');
    return result.type == ResultType.done;
  } catch (_) {
    return false;
  }
}
