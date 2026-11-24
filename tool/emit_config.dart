// Emits a config from ConfigBuilder so it can be checked with the real sing-box
// binary:  dart run tool/emit_config.dart [link] [ruleSetDir] | sing-box check -c /dev/stdin
//
// Passing a directory of downloaded .srs files exercises the routing rules too;
// without it the presets are left out, exactly as they are at runtime when a
// download has not succeeded.
import 'dart:convert';
import 'dart:io';

import 'package:trefoil/core/profile/config_builder.dart';
import 'package:trefoil/core/profile/routing.dart';
import 'package:trefoil/core/profile/share_link.dart';
import 'package:trefoil/core/profile/warp.dart';

void main(List<String> args) {
  // An empty first argument means "use the sample", so a rule-set directory can be
  // passed without also supplying a link.
  final link = args.isNotEmpty && args.first.isNotEmpty
      ? args.first
      : 'vless://11111111-2222-3333-4444-555555555555@example.com:443'
            '?type=ws&security=tls&sni=example.com&path=%2Fws&host=example.com#Test%20Server';
  final outbound = ShareLink.parse(link);
  if (outbound == null) {
    stderr.writeln('could not parse: $link');
    exit(2);
  }

  final ruleSetPaths = <String, String>{};
  if (args.length > 1 && args[1].isNotEmpty) {
    for (final preset in RuleSetPreset.catalog) {
      final file = File('${args[1]}/${preset.id}.srs');
      if (file.existsSync()) ruleSetPaths[preset.id] = file.path;
    }
  }

  // A third argument points at a registered WARP account, so the endpoint and the
  // rule that targets it are exercised too.
  WarpAccount? warp;
  if (args.length > 2 && args[2].isNotEmpty) {
    warp = WarpAccount.fromJson(
      (jsonDecode(File(args[2]).readAsStringSync()) as Map).cast<String, Object?>(),
    );
  }

  final builder = ConfigBuilder(
    routing: RoutingSettings(
      warp: warp,
      enabledPresets: {
        'geosite-category-ads-all',
        'geoip-id',
        'geosite-private',
        'geosite-category-porn',
      },
      rules: [
        RoutingRule(match: RuleMatch.domainSuffix, value: 'netflix.com', action: RuleAction.proxy),
        RoutingRule(match: RuleMatch.domainSuffix, value: 'go.id', action: RuleAction.direct),
        RoutingRule(match: RuleMatch.domainKeyword, value: 'doubleclick', action: RuleAction.block),
        RoutingRule(match: RuleMatch.ipCidr, value: '10.0.0.0/8', action: RuleAction.direct),
        RoutingRule(
          match: RuleMatch.packageName,
          value: 'com.gojek.app',
          action: RuleAction.direct,
        ),
        RoutingRule(
          match: RuleMatch.domain,
          value: 'disabled.example',
          action: RuleAction.block,
          enabled: false,
        ),
        RoutingRule(match: RuleMatch.domainSuffix, value: 'openai.com', action: RuleAction.warp),
      ],
    ),
  );
  // A second server so the selector and urltest groups are exercised.
  final other = ShareLink.parse('trojan://pw@backup.example:443#Backup')!;
  stdout.write(builder.build(outbound, servers: [outbound, other], ruleSetPaths: ruleSetPaths));
}
