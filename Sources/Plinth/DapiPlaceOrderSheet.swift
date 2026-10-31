import SwiftUI

// "Review 3DAPI order" (from the composer's Review Order…) and "Cancel 3DAPI order" (from the detail's Cancel Order…).
// The flows and their rules live in DapiOrderComposer.swift. Place Order and Cancel Order are never the default
// button and have no shortcut; Go Back takes Escape. Neither sheet can close while its request waits for 3DAPI.

struct DapiPlaceOrderSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = DapiOrderSession.shared
    @StateObject private var runner: DapiPlaceOrderRunner
    @State private var registered = false
    let onPlaced: (DapiOrder) -> Void
    let onFound: (DapiOrder) -> Void

    init(draft: DapiOrderDraft, onPlaced: @escaping (DapiOrder) -> Void, onFound: @escaping (DapiOrder) -> Void) {
        _runner = StateObject(wrappedValue: DapiPlaceOrderRunner(draft: draft, environment: .live()))
        self.onPlaced = onPlaced
        self.onFound = onFound
    }

    private var draft: DapiOrderDraft { runner.draft }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review 3DAPI order").font(.title2.weight(.bold))
                Text(dapiOrderChargeNote).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    status
                    if !runner.changes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("The figures changed since you reviewed them, so nothing was sent. Check the new figures and press Place Order again.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(runner.changes, id: \.self) { change in
                                Text(change).font(.callout).padding(.leading, 20)
                            }
                        }
                    }
                    figures
                    recipient
                    notes
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(20)
        }
        .frame(minWidth: 620, idealWidth: 700, maxWidth: 900, minHeight: 540, idealHeight: 680)
        .interactiveDismissDisabled(runner.isWriting)
        .confirmationDialog("Place another order?", isPresented: Binding(
            get: { runner.askPlaceAnyway },
            set: { if !$0 { runner.declinePlaceAnyway() } }
        ), titleVisibility: .visible) {
            // No shortcut: it charges.
            Button("Place Anyway") { runner.placeOrder(confirmedAnyway: true) }
            Button("Don’t Place", role: .cancel) { runner.declinePlaceAnyway() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(dapiPlaceAnywayMessage(session.unconfirmedOrders))
        }
        .onAppear {
            if !registered {
                registered = true
                session.sheetOpened()
            }
            runner.log = dapiOrderActivityLogger(store)
            runner.onPlaced = onPlaced
            runner.start()
        }
        .onDisappear {
            runner.close()
            if registered {
                registered = false
                session.sheetClosed()
            }
        }
        .onChange(of: runner.phase) { _, phase in
            if case .placed = phase { dismiss() }
        }
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        switch runner.phase {
        case .checking:
            progress("Checking your 3DAPI account, the quotes and shipping…")
        case .rechecking:
            progress("Checking the figures once more before placing the order…")
        case .placing:
            progress("Placing the order with 3DAPI… Don’t quit Plinth until 3DAPI answers.")
        case .ready, .placed:
            EmptyView()
        case .blocked(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .notCharged(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("3DAPI didn’t place the order, and nothing was charged.", systemImage: "xmark.octagon")
                    .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        case .unknown(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let attempt = runner.unconfirmed {
                    DapiUnconfirmedOrdersNotice(only: [attempt.id]) { order in onFound(order) }
                }
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Figures

    @ViewBuilder
    private var figures: some View {
        if let figures = runner.figures {
            VStack(alignment: .leading, spacing: 10) {
                Text("Order").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Model"); Text("Materials"); Text("Qty"); Text("Per unit"); Text("Up to")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(draft.lines.enumerated()), id: \.offset) { _, line in
                        let price = figures.quotes[line.request.quoteID]?.price
                        GridRow(alignment: .top) {
                            Text(line.name).lineLimit(2)
                            Text(line.materialsText).font(.callout).fixedSize(horizontal: false, vertical: true)
                            Text("\(line.request.quantity)").monospacedDigit()
                            Text(price.map(dapiMoneyText) ?? "—").monospacedDigit()
                            Text(price.flatMap { dapiLineUpTo(unitPrice: $0, quantity: line.request.quantity) }.map(dapiMoneyText) ?? "—")
                                .monospacedDigit()
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        Text("Shipping")
                        Text(dapiShippingNote(figures.shipping)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(""); Text("")
                        Text(dapiMoneyText(figures.shipping.total) + " excl. VAT").monospacedDigit()
                    }
                    GridRow {
                        Text("Total").fontWeight(.semibold)
                        Text(""); Text(""); Text("")
                        Text(upToTotal(figures).map { "Up to " + dapiMoneyText($0) } ?? "Not added (different currencies, or too large)")
                            .fontWeight(.semibold).monospacedDigit()
                    }
                }
                .font(.callout)
                VStack(alignment: .leading, spacing: 4) {
                    Text(dapiOrderUpToNote)
                    Text(dapiVATNote)
                    Text(dapiWalletNote)
                    if let wallet = figures.wallet {
                        Text("Wallet balance now: \(dapiMoneyText(wallet.balance))"
                             + (wallet.sampleCredit.map { $0.amountMinor > 0 ? " · sample credit \(dapiMoneyText($0))" : "" } ?? ""))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func upToTotal(_ figures: DapiOrderReviewFigures) -> DapiMoney? {
        var lines: [(unitPrice: DapiMoney, quantity: Int)] = []
        for line in draft.lines {
            guard let price = figures.quotes[line.request.quoteID]?.price else { return nil }
            lines.append((price, line.request.quantity))
        }
        return dapiOrderUpToTotal(lines: lines, shipping: figures.shipping.total)
    }

    private var recipient: some View {
        let r = draft.recipient
        let addressLine = [r.line1, r.line2, r.city, r.state, r.postalCode].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 4) {
            Text("Deliver to").font(.headline)
            Text(r.name)
            Text(r.email).foregroundStyle(.secondary)
            if let phone = r.phone { Text(phone).foregroundStyle(.secondary) }
            Text(addressLine).fixedSize(horizontal: false, vertical: true)
            Text(dapiCountryName(r.countryCode))
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Reference").font(.headline)
            let sent = dapiOrderReference(sellerReference: draft.sellerReference, token: "xxxxxxxx")
                .replacingOccurrences(of: "xxxxxxxx", with: "…")
            Text("\(sent) (Plinth adds a new code each time you press Place Order)").font(.callout)
            if let notes = draft.notes {
                Text("Notes").font(.headline).padding(.top, 6)
                Text(notes).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button(runner.phase.isPlacedOrUnknown ? "Close" : "Go Back", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(!runner.canClose)
            Spacer()
            switch runner.phase {
            case .blocked:
                Button("Check Again") { runner.checkAgain() }
                    .help("Read the account, quotes and shipping again. Nothing is ordered.")
            case .ready, .checking, .rechecking, .placing:
                // Never the default button and no shortcut: it charges your 3DAPI wallet at once.
                Button("Place Order") { runner.placeOrder() }
                    .buttonStyle(.bordered)
                    .disabled(!runner.canPlace)
                    .help("Charge your 3DAPI wallet and send this order to production")
            case .placed, .notCharged, .unknown:
                EmptyView()
            }
        }
    }
}

extension DapiPlacePhase {
    /// Nothing more to do here: Close rather than Go Back.
    var isPlacedOrUnknown: Bool {
        switch self {
        case .placed, .unknown: true
        default: false
        }
    }
}

// MARK: - Cancel review

struct DapiCancelOrderSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = DapiOrderSession.shared
    @StateObject private var runner: DapiCancelOrderRunner
    @State private var registered = false
    let request: DapiCancelRequest
    let onOrder: (DapiOrder) -> Void

    init(request: DapiCancelRequest, onOrder: @escaping (DapiOrder) -> Void) {
        self.request = request
        self.onOrder = onOrder
        _runner = StateObject(wrappedValue: DapiCancelOrderRunner(orderID: request.orderID, shownStatus: request.shownStatus,
                                                                  environment: .live()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cancel 3DAPI order").font(.title2.weight(.bold))
            Text("Order \(request.number) · \(request.shownStatus.label)").font(.callout).foregroundStyle(.secondary)
            Text(dapiCancelExplanation).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            status
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(isDone ? "Close" : "Go Back", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(runner.isWriting)
                Spacer()
                if !isDone {
                    // Never the default button and no shortcut.
                    Button("Cancel Order", role: .destructive) { runner.cancelOrder() }
                        .disabled(!runner.canCancel)
                        .help("Ask 3DAPI to cancel this order and refund it to your wallet")
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 260)
        .interactiveDismissDisabled(runner.isWriting)
        .onAppear {
            if !registered {
                registered = true
                session.sheetOpened()
            }
            runner.log = dapiOrderActivityLogger(store)
            runner.onOrder = onOrder
            runner.start()
        }
        .onDisappear {
            runner.close()
            if registered {
                registered = false
                session.sheetClosed()
            }
        }
    }

    private var isDone: Bool { if case .done = runner.phase { true } else { false } }

    @ViewBuilder
    private var status: some View {
        switch runner.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the order from 3DAPI…").font(.callout).foregroundStyle(.secondary)
            }
        case .ready:
            Text("3DAPI still lets this order be cancelled.").font(.callout).foregroundStyle(.secondary)
        case .blocked(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelling:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking 3DAPI to cancel the order… Don’t quit Plinth until 3DAPI answers.").font(.callout).foregroundStyle(.secondary)
            }
        case .done(let outcome):
            switch outcome {
            case .cancelled:
                Label("3DAPI cancelled the order. A paid order is refunded in full to your wallet.", systemImage: "checkmark.circle")
                    .font(.callout)
            case .notYetCancelled(let order):
                Label("3DAPI answered, but the order shows “\(order.status.label)”, not cancelled. Refresh it later to see whether the cancellation went through; Plinth won’t send another meanwhile.",
                      systemImage: "questionmark.circle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .refused(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("3DAPI didn’t cancel the order.", systemImage: "xmark.octagon")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            case .unknown(let message):
                Label(message, systemImage: "questionmark.circle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
