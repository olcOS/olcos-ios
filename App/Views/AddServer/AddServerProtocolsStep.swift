import SwiftUI

/// Step 3 — call carriers (multi-select, first pick is primary) with a
/// transport each, and Xray as the direct protocol beside them. Descriptions
/// come from the verified `carrier*Desc` / `transport*Desc` strings; the
/// badges follow upstream's guidance only.
struct AddServerProtocolsStep: View {
    @ObservedObject var flow: AddServerFlowController
    @State private var showsXrayAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.s4) {
            AddServerLead(text: .addFlowProtocolsLead)
            OlcSectionHeader(L10n.addFlowCallsSection.localized())
            ForEach(CarrierTransportMatrix.carriers, id: \.self) { carrier in
                carrierCard(carrier)
            }
            Text(L10n.carrierFooter.localized())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            OlcSectionHeader(L10n.addFlowDirectSection.localized())
            xrayCard
            if !flow.plan.hasAnything {
                AddServerInlineError(message: L10n.addFlowPickAtLeastOne.localized())
            }
        }
    }

    // MARK: Xray card

    private var xrayCard: some View {
        let selected = flow.plan.xray
        return OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { flow.plan.xray.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                            HStack(spacing: Theme.Metrics.s2) {
                                Text(L10n.xrayProtocolTitle.localized())
                                    .font(Theme.Typography.title)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                AddServerBadge(text: L10n.addFlowBadgeFast.localized(), tone: .ok)
                            }
                            Text(L10n.xrayProtocolDesc.localized())
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Theme.Metrics.s2)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(Theme.Typography.title)
                            .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])

                if selected {
                    DisclosureGroup(isExpanded: $showsXrayAdvanced) {
                        xrayAdvanced
                            .padding(.top, Theme.Metrics.s2)
                    } label: {
                        Text(L10n.xrayAdvancedTitle.localized())
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    .tint(Theme.Palette.accent)
                }
            }
        }
    }

    /// Automatic unless the user types something; the server validates the
    /// site itself (TLS 1.3, H2, certificate size) before it is used.
    private var xrayAdvanced: some View {
        let options = flow.plan.xrayOptions
        return VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
            FormField(label: L10n.xrayTargetField.localized(),
                      placeholder: L10n.xrayTargetPlaceholder.localized(),
                      text: $flow.plan.xrayOptions.target,
                      keyboard: .URL, mono: true,
                      helper: L10n.xrayTargetHint.localized())
            if !options.isTargetValid {
                AddServerInlineError(message: L10n.xrayTargetInvalid.localized())
            }
            FormField(label: L10n.xrayPortField.localized(), placeholder: "443",
                      text: $flow.plan.xrayOptions.port,
                      keyboard: .numberPad, mono: true,
                      helper: L10n.xrayPortHint.localized())
            if !options.isPortValid {
                AddServerInlineError(message: L10n.validateXrayPortRange.localized())
            }
        }
    }

    // MARK: Carrier card

    private func carrierCard(_ carrier: String) -> some View {
        let selected = flow.plan.selected.contains(carrier)
        let isPrimary = flow.plan.primary == carrier
        return OlcCard {
            VStack(alignment: .leading, spacing: Theme.Metrics.s3) {
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { flow.plan.toggle(carrier) }
                } label: {
                    HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                        VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
                            Text(CarrierTransportMatrix.carrierLabel(carrier))
                                .font(Theme.Typography.title)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            // Under the title and wrapping as a group: beside
                            // it, "Yandex account needed" broke into three lines.
                            let badges = badgeList(carrier, isPrimary: isPrimary)
                            if !badges.isEmpty {
                                FlowLayout(spacing: Theme.Metrics.s2, lineSpacing: Theme.Metrics.s1) {
                                    ForEach(badges, id: \.text) { badge in
                                        AddServerBadge(text: badge.text, tone: badge.tone)
                                    }
                                }
                            }
                            Text(AddServerCarrierPlan.descriptionKey(forCarrier: carrier).localized())
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Theme.Metrics.s2)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(Theme.Typography.title)
                            .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])

                if selected {
                    transportPicker(carrier)
                    if !isPrimary {
                        OlcButton(L10n.addFlowBadgePrimary.localized(), systemImage: "star",
                                  role: .ghost, compact: true) {
                            withAnimation(.snappy) { flow.plan.makePrimary(carrier) }
                        }
                    }
                }
            }
        }
    }

    private func badgeList(_ carrier: String, isPrimary: Bool) -> [(text: String, tone: OlcStatusTone)] {
        var list: [(text: String, tone: OlcStatusTone)] = []
        let kind = AddServerCarrierPlan.badge(for: carrier)
        if let title = kind.title {
            list.append((title.localized(), kind == .recommended ? .ok : .unknown))
        }
        if let need = AddServerCarrierPlan.requirement(for: carrier) {
            list.append((need.text.localized(), need.tone))
        }
        if isPrimary, flow.plan.selected.count > 1 {
            list.append((L10n.addFlowBadgePrimary.localized(), .progress))
        }
        return list
    }

    // MARK: Transport

    private func transportPicker(_ carrier: String) -> some View {
        let options = AddServerCarrierPlan.transportOptions(for: carrier)
        let recommended = AddServerCarrierPlan.recommendedTransport(for: carrier)
        let binding = Binding<String>(
            get: { flow.plan.transport(for: carrier) },
            set: { flow.plan.transport[carrier] = $0 }
        )
        return VStack(alignment: .leading, spacing: Theme.Metrics.s2) {
            OlcSectionHeader(L10n.addFlowTransportFor_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier)))
            ForEach(options, id: \.self) { transport in
                transportRow(transport, carrier: carrier, selected: binding.wrappedValue == transport,
                             recommended: transport == recommended) {
                    Haptics.tap()
                    binding.wrappedValue = transport
                }
            }
        }
    }

    private func transportRow(_ transport: String, carrier: String, selected: Bool,
                              recommended: Bool, action: @escaping () -> Void) -> some View {
        let compat = CarrierTransportMatrix.compat(carrier: carrier, transport: transport)
        return Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Metrics.s3) {
                VStack(alignment: .leading, spacing: Theme.Metrics.s1) {
                    HStack(spacing: Theme.Metrics.s2) {
                        Text(CarrierTransportMatrix.transportLabel(transport))
                            .font(selected ? Theme.Typography.bodyStrong : Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if recommended {
                            AddServerBadge(text: L10n.addFlowBadgeRecommended.localized(), tone: .ok)
                        }
                    }
                    Text(AddServerCarrierPlan.descriptionKey(forTransport: transport).localized())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if compat == .question {
                        Text(L10n.matrixQuestion_fmt.formatted(CarrierTransportMatrix.carrierLabel(carrier)))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.orange)
                    }
                }
                Spacer(minLength: Theme.Metrics.s2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Metrics.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
