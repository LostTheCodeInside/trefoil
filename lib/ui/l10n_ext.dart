import '../core/profile/routing.dart';
import '../core/tunnel_status.dart';
import '../l10n/app_localizations.dart';

/// Human-readable names for the core's enums.
///
/// These live here rather than on the enums themselves: `core` describes what the
/// tunnel does and has no business holding display strings, let alone translated
/// ones. Keeping them out also means a new language needs no changes below the UI.
extension RuleActionText on RuleAction {
  String label(AppLocalizations l10n) => switch (this) {
    RuleAction.proxy => l10n.actionProxy,
    RuleAction.direct => l10n.actionDirect,
    RuleAction.block => l10n.actionBlock,
    RuleAction.warp => l10n.actionWarp,
  };
}

extension RuleMatchText on RuleMatch {
  String label(AppLocalizations l10n) => switch (this) {
    RuleMatch.domainSuffix => l10n.matchDomainSuffix,
    RuleMatch.domain => l10n.matchDomain,
    RuleMatch.domainKeyword => l10n.matchDomainKeyword,
    RuleMatch.domainRegex => l10n.matchDomainRegex,
    RuleMatch.ipCidr => l10n.matchIpCidr,
    RuleMatch.packageName => l10n.matchPackageName,
    RuleMatch.port => l10n.matchPort,
    RuleMatch.portRange => l10n.matchPortRange,
    RuleMatch.network => l10n.matchNetwork,
    RuleMatch.protocol => l10n.matchProtocol,
  };

  String hint(AppLocalizations l10n) => switch (this) {
    RuleMatch.domainSuffix => l10n.hintDomainSuffix,
    RuleMatch.domain => l10n.hintDomain,
    RuleMatch.domainKeyword => l10n.hintDomainKeyword,
    RuleMatch.domainRegex => l10n.hintDomainRegex,
    RuleMatch.ipCidr => l10n.hintIpCidr,
    RuleMatch.packageName => l10n.hintPackageName,
    RuleMatch.port => l10n.hintPort,
    RuleMatch.portRange => l10n.hintPortRange,
    RuleMatch.network => l10n.hintNetwork,
    RuleMatch.protocol => l10n.hintProtocol,
  };
}

extension TunnelStageText on TunnelStage {
  String label(AppLocalizations l10n) => switch (this) {
    TunnelStage.starting => l10n.stateConnecting,
    TunnelStage.started => l10n.stateConnected,
    TunnelStage.stopping => l10n.stateDisconnecting,
    TunnelStage.stopped => l10n.stateNotConnected,
  };
}
