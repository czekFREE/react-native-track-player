import AVFoundation
import XCTest

private final class FailedAVPlayer: AVPlayer {
  override var status: AVPlayer.Status { .failed }
}

final class SwiftAudioExPlaybackRecoveryTests: XCTestCase {
  func testDirectFailureRecreatesPlayer() {
    let wrapper = AVPlayerWrapper()
    let previousPlayer = wrapper.avPlayer
    wrapper.itemFailedToPlayToEndTime()
    XCTAssertEqual(wrapper.state, .failed)

    wrapper.load()

    XCTAssertFalse(wrapper.avPlayer === previousPlayer)
    XCTAssertNotEqual(wrapper.avPlayer.status, .failed)
    XCTAssertNil(wrapper.playbackError)
  }

  func testFailureThenStopThenNextTrackRecreatesPlayer() {
    let wrapper = AVPlayerWrapper()
    wrapper.avPlayer = FailedAVPlayer()
    let failedPlayer = wrapper.avPlayer
    wrapper.itemFailedToPlayToEndTime()
    XCTAssertEqual(wrapper.state, .failed)
    wrapper.stop()
    XCTAssertEqual(wrapper.state, .stopped)
    XCTAssertEqual(wrapper.avPlayer.status, .failed)
    let nextTrack = URL(fileURLWithPath: "/yrt-tests/next-track.mp3")

    wrapper.load(from: nextTrack, playWhenReady: false)

    XCTAssertFalse(wrapper.avPlayer === failedPlayer)
    XCTAssertNotEqual(wrapper.avPlayer.status, .failed)
    XCTAssertNil(wrapper.playbackError)
    XCTAssertEqual(wrapper.url, nextTrack)
  }

  func testFailureThenUnloadThenNextTrackRecreatesPlayer() {
    let wrapper = AVPlayerWrapper()
    wrapper.avPlayer = FailedAVPlayer()
    let failedPlayer = wrapper.avPlayer
    wrapper.itemFailedToPlayToEndTime()
    XCTAssertEqual(wrapper.state, .failed)
    wrapper.unload()
    XCTAssertEqual(wrapper.state, .idle)
    let nextTrack = URL(fileURLWithPath: "/yrt-tests/next-track.mp3")

    wrapper.load(from: nextTrack, playWhenReady: false)

    XCTAssertFalse(wrapper.avPlayer === failedPlayer)
    XCTAssertNotEqual(wrapper.avPlayer.status, .failed)
    XCTAssertNil(wrapper.playbackError)
    XCTAssertEqual(wrapper.url, nextTrack)
  }

  func testFailureThenStopThenSameTrackPlayRecreatesPlayer() {
    let wrapper = AVPlayerWrapper()
    let sameTrack = URL(fileURLWithPath: "/yrt-tests/same-track.mp3")
    wrapper.load(from: sameTrack, playWhenReady: false)
    wrapper.avPlayer = FailedAVPlayer()
    let failedPlayer = wrapper.avPlayer
    wrapper.itemFailedToPlayToEndTime()
    XCTAssertEqual(wrapper.state, .failed)
    wrapper.stop()
    XCTAssertEqual(wrapper.state, .stopped)

    wrapper.play()

    XCTAssertFalse(wrapper.avPlayer === failedPlayer)
    XCTAssertNotEqual(wrapper.avPlayer.status, .failed)
    XCTAssertNil(wrapper.playbackError)
    XCTAssertEqual(wrapper.url, sameTrack)
    XCTAssertTrue(wrapper.playWhenReady)
  }

  func testHealthyStopThenLoadKeepsPlayer() {
    let wrapper = AVPlayerWrapper()
    let healthyPlayer = wrapper.avPlayer
    wrapper.stop()
    XCTAssertEqual(wrapper.state, .stopped)
    let nextTrack = URL(fileURLWithPath: "/yrt-tests/next-track.mp3")

    wrapper.load(from: nextTrack, playWhenReady: false)

    XCTAssertTrue(wrapper.avPlayer === healthyPlayer)
    XCTAssertNotEqual(wrapper.avPlayer.status, .failed)
    XCTAssertEqual(wrapper.url, nextTrack)
  }

}
