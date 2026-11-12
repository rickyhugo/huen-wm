# Local development signing

`scripts/bundle.sh` uses ad-hoc signing for local development only.
It embeds this explicit designated requirement instead of the default requirement tied to the executable's code hash.

```text
designated => identifier "dev.huen-wm"
```

Different builds can satisfy the same requirement even when their executable bytes change.
The bundle identifier remains `dev.huen-wm`.
The script still builds with the repository's exact Zig 0.17.0 toolchain through `mise`.
Without arguments, it creates `zig-out/Huen WM.app` without installation or launch.
With `--install`, it copies the bundle to `~/Applications/Huen WM.app` without launch.

## Permission limits

The purpose is to keep the development code identity stable across rebuilds.
The requirement does not retain grants associated with an older code-hash identity.
After installation, you must manually grant Accessibility and Screen Recording permission to the updated app identity once.
Do not edit the TCC database or attempt to reuse the old hash-based grant.

Local verification confirmed that two temporary bundles with different executable bytes had identical designated requirements.
Both passed strict signature verification against `identifier "dev.huen-wm"`.
A check against a different identifier failed.
These checks prove code identity stability, not TCC permission persistence.
Accessibility and Screen Recording grants still require native verification across an installed rebuild after manual approval.

## Security limits

This requirement checks only the signing identifier.
Anyone can ad-hoc sign another executable with that identifier and satisfy the requirement.
It does not authenticate the developer and must not be used as a distribution trust policy.
The bundle has no Developer ID signature and is not notarized.
This change does not establish Gatekeeper approval.

## Inspect the built bundle

Run these commands after a local build.

```sh
codesign --display --requirements - 'zig-out/Huen WM.app'
codesign --verify --strict --verbose=2 \
	--test-requirement '=identifier "dev.huen-wm"' 'zig-out/Huen WM.app'
```

The first command must print the explicit `designated => identifier "dev.huen-wm"` requirement above.
The second command must report that the explicit requirement is satisfied.

## Syntax sources

Apple's [TN2206, Code Designated Requirement](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) documents explicit designated requirements and `codesign -r`.
Its Code Requirements section defines `identifier` as an exact signing-identifier match and documents verification with `-R`.
The local `man codesign` documents `--requirements`, `--test-requirement`, and the leading `=` for literal requirement text.
