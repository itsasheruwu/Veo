import AVFoundation
import SwiftUI

struct VeoPrismView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    Rectangle().fill(.black).overlay {
      Image("VeoPrism").resizable().scaledToFill()
      if !reduceMotion { PrismMovie() }
    }.clipped().accessibilityHidden(true).allowsHitTesting(false)
  }
}

private struct PrismMovie: NSViewRepresentable {
  class Surface: NSView {
    let player = AVQueuePlayer()
    var loop: AVPlayerLooper?
    override init(frame: NSRect) {
      super.init(frame: frame)
      let video = AVPlayerLayer(player: player)
      video.videoGravity = .resizeAspectFill
      layer = video
      wantsLayer = true
      player.isMuted = true
      if let url = Bundle.main.url(forResource: "VeoPrism", withExtension: "mp4") {
        loop = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
      }
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil { player.pause() } else { player.play() }
    }
  }
  func makeNSView(context: Context) -> Surface { Surface(frame: .zero) }
  func updateNSView(_ view: Surface, context: Context) {}
}
