// zz_olcos_ipsec.go — olcOS BUILD SHIM, not core code.
//
// The core's ICE interface filter (internal/protect/pionnet.go) excludes
// tunnel-style interfaces by name prefix — tun, utun, ppp, pptp — but not
// iOS's IPsec tunnels (ipsecN). Without this, pion may gather host candidates
// on an IPsec VPN's interface: ICE noise at best, a routing loop at worst.
// tunInterfacePrefixes is a package var read at call time, so appending in
// init() needs no patching of core files.
//
// scripts/build-framework.sh copies this file into
// olcrtc-upstream/internal/protect/ right before `gomobile bind` and
// trap-deletes it after, so the submodule stays clean.
package protect

//nolint:gochecknoinits // build shim: must run before any interface enumeration
func init() {
	tunInterfacePrefixes = append(tunInterfacePrefixes, "ipsec")
}
