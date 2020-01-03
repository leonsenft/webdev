import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:shelf_static/shelf_static.dart';

import '../daemon_client.dart';
import 'ddc_names.dart';

final _sdkDir = p.dirname(p.dirname(Platform.resolvedExecutable));

class FrontendAssetServer {
  final HttpServer _server;

  FrontendAssetServer._(this._server);

  static Future<FrontendAssetServer> start(String workingDirectory) async {
    var _serverPortFile = File(assetServerPortFilePath(workingDirectory));
    var _assetServerPort = 8888;
    await _serverPortFile.create(recursive: true);
    await _serverPortFile.writeAsString(_assetServerPort.toString());

    var cascade = Cascade()
        .add(_sdkSourcesHandler())
        .add(createStaticHandler(p.current, defaultDocument: 'index.html'))
        .add(_handleJsModuleRequest)
        .add(_handleJsAppRequest);

    var server = await serve(cascade.handler, 'localhost', _assetServerPort);

    return FrontendAssetServer._(server);
  }

  Future<void> close() async {
    await _server.close();
  }
}

Future<Response> _handleJsModuleRequest(Request request) async {
  if (!request.requestedUri.path.endsWith('.dart.js')) {
    return Response.notFound('Not Found');
  }
  var absolutePath = p.absolute(request.requestedUri.path.substring(1));
  var jsonFile = File('${p.withoutExtension(absolutePath)}.dill.json');
  var info = jsonDecode(await jsonFile.readAsString())[absolutePath];
  if (info == null) {
    return Response.notFound('Not Found');
  }

  var sourcesFile = File('${p.withoutExtension(absolutePath)}.dill.sources');
  var sourcesBytes = await sourcesFile.readAsBytes();
  var sourceBytes = sourcesBytes
      .getRange(info['code'][0] as int, info['code'][1] as int)
      .toList();
  return Response.ok(utf8.decode(sourceBytes), headers: {
    HttpHeaders.contentTypeHeader: 'application/javascript',
  });
}

Future<Response> _handleJsAppRequest(Request request) async {
  if (!request.requestedUri.path.endsWith('.js')) {
    return Response.notFound('Not Found');
  }
  return Response.ok(_appBootstrap(request), headers: {
    HttpHeaders.contentTypeHeader: 'application/javascript',
  });
}

Handler _sdkSourcesHandler() {
  var sdkServer = createStaticHandler(_sdkDir);
  return (request) {
    if (request.requestedUri.pathSegments[1] != r'$sdk') {
      return Response.notFound('Not Found');
    }
    return sdkServer(Request(
        request.method,
        request.requestedUri
            .replace(pathSegments: request.requestedUri.pathSegments.skip(2))));
  };
}

String _appBootstrap(Request request) {
  var relativePath = request.requestedUri.path.substring(1);
  var basename = p.url.basename(request.requestedUri.path);
  var appModuleName = '${p.withoutExtension(basename)}.dart';
  var moduleScope =
      pathToJSIdentifier(p.absolute(p.url.withoutExtension(relativePath)));
  return '''
require.config({
    waitSeconds: 0,
    paths: {"dart_sdk": "\$sdk/lib/dev_compiler/kernel/amd/dart_sdk"}
});

require(["$appModuleName", "dart_sdk"], function(app, dart_sdk) {
  dart_sdk.dart.setStartAsyncSynchronously(true);
  dart_sdk._isolate_helper.startRootIsolate(() => {}, []);
  /* MAIN_EXTENSION_MARKER */
  app.$moduleScope.main();
})();
''';
}
