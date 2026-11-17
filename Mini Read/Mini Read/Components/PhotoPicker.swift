//
//  PhotoPicker.swift
//  TheNewVellium
//
//  Created by Max Piednes on 2026/5/3.
//

import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct PhotoPickerView: UIViewControllerRepresentable {
    var selectionLimit: Int = 1
    var filter: PHPickerFilter = .images
    var preferredAssetRepresentationMode: PHPickerConfiguration.AssetRepresentationMode = .automatic
    var onPicked: (UIImage?) -> Void
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = selectionLimit
        configuration.filter = filter
        configuration.preferredAssetRepresentationMode = preferredAssetRepresentationMode

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (UIImage?) -> Void
        let onCancel: (() -> Void)?

        init(onPicked: @escaping (UIImage?) -> Void, onCancel: (() -> Void)?) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let provider = results.first?.itemProvider else {
                onCancel?()
                return
            }

            guard provider.canLoadObject(ofClass: UIImage.self) else {
                onPicked(nil)
                return
            }

            provider.loadObject(ofClass: UIImage.self) { object, _ in
                let image = object as? UIImage
                DispatchQueue.main.async {
                    self.onPicked(image)
                }
            }
        }
    }
}
