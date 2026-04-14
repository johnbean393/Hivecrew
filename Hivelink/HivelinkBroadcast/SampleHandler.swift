//
//  SampleHandler.swift
//  HivelinkBroadcast
//

import CoreMedia
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {}

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {}

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {}
}
