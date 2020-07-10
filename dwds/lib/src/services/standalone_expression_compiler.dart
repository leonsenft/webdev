// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'expression_compiler.dart';

/// Runs a separate dartdevc process in expression compilation mode, feeding
/// it dependent dill files as needed.
class StandaloneExpressionCompiler implements ExpressionCompiler {
  // Communication channels
  final Stream<Map<String, dynamic>> _responseStream;
  final void Function(Map<String, dynamic>) _sendRequest;

  /// The currently in flight request, if there is one.
  _ServiceRequest _pendingRequest;
  final _requestQueue = Queue<_ServiceRequest>();

  // Optional shutdown callback
  final void Function() _onShutdown;

  StandaloneExpressionCompiler._(this._responseStream, this._sendRequest,
      {void Function() onShutdown})
      : _onShutdown = onShutdown {
    _responseStream.listen((event) {
      if (_pendingRequest == null) {
        throw StateError(
            'Got an unexpected message from dartdevc isolate:\n$event');
      }
      _pendingRequest.responseCompleter.complete(event);
      _pendingRequest = null;
      _maybeSendNextRequest();
    });
  }

  static Future<StandaloneExpressionCompiler> startIsolate(
      Stream<Iterable<InputDill>> dillUpdates) async {
    var receivePort = ReceivePort();
    var isolateSendPort = receivePort.sendPort;
    var isolate = await Isolate.spawnUri(
        Uri.file(
            '/home/jakemac/dart-lang-sdk/sdk/pkg/dev_compiler/bin/dartdevc.dart'),
        // Uri.file(
        //     p.join(_sdkDir, 'bin', 'snapshots', 'dart2js.dart.snapshot')),
        [
          '--experimental-expression-compiler',
          '--libraries-file=${p.join(_sdkDir, 'lib', 'libraries.json')}',
          '--packages-file=${p.join('.dart_tool', 'package_config.json')}',
          '--dart-sdk-summary=${p.join(_sdkDir, 'lib', '_internal', 'ddc_sdk.dill')}',
        ],
        isolateSendPort,
        packageConfig: Uri.file(
            '/home/jakemac/dart-lang-sdk/sdk/.dart_tool/package_config.json'));

    // The first message from the isolate is the SendPort, and the rest are
    // JSON maps.
    var sendPortCompleter = Completer<SendPort>();
    var responseStreamController = StreamController<Map<String, dynamic>>();
    receivePort.listen((message) {
      if (!sendPortCompleter.isCompleted) {
        sendPortCompleter.complete(message as SendPort);
      } else {
        responseStreamController.add(message as Map<String, dynamic>);
      }
    });

    return StandaloneExpressionCompiler._(
        responseStreamController.stream, (await sendPortCompleter.future).send,
        onShutdown: () {
      isolate.kill();
      receivePort.close();
    });
  }

  @override
  Future<ExpressionCompilationResult> compileExpressionToJs(
      String isolateId,
      String libraryUri,
      int line,
      int column,
      Map<String, String> jsModules,
      Map<String, String> jsFrameValues,
      String moduleName,
      String expression) async {
    var request = _ServiceRequest({
      'command': 'CompileExpression',
      'libraryUri': libraryUri,
      'line': line,
      'column': column,
      'jsModules': jsModules,
      'jsScope': jsFrameValues,
      'expression': expression,
      'moduleName': moduleName,
    });
    _requestQueue.add(request);
    _maybeSendNextRequest();
    var response = await request.response;
    return ExpressionCompilationResult(response['compiledProcedure'] as String,
        !(response['succeeded'] as bool));
  }

  Future<bool> updateDependencies(List<InputDill> dependencies) async {
    var request = _ServiceRequest({
      'command': 'UpdateDeps',
      'inputs': [
        for (var dep in dependencies)
          {
            'path': dep.path,
            'moduleName': dep.moduleName,
          }
      ]
    });
    _requestQueue.add(request);
    _maybeSendNextRequest();
    var response = await request.response;
    return response['succeeded'] as bool;
  }

  void shutdown() {
    if (_onShutdown != null) _onShutdown();
  }

  /// Sends the next request if one is available and another is not pending.
  void _maybeSendNextRequest() {
    if (_requestQueue.isEmpty || _pendingRequest != null) return;

    _pendingRequest = _requestQueue.removeFirst();
    _sendRequest(_pendingRequest.request);
  }
}

/// Represents an input dill that needs to be loaded.
class InputDill {
  final String path;
  final String moduleName;

  InputDill(this.path, {String moduleName}) : moduleName = moduleName ?? path;
}

/// A pending request object plus its response completer.
class _ServiceRequest {
  final Map<String, dynamic> request;
  final responseCompleter = Completer<Map<String, dynamic>>();

  Future<Map<String, dynamic>> get response => responseCompleter.future;

  _ServiceRequest(this.request);
}

final _sdkDir = p.dirname(p.dirname(Platform.resolvedExecutable));
