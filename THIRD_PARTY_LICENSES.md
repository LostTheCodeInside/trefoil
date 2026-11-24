# Third-party licenses

Trefoil is licensed under GPL-3.0-or-later (see [LICENSE](LICENSE)). It builds on the
projects below. Each keeps its own license; the full texts are in the linked
repositories and in the module and package caches of a build.

## Native cores

Compiled from source into `libcores.aar` by `scripts/build-cores.sh`. The exact
versions are pinned in `native/cores/go.mod`, which also lists the indirect modules.

| Project | License |
|---|---|
| [sing-box](https://github.com/SagerNet/sing-box) | GPL-3.0-or-later, plus a clause on the use of its name |
| [sing](https://github.com/SagerNet/sing) | GPL-3.0-or-later |
| [Xray-core](https://github.com/XTLS/Xray-core) | MPL-2.0 |
| [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go) | MIT |
| [gomobile (SagerNet fork)](https://github.com/SagerNet/gomobile) | BSD-3-Clause |
| [gVisor](https://github.com/google/gvisor) | Apache-2.0 |
| [golang.org/x/crypto, golang.org/x/net](https://cs.opensource.google/go/x) | BSD-3-Clause |

## App

Direct dependencies; versions are pinned in `pubspec.lock`, which also lists the
transitive ones.

| Package | License |
|---|---|
| [Flutter](https://github.com/flutter/flutter) | BSD-3-Clause |
| [intl](https://pub.dev/packages/intl), [http](https://pub.dev/packages/http), [path_provider](https://pub.dev/packages/path_provider) | BSD-3-Clause |
| [mobile_scanner](https://pub.dev/packages/mobile_scanner) | BSD-3-Clause |
| [dynamic_color](https://pub.dev/packages/dynamic_color) | Apache-2.0 |
| [yaml](https://pub.dev/packages/yaml), [cupertino_icons](https://pub.dev/packages/cupertino_icons) | MIT |

## Names

sing-box, Xray and AmneziaWG are the names of their respective projects, used here only
to say what the app is built from. sing-box's license adds that no derivative work may
use its name or imply association with it without consent. Trefoil is not affiliated
with or endorsed by any of these projects.
