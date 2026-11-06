// Package olcrtc adapts the existing olcrtc WebRTC transport to engine.Engine.
//
// Milestone M0: registration and profile validation only. The runtime hookup
// (upstream `mobile` package + olcos-ios tunstack) is delivered together with
// the single gomobile bind in M2; until then Start returns
// engine.ErrNotImplemented. Upstream openlibrecommunity/olcrtc is archived
// (EoL 2026-09-15); the vendored copy stays untouched, no fork/issue/PR.
package olcrtc

import (
	"context"
	"errors"

	"github.com/Hotelk52339/olcos-core/engine"
)

// Engine implements engine.Engine for the olcrtc transport.
type Engine struct{}

func init() { engine.Register(Engine{}) }

// Kind reports engine.KindOlcrtc.
func (Engine) Kind() engine.Kind { return engine.KindOlcrtc }

// Start validates the profile and (M2) starts the upstream mobile runtime
// plus tunstack. The SOCKS listener is always local because the upstream
// core does not own the TUN device.
func (Engine) Start(ctx context.Context, p engine.Profile, h engine.Host) (engine.Session, error) {
	if err := p.Validate(); err != nil {
		return nil, err
	}
	if p.Host == "" || p.Room == "" {
		return nil, errors.New("olcrtc: carrier and room are required")
	}
	if h == nil {
		return nil, errors.New("olcrtc: nil host")
	}
	return nil, engine.ErrNotImplemented
}
