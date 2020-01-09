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

import 'frontend_asset_server.dart';

final _sdkDir = p.dirname(p.dirname(Platform.resolvedExecutable));

class FrontendServerClient implements BuildDaemonClient {
  final Function(ServerLog) _logHandler;
  final Process _feServer;
  final Stream<String> _feServerStdOutLines;
  final _buildTargets = <String, bool>{};
  final FrontendAssetServer _assetServer;

  FrontendServerClient._(this._logHandler, this._feServer, this._assetServer)
      : _feServerStdOutLines = _feServer.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .asBroadcastStream() {
    _feServer.exitCode.then((_) => _finished.complete(null));
    _feServerStdOutLines.listen((line) => _logHandler(ServerLog((b) => b
      ..message = line
      ..level = Level.WARNING
      ..loggerName = 'FrontendServer')));

    _feServer.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _logHandler(ServerLog((b) => b
          ..message = line
          ..level = Level.SEVERE
          ..loggerName = 'FrontendServer')));
  }

  static Future<FrontendServerClient> create(String workingDirectory,
          List<String> options, Function(ServerLog) logHandler) async =>
      FrontendServerClient._(
        logHandler,
        await Process.start(
            p.join(_sdkDir, 'bin', 'dart'),
            [
              p.join(
                  _sdkDir, 'bin', 'snapshots', 'frontend_server.dart.snapshot'),
              '--sdk-root',
              _sdkDir,
              '--platform',
              p.join(_sdkDir, 'lib', '_internal', 'ddc_sdk.dill'),
              '--target',
              'dartdevc',
              '--filesystem-root',
              p.current,
              '--filesystem-scheme',
              'org-dartlang-app',
              '--output-dill',
              '.dart_tool/webdev/frontend_server/main.dart.dill',
              ...options,
            ],
            workingDirectory: workingDirectory),
        await FrontendAssetServer.start(workingDirectory),
      );

  @override
  Stream<BuildResults> get buildResults => _buildResultsController.stream;
  final _buildResultsController = StreamController<BuildResults>.broadcast();

  @override
  Future<void> close() async {
    await _buildResultsController.close();
    await _assetServer.close();
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
      var absolutePath = 'org-dartlang-app:/${p.join(target, 'main.dart')}';

      var command = StringBuffer('$action $absolutePath');
      if (action == 'recompile') {
        var boundaryKey = Uuid().v4();
        command
          ..writeln(boundaryKey)
          ..writeln(absolutePath)
          ..write(boundaryKey);
      }

      _feServer.stdin.writeln(command);
      var state = 'StartedBuild';
      String feBoundaryKey;
      await _feServerStdOutLines.takeWhile((line) {
        switch (state) {
          case 'StartedBuild':
            assert(line.startsWith('result'));
            feBoundaryKey = line.substring(line.indexOf(' ') + 1);
            state = 'WaitingForKey';

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
              state = 'Done';
              return false;
            }
            return true;
          default:
            throw StateError('Unreachable! state is $state');
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
