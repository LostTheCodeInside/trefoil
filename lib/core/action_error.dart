import 'dart:async';
import 'dart:io';

import 'profile/profile_store.dart';
import 'profile/server_check.dart';
import 'tunnel_channel.dart';

/// Why something the user asked for did not happen: a [kind] the UI can say in the
/// user's language, plus whatever only makes sense verbatim.
///
/// This layer has no BuildContext and no translations, and it should not grow them.
/// It used to build English sentences here, which is what most people using this app
/// — in Persian, Russian, Chinese — then read in a snackbar at exactly the moment
/// something had gone wrong. The sentence is now the UI's job; this only sorts.
class ActionError {
  const ActionError(this.kind, {this.subject = '', this.detail = '', this.problem, this.cause});

  /// Sorts any exception into a kind. Anything unrecognised keeps its own text as
  /// detail, so nothing is ever reduced to a bare "something went wrong".
  factory ActionError.from(Object error) => switch (error) {
    ActionError() => error,
    TunnelException(:final code, :final message) => switch (code) {
      'wrong_password' => const ActionError(ActionErrorKind.wrongPassword),
      'not_a_backup' => const ActionError(ActionErrorKind.notABackup),
      'too_large' => const ActionError(ActionErrorKind.fileTooLarge),
      'unsupported' => const ActionError(ActionErrorKind.tunnelUnavailable),
      'vpn_unavailable' => ActionError(ActionErrorKind.vpnUnavailable, detail: message),
      'busy' || 'prepare_in_progress' => const ActionError(ActionErrorKind.dialogOpen),
      'no_file_picker' => const ActionError(ActionErrorKind.noFilePicker),
      'save_failed' || 'open_failed' => ActionError(ActionErrorKind.fileFailed, detail: message),
      'start_failed' => ActionError(ActionErrorKind.startFailed, detail: message),
      _ => ActionError(ActionErrorKind.coreFailed, detail: message),
    },
    SubscriptionException(:final status?) => ActionError(switch (status) {
      401 || 403 => ActionErrorKind.subscriptionRefused,
      404 || 410 => ActionErrorKind.subscriptionNotFound,
      429 => ActionErrorKind.subscriptionRateLimited,
      >= 500 => ActionErrorKind.subscriptionServerError,
      _ => ActionErrorKind.subscriptionHttp,
    }, subject: '$status'),
    SubscriptionException(:final tooLarge) when tooLarge => const ActionError(
      ActionErrorKind.subscriptionTooLarge,
    ),
    SubscriptionException() => const ActionError(ActionErrorKind.subscriptionEmpty),
    BackupTooNewException() => const ActionError(ActionErrorKind.backupTooNew),
    SocketException(:final address, :final message, :final osError) => ActionError(
      ActionErrorKind.unreachable,
      subject: address?.host ?? '',
      detail: osError?.message ?? message,
    ),
    HandshakeException(:final message) ||
    TlsException(:final message) => ActionError(ActionErrorKind.tls, detail: message),
    TimeoutException() => const ActionError(ActionErrorKind.timeout),
    HttpException(:final message) => ActionError(ActionErrorKind.network, detail: message),
    FormatException(:final message) => ActionError(ActionErrorKind.unreadable, detail: message),
    _ => ActionError(ActionErrorKind.unknown, detail: '$error'),
  };

  final ActionErrorKind kind;

  /// What the failure is about, when the sentence names it: a server, a host, the
  /// lists that would not download, an HTTP status.
  final String subject;

  /// The words that only make sense verbatim — a core's parser message, an OS error.
  /// Appended to the translated sentence rather than translated.
  final String detail;

  /// What is wrong with the server in [subject], for [ActionErrorKind.serverUnsupported].
  final ServerProblem? problem;

  /// The failure underneath, for a sentence that says what was being attempted:
  /// "Could not register with Cloudflare" because the network was unreachable.
  final ActionError? cause;

  @override
  String toString() => [
    kind.name,
    subject,
    detail,
    ?problem?.toString(),
    ?cause?.toString(),
  ].where((part) => part.isNotEmpty).join(': ');
}

enum ActionErrorKind {
  noServer,
  serverUnsupported,
  xrayUnconvertible,
  vpnPermission,
  configRejected,
  warpNotOn,
  warpRegistration,
  saveFailed,
  profileDamaged,
  ruleSetsUnavailable,
  notALink,
  wireGuardIncomplete,
  subscriptionRefused,
  subscriptionNotFound,
  subscriptionRateLimited,
  subscriptionServerError,
  subscriptionHttp,
  subscriptionTooLarge,
  subscriptionEmpty,
  unreachable,
  tls,
  timeout,
  network,
  unreadable,
  wrongPassword,
  notABackup,
  backupTooNew,
  fileTooLarge,
  fileFailed,
  noFilePicker,
  dialogOpen,
  tunnelUnavailable,
  vpnUnavailable,
  startFailed,
  coreFailed,
  unknown,
}
