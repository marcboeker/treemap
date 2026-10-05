import SwiftUI
import TreemapCore

struct InspectorView: View {
    let model: ScanModel

    var body: some View {
        let infos = model.inspectorInfos
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if infos.isEmpty {
                    ContentUnavailableView("Nothing selected", systemImage: "square.dashed",
                                           description: Text("Hover a cell or click to select it."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else if infos.count == 1 {
                    SingleInfo(model: model, info: infos[0], hover: model.inspectorIsHover)
                } else {
                    MultiInfo(model: model, infos: infos)
                }
            }
            .padding(16)
        }
    }
}

private struct SingleInfo: View {
    let model: ScanModel
    let info: NodeInfo
    let hover: Bool

    var body: some View {
        Text(hover ? "HOVER" : "SELECTED")
            .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: FileIcon.image(forPath: info.path))
                .resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.headline).lineLimit(3).textSelection(.enabled)
                Text(Fmt.size(info)).font(.title3).monospacedDigit()
            }
        }
        Text(info.path)
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        Divider()
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Size", Fmt.size(info))
            row(info.isDirectory ? "Items" : "Kind", info.isDirectory ? info.itemCount.formatted() : "File")
            row("Modified", info.modified.formatted(date: .abbreviated, time: .shortened))
        }
        flags
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Button { model.reveal([info]) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button { model.toggleTray([info.id]) } label: {
                if model.isInTray(info.id) { Label("Remove", systemImage: "tray.and.arrow.up") }
                else { Label("Add to Tray", systemImage: "tray.and.arrow.down") }
            }
            .disabled(info.id == model.session?.rootID)
        }
        .controlSize(.regular)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().textSelection(.enabled)
        }
    }

    @ViewBuilder private var flags: some View {
        let f = info.flags
        let tags: [(String, String)] = [
            (f.contains(.hidden) ? "Hidden" : "", "eye.slash"),
            (f.contains(.mountPoint) ? "Mount point" : "", "externaldrive"),
            (f.contains(.unreadable) ? "Unreadable" : "", "lock"),
            (f.contains(.scanning) ? "Scanning" : "", "hourglass"),
        ].filter { !$0.0.isEmpty }
        if !tags.isEmpty {
            HStack(spacing: 6) {
                ForEach(tags, id: \.0) { t in
                    Label(t.0, systemImage: t.1)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

private struct MultiInfo: View {
    let model: ScanModel
    let infos: [NodeInfo]

    var body: some View {
        let total = model.total(infos)
        Text("SELECTED").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        Text("\(infos.count) items").font(.headline)
        Text("up to \(Fmt.bytes(total))").font(.title3).monospacedDigit()
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            ForEach(infos.prefix(40), id: \.id) { i in
                HStack(spacing: 8) {
                    Image(nsImage: FileIcon.image(forPath: i.path)).resizable().frame(width: 16, height: 16)
                    Text(i.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(Fmt.size(i)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.callout)
            }
            if infos.count > 40 { Text("and \(infos.count - 40) more").font(.caption).foregroundStyle(.secondary) }
        }
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            Button { model.reveal(infos) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Button { model.addToTray(infos.map(\.id)) } label: { Label("Add to Tray", systemImage: "tray.and.arrow.down") }
        }
    }
}
