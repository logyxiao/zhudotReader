import SwiftUI
import CoreImage.CIFilterBuiltins

struct LANSyncView: View {
    @Environment(ReaderStore.self) private var store
    @State private var selectedAddress = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("扫码同步阅读").font(.title2.bold())
            Text("手机与电脑连接同一 Wi-Fi，扫码即可接着阅读。\n电脑需保持运行，阅读位置会双向同步。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if store.lanSync.isRunning {
                if let url = selectedURL, let qr = qrImage(url) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(12).background(.white)
                    if store.lanSync.addresses.count > 1 {
                        Picker("网络地址", selection: $selectedAddress) {
                            ForEach(store.lanSync.addresses, id: \.self) { address in
                                Text(URL(string: address)?.host ?? address).tag(address)
                            }
                        }
                    }
                    Button("复制阅读链接") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                Text(store.lanSync.status).font(.callout)
                Text("仅共享开启时选中的书。持有链接的局域网设备可读取正文并同步位置。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("关闭同步", role: .destructive) { store.lanSync.stop() }
            } else {
                Text(store.lanSync.status).font(.callout).foregroundStyle(.secondary)
                Button("开启当前书籍同步") { store.startLANSync() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.activeReadingDocument == nil || store.isEditingContent)
            }
        }
        .padding(24).frame(width: 380)
        .onChange(of: store.lanSync.addresses) { _, addresses in selectedAddress = addresses.first ?? "" }
    }

    private var selectedURL: String? {
        store.lanSync.addresses.contains(selectedAddress) ? selectedAddress : store.lanSync.addresses.first
    }

    private func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
