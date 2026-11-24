# Security policy

## Supported versions

Only the newest release gets fixes. The app offers it under Settings → About.

## Reporting a vulnerability

Please do not open a public issue. Use
[Report a vulnerability](https://github.com/LostTheCodeInside/trefoil/security/advisories/new)
on this repository's Security tab; only the maintainers can read what you send there.

Say which version of Trefoil and Android you used and how to reproduce it. Leave out real
server addresses, keys, passwords and subscription URLs.

## Scope

Anything in this repository: the app, the Kotlin service, the Go code in `native/cores`,
and the build and release scripts. Traffic leaving the tunnel, secrets readable by other
apps, and an update or backup that is accepted when it should not be matter most.

A flaw in sing-box, Xray-core or amneziawg-go itself is best reported to that project.
Do tell us too if Trefoil's use of it makes it worse.
