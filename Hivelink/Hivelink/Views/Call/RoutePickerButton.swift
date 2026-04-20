//
//  RoutePickerButton.swift
//  Hivelink
//
//  UIViewRepresentable wrapping AVRoutePickerView for switching audio
//  output to AirPods, HomePod, CarPlay, or other AirPlay destinations.
//

import AVKit
import SwiftUI

struct RoutePickerButton: UIViewRepresentable {
    var activeTintColor: UIColor = .white
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = activeTintColor
        picker.tintColor = tintColor
        picker.prioritizesVideoDevices = false
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentHuggingPriority(.required, for: .vertical)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = activeTintColor
        uiView.tintColor = tintColor
    }
}
