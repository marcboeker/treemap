import AppKit
import SwiftUI

struct VolumeEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    var id: URL { url }
    var used: Int64 { max(0, total - free) }

    static func mounted() -> [VolumeEntry] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsLocalKey,
                                      .volumeIsReadOnlyKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            // Only local, browsable, writable volumes: no network shares, no read-only disk images.
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true,
                  v.volumeIsBrowsable != false, v.volumeIsReadOnly != true,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            return VolumeEntry(url: url, name: v.volumeLocalizedName ?? url.lastPathComponent, total: Int64(total),
                               free: v.volumeAvailableCapacityForImportantUsage ?? 0)
        }
    }
}

struct StartView: View {
    @State private var volumes: [VolumeEntry] = []
    @State private var recents: [URL] = []
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            section("Disks") {
                ForEach(volumes) { v in VolumeRow(volume: v) { AppRouter.shared.open(v.url) } }
            }
            if !recents.isEmpty {
                section("Recent") {
                    ForEach(recents, id: \.self) { url in
                        RecentRow(url: url) { AppRouter.shared.open(url) } remove: {
                            RecentRoots.remove(url)
                            recents.removeAll { $0 == url }
                        }
                    }
                }
            }
            dropZone
        }
        .padding(24)
        .frame(width: 520)
        .containerBackground(.regularMaterial, for: .window)
        .onAppear(perform: reload)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in reload() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in reload() }
        .background(WindowAccessor { w in
            w.tabbingMode = .disallowed
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
        })
    }

    private func reload() {
        volumes = VolumeEntry.mounted()
        recents = RecentRoots.load()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Treemap").font(.largeTitle.weight(.semibold))
                Text("See what fills your disk, then reclaim it.").foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private var dropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.title2)
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text("Drop a folder here")
                .foregroundStyle(dropTargeted ? Color.primary : .secondary)
            Spacer()
            Button("Choose Folder…") { Opener.chooseFolder() }
                .buttonStyle(.glass)
                .keyboardShortcut("o")
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .dropDestination(for: URL.self) { urls, _ in
            let dirs = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            for u in dirs { AppRouter.shared.open(u) }
            return !dirs.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }
}

private struct VolumeRow: View {
    let volume: VolumeEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(nsImage: FileIcon.image(forPath: volume.url.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(volume.name).fontWeight(.medium)
                        Spacer()
                        Text("\(Fmt.bytes(volume.free)) free of \(Fmt.bytes(volume.total))")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ProgressView(value: Double(volume.used), total: Double(max(volume.total, 1)))
                        .progressViewStyle(.linear)
                        .tint(volume.free * 10 < volume.total ? .red : .accentColor)
                }
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: FileIcon.image(forPath: url.path)).resizable().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(FileManager.default.displayName(atPath: url.path))
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 28)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove from Recent")
                .padding(.trailing, 10)
            }
        }
        .onHover { hovering = $0 }
    }
}
