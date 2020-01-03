import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';

import '../daemon_client.dart';

class FrontendAssetServer {
  final HttpServer _server;

  FrontendAssetServer._(this._server);

  static Future<FrontendAssetServer> start(String workingDirectory) async {
    var _serverPortFile = File(assetServerPortFilePath(workingDirectory));
    var _assetServerPort = 8888;
    await _serverPortFile.create(recursive: true);
    await _serverPortFile.writeAsString(_assetServerPort.toString());

    var server = await serve(_handleRequest, 'localhost', _assetServerPort);

    return FrontendAssetServer._(server);
  }

  Future<void> close() async {
    await _server.close();
  }
}

FutureOr<Response> _handleRequest(Request request) {
  print(request);
  return Response.notFound('Unimplemented');
}
