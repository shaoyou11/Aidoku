import SwiftUI

struct PrivacyDisplayView: View {
    @ObservedObject private var privacy = PrivacyDisplayStore.shared

    var body: some View {
        List {
            Section {
                Toggle("默认隐藏 NSFW 内容", isOn: Binding(
                    get: { privacy.policy.enabled }, set: { privacy.setEnabled($0) }
                ))
                if privacy.policy.enabled {
                    HStack { Text("当前状态"); Spacer(); Text(privacy.policy.temporarilyRevealed ? "临时显示" : "已隐藏").foregroundStyle(.secondary) }
                    if privacy.policy.temporarilyRevealed {
                        Button("立即隐藏") { privacy.hideAgain() }
                    }
                }
            } footer: {
                Text("连续三击底部“书架”可临时显示，再三击可隐藏。切到后台或重新打开 App 后恢复隐藏；关闭上方开关则不再过滤。")
            }
            Section("识别与手动标记") {
                Text("根据图源的 NSFW 评级和手动标记隐藏书架、阅读历史、下载及浏览中的相关条目。没有评级的内容无法自动准确判断，可在漫画详情右上角用眼睛按钮手动标记。")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack { Text("手动标记"); Spacer(); Text("\(privacy.policy.marked.count) 本").foregroundStyle(.secondary) }
                Text("标记只影响显示，不会删除漫画、历史记录或下载文件，也不会修改图源数据。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("隐私显示")
    }
}
