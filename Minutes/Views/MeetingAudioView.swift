import SwiftUI
import AVFoundation
import AppKit

/// 会议音频播放器：AVAudioPlayer 薄封装，供历史详情页内嵌回放。
@MainActor
@Observable
final class MeetingAudioPlayer {
    private let player: AVAudioPlayer?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    let duration: TimeInterval
    private var timer: Timer?

    init?(url: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        self.player = player
        player.enableRate = true
        player.prepareToPlay()
        duration = player.duration
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
        currentTime = player.currentTime
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func setRate(_ rate: Float) {
        player?.rate = rate
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.timer?.invalidate()
                }
            }
        }
    }
}

/// 历史详情页的会议音频小节：播放器、Finder 定位、单独删除音频。
/// 无音频（旧会议或已删除）时不显示，优雅降级。
struct MeetingAudioView: View {
    let meeting: Meeting
    @Environment(MeetingsStore.self) private var store
    @State private var player: MeetingAudioPlayer?
    @State private var hasAudio = false
    @State private var confirmsDeletion = false
    @State private var rate: Float = 1

    var body: some View {
        Group {
            if hasAudio, let player {
                VStack(alignment: .leading, spacing: 10) {
                    Label("会议音频", systemImage: "play.circle")
                        .font(.title3).bold()
                    HStack(spacing: 12) {
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 28))
                        }
                        .buttonStyle(.plain)
                        .help(player.isPlaying ? "暂停" : "播放")
                        Slider(
                            value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                            in: 0...max(player.duration, 0.1)
                        )
                        Text("\(Formatters.clock(player.currentTime)) / \(Formatters.clock(player.duration))")
                            .font(.caption)
                            .monospacedDigit()
                        Picker("倍速", selection: $rate) {
                            ForEach([0.5, 1, 1.5, 2], id: \.self) { value in
                                Text(String(format: "%g×", value)).tag(Float(value))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 76)
                        .labelsHidden()
                        .onChange(of: rate) { _, newRate in player.setRate(newRate) }
                    }
                    HStack(spacing: 16) {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.audioURL(for: meeting)])
                        }
                        Button("删除音频", role: .destructive) { confirmsDeletion = true }
                    }
                    .font(.caption)
                }
            }
        }
        .task(id: meeting.id) {
            let url = store.audioURL(for: meeting)
            hasAudio = FileManager.default.fileExists(atPath: url.path)
            player = hasAudio ? MeetingAudioPlayer(url: url) : nil
        }
        .onDisappear { player?.stop() }
        .confirmationDialog("删除会议音频？", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("删除音频", role: .destructive) {
                player?.stop()
                try? store.deleteAudio(for: meeting)
                hasAudio = false
                player = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("音频删除后无法恢复，转写与纪要保留。")
        }
    }
}
