//
//  TideCameraView.swift
//  Tide
//
//  In-app camera preview controlled by the ring's photo gesture.
//

@preconcurrency import AVFoundation
import Combine
import Photos
import SwiftUI
import UIKit

struct TideCameraView: View {
    @ObservedObject var manager: RingManager
    @StateObject private var camera = TideCameraController()
    @State private var isVisible = false
    @State private var shutterFlash = false
    @State private var isShowingGallery = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            cameraSurface

            VStack(spacing: 0) {
                statusPill
                    .padding(.top, 12)
                Spacer()
                controls
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
            }

            Color.white
                .opacity(shutterFlash ? 0.82 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
        .fullScreenCover(isPresented: $isShowingGallery) {
            TidePhotoGallery(photos: camera.photos)
        }
        .onAppear {
            isVisible = true
            camera.start()
            armRingCameraIfPossible()
        }
        .onDisappear {
            isVisible = false
            manager.setCameraMode(enabled: false)
            camera.stop()
        }
        .onChange(of: manager.connectionState) { _, state in
            if isVisible, state == .connected {
                manager.setCameraMode(enabled: true)
            }
        }
        .onChange(of: manager.cameraShutterSequence) { _, _ in
            guard isVisible else { return }
            camera.capturePhoto()
        }
        .onChange(of: camera.captureSequence) { _, _ in
            showShutterFlash()
        }
    }

    @ViewBuilder
    private var cameraSurface: some View {
        switch camera.authorizationState {
        case .authorized:
            TideCameraPreview(session: camera.session)
                .ignoresSafeArea()
        case .denied:
            cameraMessage(
                icon: "camera.fill",
                title: "Camera Access Is Off",
                message: "Allow camera access in Settings to take photos with your Tide ring.",
                buttonTitle: "Open Settings",
                action: openSettings
            )
        case .unavailable:
            cameraMessage(
                icon: "camera.badge.ellipsis",
                title: "Camera Unavailable",
                message: "Tide could not find a camera on this device."
            )
        case .notDetermined:
            ProgressView("Preparing camera…")
                .tint(.white)
                .foregroundStyle(.white)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(manager.connectionState == .connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(manager.connectionState == .connected ? "Ring gesture ready" : "Connect your ring to use gestures")
                .font(.caption.weight(.semibold))
            Text("· \(manager.cameraShutterSequence)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.black.opacity(0.58), in: Capsule())
    }

    private var controls: some View {
        HStack {
            Button {
                camera.switchCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel("Switch camera")
            .disabled(!camera.canCapture)

            Spacer()

            Button {
                camera.capturePhoto()
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                    Circle().fill(.white).frame(width: 62, height: 62)
                }
            }
            .accessibilityLabel("Take photo")
            .disabled(!camera.canCapture)

            Spacer()

            Button {
                isShowingGallery = !camera.photos.isEmpty
            } label: {
                Group {
                    if let photo = camera.photos.first {
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.45))
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.8), lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if camera.photos.count > 1 {
                    Text("\(camera.photos.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(5)
                        .background(.white, in: Circle())
                        .offset(x: 7, y: -7)
                }
            }
            .accessibilityLabel("View Tide photos")
            .disabled(camera.photos.isEmpty)
        }
    }

    private func cameraMessage(
        icon: String,
        title: String,
        message: String,
        buttonTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 42))
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(TideColors.accent)
            }
        }
        .foregroundStyle(.white)
        .padding(36)
    }

    private func armRingCameraIfPossible() {
        guard manager.connectionState == .connected else { return }
        manager.setCameraMode(enabled: true)
    }

    private func showShutterFlash() {
        shutterFlash = true
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            shutterFlash = false
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

@MainActor
final class TideCameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    enum AuthorizationState {
        case notDetermined
        case authorized
        case denied
        case unavailable
    }

    let session = AVCaptureSession()

    @Published private(set) var authorizationState: AuthorizationState = .notDetermined
    @Published private(set) var canCapture = false
    @Published private(set) var captureSequence: UInt64 = 0
    @Published private(set) var latestPhoto: UIImage?
    @Published private(set) var photos: [TideCapturedPhoto] = []

    private let photoOutput = AVCapturePhotoOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var isCapturing = false

    override init() {
        super.init()
        loadTideGallery()
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationState = .authorized
            configureAndStart()
        case .notDetermined:
            let controller = self
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                Task { @MainActor in
                    controller.authorizationState = allowed ? .authorized : .denied
                    if allowed { controller.configureAndStart() }
                }
            }
        default:
            authorizationState = .denied
            canCapture = false
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        canCapture = false
    }

    func capturePhoto() {
        guard canCapture, !isCapturing else { return }
        isCapturing = true
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func switchCamera() {
        guard isConfigured, let currentInput = videoInput else { return }
        let newPosition: AVCaptureDevice.Position = currentInput.device.position == .back ? .front : .back
        guard let device = cameraDevice(position: newPosition),
              let newInput = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        session.removeInput(currentInput)
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            videoInput = newInput
        } else {
            session.addInput(currentInput)
        }
        session.commitConfiguration()
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isCapturing = false
            guard let data else { return }
            self.latestPhoto = UIImage(data: data)
            self.saveToTideGallery(data)
            self.captureSequence &+= 1
            self.saveToPhotoLibrary(data)
        }
    }

    private func configureAndStart() {
        guard !isConfigured else {
            if !session.isRunning { session.startRunning() }
            canCapture = session.isRunning
            return
        }

        guard let device = cameraDevice(position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            authorizationState = .unavailable
            canCapture = false
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            authorizationState = .unavailable
            return
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        session.commitConfiguration()

        videoInput = input
        isConfigured = true
        session.startRunning()
        canCapture = session.isRunning
    }

    private func cameraDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    private func saveToPhotoLibrary(_ data: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
        }
    }

    private var tideGalleryDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TideCamera", isDirectory: true)
    }

    private func saveToTideGallery(_ data: Data) {
        let directory = tideGalleryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).photo")
        guard (try? data.write(to: url, options: .atomic)) != nil,
              let image = UIImage(data: data) else { return }
        let photo = TideCapturedPhoto(url: url, thumbnail: thumbnail(for: image), createdAt: Date())
        photos.insert(photo, at: 0)
    }

    private func loadTideGallery() {
        let directory = tideGalleryDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        photos = urls.compactMap { url in
            guard let image = UIImage(contentsOfFile: url.path) else { return nil }
            let values = try? url.resourceValues(forKeys: [.creationDateKey])
            return TideCapturedPhoto(
                url: url,
                thumbnail: thumbnail(for: image),
                createdAt: values?.creationDate ?? .distantPast
            )
        }
        .sorted { $0.createdAt > $1.createdAt }

        if let first = photos.first {
            latestPhoto = UIImage(contentsOfFile: first.url.path)
        }
    }

    private func thumbnail(for image: UIImage) -> UIImage {
        image.preparingThumbnail(of: CGSize(width: 360, height: 360)) ?? image
    }
}

struct TideCapturedPhoto: Identifiable {
    let url: URL
    let thumbnail: UIImage
    let createdAt: Date
    var id: URL { url }
}

private struct TidePhotoGallery: View {
    let photos: [TideCapturedPhoto]
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos) { photo in
                        NavigationLink {
                            TidePhotoViewer(photo: photo)
                        } label: {
                            Image(uiImage: photo.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .containerRelativeFrame(.horizontal, count: 3, spacing: 4)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Tide Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

private struct TidePhotoViewer: View {
    let photo: TideCapturedPhoto

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = UIImage(contentsOfFile: photo.url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView("Photo unavailable", systemImage: "photo")
                    .foregroundStyle(.white)
            }
        }
        .navigationTitle(photo.createdAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
    }
}

private struct TideCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> TideCameraPreviewView {
        let view = TideCameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: TideCameraPreviewView, context: Context) {
        uiView.previewLayer.session = session
    }
}

private final class TideCameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
