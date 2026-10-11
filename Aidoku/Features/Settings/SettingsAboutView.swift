//
//  SettingsAboutView.swift
//  Aidoku
//
//  Created by Skitty on 9/19/25.
//

import SwiftUI

struct SettingsAboutView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text(NSLocalizedString("VERSION"))
                    Spacer()
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? NSLocalizedString("UNKNOWN")
                    Text(version)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(NSLocalizedString("BUILD"))
                    Spacer()
                    let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                    ?? NSLocalizedString("UNKNOWN")
                    Text(version)
                        .foregroundStyle(.secondary)
                }
            }

            AidokuTSignedUpdateSection()

            Section {
                SettingView(setting: .init(
                    title: NSLocalizedString("GITHUB_REPO"),
                    value: .link(.init(url: "https://github.com/Aidoku/Aidoku"))
                ))
                SettingView(setting: .init(
                    title: NSLocalizedString("DISCORD_SERVER"),
                    value: .link(.init(url: "https://discord.gg/9U8cC5Zk3s", external: true))
                ))
                SettingView(setting: .init(
                    title: NSLocalizedString("SUPPORT_VIA_KOFI"),
                    value: .link(.init(url: "https://ko-fi.com/skittyblock", external: true))
                ))
            }
        }
        .navigationTitle(NSLocalizedString("ABOUT"))
    }
}


/// The portal contains signed personal builds; iOS still asks to install them.
struct AidokuTSignedUpdateSection: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("aidokut.signedUpdatePortal") private var portal = ""
    @State private var editing = false
    @State private var draft = ""
    @State private var invalid = false

    private var configuredPortal: String {
        portal.isEmpty ? (Bundle.main.object(forInfoDictionaryKey: "AidokuTUpdateURL") as? String ?? "") : portal
    }

    private func installURL(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        var query = parts.queryItems?.filter { $0.name != "app" } ?? []
        query.append(URLQueryItem(name: "app", value: "AidokuT"))
        parts.queryItems = query
        parts.fragment = "library"
        return parts.url
    }

    var body: some View {
        Section {
            Button {
                if let url = installURL(configuredPortal) {
                    openURL(url) { accepted in if !accepted { invalid = true } }
                } else { draft = configuredPortal; editing = true }
            } label: {
                Label("签名更新 / 安装新版", systemImage: "arrow.down.circle")
            }
            Button("修改更新入口") { draft = configuredPortal; editing = true }
                .foregroundStyle(.secondary)
        } header: {
            Text("AidokuT 定制更新")
        } footer: {
            Text("打开个人签名工作台，登录后查看并安装 AidokuT 新版。保留原安装标识，安装需系统确认。")
        }
        .alert("更新入口", isPresented: $editing) {
            TextField("HTTPS 工作台地址", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("取消", role: .cancel) {}
            Button("保存") {
                if installURL(draft) != nil { portal = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
                else { invalid = true }
            }
        } message: { Text("填写自己的签名工作台地址，不要填写账号或密码。") }
        .alert("无法打开更新入口", isPresented: $invalid) {
            Button("好", role: .cancel) {}
        } message: { Text("请检查 HTTPS 地址和浏览器设置。") }
    }
}
