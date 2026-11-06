// zz_olcos_logflags.go — olcOS BUILD SHIM, not core code.
//
// The core logs through the stdlib `log` package and leaves its flags at the
// default date-and-time prefix. The app's log pipeline (LogStore cleanup and
// redaction, WedgeDetector signatures) reads lines prefixed by the time only
// ("15:04:05 "), so this pins that shape once, when the package loads.
//
// scripts/build-framework.sh copies this file into olcrtc-upstream/mobile/
// right before `gomobile bind` and trap-deletes it after, so the submodule
// stays clean.
package mobile

import "log"

//nolint:gochecknoinits // build shim: must run before the first log line
func init() {
	log.SetFlags(log.Ltime)
}
