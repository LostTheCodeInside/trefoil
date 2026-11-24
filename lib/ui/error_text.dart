import '../core/action_error.dart';
import '../core/profile/routing.dart';
import '../core/profile/server_check.dart';
import '../l10n/app_localizations.dart';
import 'l10n_ext.dart';

/// Says a failure in the user's language.
///
/// Takes an [ActionError] or any exception. The sentence is translated; whatever only
/// makes sense verbatim — a parser's complaint, the operating system's reason — is
/// appended as it came, because translating "unexpected character at line 3" would
/// only make it harder to search for.
String describeError(AppLocalizations l10n, Object error) {
  final e = ActionError.from(error);
  final lead = switch (e.kind) {
    ActionErrorKind.noServer => l10n.errorNoServer,
    // Already carries its detail in the sentence.
    ActionErrorKind.serverUnsupported => l10n.errorServerUnsupported(e.subject, switch (e.problem) {
      final ServerProblem problem => describeProblem(l10n, problem),
      null => e.detail,
    }),
    ActionErrorKind.xrayUnconvertible => l10n.errorXrayUnconvertible(e.subject),
    ActionErrorKind.vpnPermission => l10n.errorVpnPermission,
    ActionErrorKind.configRejected => l10n.errorConfigRejected,
    ActionErrorKind.warpNotOn => l10n.errorWarpNotOn,
    ActionErrorKind.warpRegistration => l10n.errorWarpRegistration,
    ActionErrorKind.saveFailed => l10n.errorSaveFailed,
    ActionErrorKind.profileDamaged => l10n.errorProfileDamaged,
    ActionErrorKind.ruleSetsUnavailable => l10n.errorRuleSetsUnavailable(
      e.subject.split(',').map((id) => _listName(l10n, id)).join(', '),
    ),
    ActionErrorKind.notALink => l10n.errorNotALink,
    ActionErrorKind.wireGuardIncomplete => l10n.errorWireGuardIncomplete,
    ActionErrorKind.subscriptionRefused => l10n.errorSubscriptionRefused(e.subject),
    ActionErrorKind.subscriptionNotFound => l10n.errorSubscriptionNotFound(e.subject),
    ActionErrorKind.subscriptionRateLimited => l10n.errorSubscriptionRateLimited,
    ActionErrorKind.subscriptionServerError => l10n.errorSubscriptionServerError(e.subject),
    ActionErrorKind.subscriptionHttp => l10n.errorSubscriptionHttp(e.subject),
    ActionErrorKind.subscriptionTooLarge => l10n.errorSubscriptionTooLarge,
    ActionErrorKind.subscriptionEmpty => l10n.errorSubscriptionEmpty,
    ActionErrorKind.unreachable =>
      e.subject.isEmpty ? l10n.errorUnreachable : l10n.errorUnreachableHost(e.subject),
    ActionErrorKind.tls => l10n.errorTls,
    ActionErrorKind.timeout => l10n.errorTimeout,
    ActionErrorKind.network => l10n.errorNetwork,
    ActionErrorKind.unreadable => l10n.errorUnreadable,
    ActionErrorKind.wrongPassword => l10n.errorWrongPassword,
    ActionErrorKind.notABackup => l10n.errorNotABackup,
    ActionErrorKind.backupTooNew => l10n.errorBackupTooNew,
    ActionErrorKind.fileTooLarge => l10n.errorFileTooLarge,
    ActionErrorKind.fileFailed => l10n.errorFileFailed,
    ActionErrorKind.noFilePicker => l10n.errorNoFilePicker,
    ActionErrorKind.dialogOpen => l10n.errorDialogOpen,
    ActionErrorKind.tunnelUnavailable => l10n.errorTunnelUnavailable,
    ActionErrorKind.vpnUnavailable => l10n.errorVpnUnavailable,
    ActionErrorKind.startFailed => l10n.errorStartFailed,
    ActionErrorKind.coreFailed => l10n.errorCoreFailed,
    ActionErrorKind.unknown => l10n.errorUnknown,
  };
  final tail = switch (e) {
    ActionError(:final cause?) => describeError(l10n, cause),
    ActionError(kind: ActionErrorKind.serverUnsupported) => '',
    ActionError(:final detail) => detail.trim(),
  };
  return tail.isEmpty ? lead : l10n.errorWithDetail(lead, tail);
}

String _listName(AppLocalizations l10n, String id) => RuleSetPreset.byId(id)?.label(l10n) ?? id;

/// Why a server cannot be used, as the end of a sentence that says it cannot.
String describeProblem(AppLocalizations l10n, ServerProblem problem) => switch (problem.code) {
  ServerProblem.plugin => l10n.problemPlugin(problem.detail),
  ServerProblem.transport => l10n.problemTransport(problem.detail),
  ServerProblem.insecureTls => l10n.problemInsecureTls,
  ServerProblem.port => l10n.problemPort,
  ServerProblem.cipher => l10n.problemCipher(problem.detail),
  ServerProblem.flow => l10n.problemFlow(problem.detail),
  ServerProblem.key => l10n.problemKey,
  ServerProblem.fingerprint => l10n.problemFingerprint(problem.detail),
  ServerProblem.obfs => l10n.problemObfs(problem.detail),
  ServerProblem.congestion => l10n.problemCongestion(problem.detail),
  ServerProblem.path => l10n.problemPath,
  // From a version that knows more reasons, or a sentence stored before there were
  // codes. Shown as it is.
  _ => problem.detail.isEmpty ? problem.code : problem.detail,
};
