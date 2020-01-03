import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build_daemon/client.dart';
import 'package:build_daemon/data/build_status.dart';
import 'package:build_daemon/data/build_target.dart';
import 'package:build_daemon/data/server_log.dart';
import 'package:build_daemon/data/shutdown_notification.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

final _sdkDir = p.dirname(p.dirname(Platform.resolvedExecutable));

final _feServerBinary =
    '/usr/local/google/home/jakemac/dart-lang-sdk/sdk/pkg/frontend_server/bin/frontend_server_starter.dart';

class FrontendServerClient implements BuildDaemonClient {
  final Function(ServerLog) _logHandler;
  final Process _feServer;
  final Stream<String> _feServerStdOutLines;
  final _buildTargets = <String, bool>{};

  FrontendServerClient._(this._logHandler, this._feServer)
      : _feServerStdOutLines = _feServer.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream() {
    _feServer.exitCode.then((_) => _finished.complete(null));
    _feServerStdOutLines.listen((line) => _logHandler(ServerLog((b) => b
      ..message = line
      ..level = Level.INFO
      ..loggerName = 'FrontendServer')));
  }

  static Future<FrontendServerClient> create(String workingDirectory,
          List<String> options, Function(ServerLog) logHandler) async =>
      FrontendServerClient._(
        logHandler,
        await Process.start(
            p.join(_sdkDir, 'bin', 'dart'),
            [
              _feServerBinary,
              '--incremental',
              '--sdk-root',
              _sdkDir,
              '--platform',
              p.join(_sdkDir, 'lib', '_internal', 'ddc_sdk.dill'),
              '--target',
              'dartdevc',
              ...options,
            ],
            workingDirectory: workingDirectory),
      );

  @override
  Stream<BuildResults> get buildResults => _buildResultsController.stream;
  final _buildResultsController = StreamController<BuildResults>();

  @override
  Future<void> close() async {
    await _buildResultsController.close();
    _feServer.stdin.writeln('quit');
  }

  @override
  Future<void> get finished => _finished.future;
  final _finished = Completer<void>();

  @override
  void registerBuildTarget(BuildTarget target) {
    _buildTargets[target.target] ??= false;
  }

  @override
  Stream<ShutdownNotification> get shutdownNotifications =>
      const Stream<ShutdownNotification>.empty();

  @override
  void startBuild() async {
    for (var target in _buildTargets.keys) {
      var action = _buildTargets[target] ? 'recompile' : 'compile';
      _buildTargets[target] = true;

      var command = '$action $target';
      if (action == 'recompile') {
        var boundaryKey = Uuid().v4();
        command += '$boundaryKey\n$target\n$boundaryKey';
      }

      _feServer.stdin.writeln(command);
      var state = 'StartedBuild';
      String feBoundaryKey;
      await _feServerStdOutLines.takeWhile((line) {
        switch (state) {
          case 'StartedBuild':
            assert(line.startsWith('result'));
            feBoundaryKey = line.substring(line.indexOf(' ') + 1);
            state = 'WaitingForResult';

            _buildResultsController.add(
              BuildResults(
                (b) => b.results.add(FeServerBuildResult(
                  feBoundaryKey,
                  BuildStatus.started,
                  target,
                )),
              ),
            );
            return true;
          case 'WaitingForKey':
            assert(line == feBoundaryKey);
            state = 'GettingDiffs';
            return true;
          case 'GettingDiffs':
            if (line.startsWith(feBoundaryKey)) {
              return false;
            }
            return true;
          default:
            throw StateError('Unreachable');
        }
      }).drain();

      _buildResultsController.add(
        BuildResults(
          (b) => b.results.add(FeServerBuildResult(
            feBoundaryKey,
            BuildStatus.succeeded,
            target,
          )),
        ),
      );
    }
  }
}

class FeServerBuildResult implements BuildResult {
  @override
  final String buildId;

  @override
  final String error;

  @override
  bool get isCached => false;

  @override
  final BuildStatus status;

  @override
  final String target;

  FeServerBuildResult(
    this.buildId,
    this.status,
    this.target, {
    this.error,
  });
}
