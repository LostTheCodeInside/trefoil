import '../core/action_error.dart';
import '../l10n/app_localizations.dart';

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
    ActionErrorKind.serverUnsupported => l10n.errorServerUnsupported(e.subject, e.detail),
    ActionErrorKind.xrayUnconvertible => l10n.errorXrayUnconvertible(e.subject),
    ActionErrorKind.vpnPermission => l10n.errorVpnPermission,
    ActionErrorKind.configRejected => l10n.errorConfigRejected,
    ActionErrorKind.warpNotOn => l10n.errorWarpNotOn,
    ActionErrorKind.warpRegistration => l10n.errorWarpRegistration,
    ActionErrorKind.saveFailed => l10n.errorSaveFailed,
    ActionErrorKind.ruleSetsUnavailable => l10n.errorRuleSetsUnavailable(e.subject),
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
