import SwiftUI

/// Immediate touch feedback without delaying the underlying action.
struct NASActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct NASActionLabel: View {
    let title: String
    var systemImage: String
    var busy = false

    var body: some View {
        HStack(spacing: 10) {
            if busy { ProgressView() } else { Image(systemName: systemImage) }
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Transport-confirmed information; it deliberately does not claim ongoing connectivity.
struct NASConnectionStatusSection: View {
    var compact = false
    @ObservedObject private var connectionStatus = NASConnectionStatus.shared

    var body: some View {
        Section {
            if let snapshot = connectionStatus.snapshot {
                DisclosureGroup {
                    Text(snapshot.address)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .privacySensitive()
                        .fixedSize(horizontal: false, vertical: true)
                    if let remoteAddress = snapshot.remoteAddress {
                        Text("实际连接 IP：" + remoteAddress)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .privacySensitive()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("确认时间：" + snapshot.connectedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } label: {
                    Label((connectionStatus.lastFailureAt.map { $0 > snapshot.connectedAt } == true ? "最近请求失败 · " : "最近成功 · ") + snapshot.family + " · " + snapshot.route, systemImage: "network")
                        .font(.subheadline.weight(.medium))
                }
                if !compact, let failure = connectionStatus.lastFailureAt, failure > snapshot.connectedAt {
                    Label("最近请求失败，上方保留上次成功连接的信息。", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(connectionStatus.lastFailureAt == nil ? "尚未确认实际连接线路" : "最近请求失败，尚无成功连接记录")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: { if !compact { Text("最近成功连接") } } footer: {
            if !compact { Text("根据实际网络请求显示线路，读取手机缓存不会更新此记录。") }
        }
    }
}
