//
//  CodeDetectorViewController.swift
//  CodeDetector
//
//  Created by 门捷夫 on 2018/7/12.
//  Copyright © 2018年 门捷夫. All rights reserved.
//

import UIKit
import AVFoundation
import SafariServices

// MARK: - CodeDetectorViewControllerDelegate
public protocol CodeDetectorViewControllerDelegate: class {
  func codeDetector(_ viewController: CodeDetectorViewController, result: String?)
  func codeDetector(_ viewController: CodeDetectorViewController, permission: AVMediaType?, granted: Bool)
  func codeDetector(_ viewController: CodeDetectorViewController, configurationFailed info: String?)
}
// MARK: - Types definition
extension CodeDetectorViewController {
  private enum SessionSetupResult {
    case success
    case notAuthorized
    case configurationFailed
  }

  private class MetadataObjectLayer: CAShapeLayer {
    var metadataObject: AVMetadataObject?
  }

}
// MARK: - AVCaptureMetadataOutputObjectsDelegate
extension CodeDetectorViewController: AVCaptureMetadataOutputObjectsDelegate {
  public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {

  }
}
// MARK: - UIViewController
open class CodeDetectorViewController: UIViewController {
  open weak var delegate: CodeDetectorViewControllerDelegate?
  open private(set) lazy var preview = CodeDetectorPreview()
  open private(set) var previewConstraints = [NSLayoutConstraint]()
  private let session = AVCaptureSession()
  private var isSessionRunning = false
  private let sessionQueue = DispatchQueue(label: "session queue") // Communicate with the session and other session objects on this queue.
  private var setupResult: SessionSetupResult = .success
  var videoDeviceInput: AVCaptureDeviceInput!
  private let metadataOutput = AVCaptureMetadataOutput()
  private let metadataObjectsQueue = DispatchQueue(label: "metadata objects queue", attributes: [], target: nil)
  /**
   A dispatch semaphore is used for drawing metadata object overlays so that
   only one group of metadata object overlays is drawn at a time.
   */
  private let metadataObjectsOverlayLayersDrawingSemaphore = DispatchSemaphore(value: 1)
  private var metadataObjectOverlayLayers = [MetadataObjectLayer]()
  private var removeMetadataObjectOverlayLayersTimer: Timer?
  private var keyValueObservations = [NSKeyValueObservation]()
  private var initialRectOfInterest: CGRect = .zero

  override open func viewDidLoad() {
    super.viewDidLoad()

    // Do any additional setup after loading the view.
    setup()
  }

  open override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    checkAuthorization()
  }

  open override func viewWillDisappear(_ animated: Bool) {
    sessionClear()
    super.viewWillDisappear(animated)
  }

  override open var shouldAutorotate: Bool {
    // Do not allow rotation if the region of interest is being resized.
    return !preview.isResizingRegionOfInterest
  }

  override open func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
    super.viewWillTransition(to: size, with: coordinator)

    if let videoPreviewLayerConnection = preview.videoPreviewLayer.connection {
      let deviceOrientation = UIDevice.current.orientation
      guard let newVideoOrientation = AVCaptureVideoOrientation(deviceOrientation: deviceOrientation),
        deviceOrientation.isPortrait || deviceOrientation.isLandscape else {
          return
      }

      videoPreviewLayerConnection.videoOrientation = newVideoOrientation

      /*
       When we transition to a new size, we need to recalculate the preview
       view's region of interest rect so that it stays in the same
       position relative to the camera.
       */
      coordinator.animate(alongsideTransition: { context in

        let newRegionOfInterest = self.preview.videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: self.metadataOutput.rectOfInterest)
        self.preview.setRegionOfInterestWithProposedRegionOfInterest(newRegionOfInterest)
      },
                          completion: { context in

                            // Remove the old metadata object overlays.
                            self.removeMetadataObjectOverlayLayers()
      }
      )
    }
  }

}

extension CodeDetectorViewController {
  private func setup() {
    view.addSubview(preview)
    preview.translatesAutoresizingMaskIntoConstraints = false
    if #available(iOS 11.0, *) {
      previewConstraints.append(contentsOf: [
        preview.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 0),
        preview.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 0),
        preview.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 0),
        preview.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: 0)])
      NSLayoutConstraint.activate(previewConstraints)
    } else {
      previewConstraints.append(contentsOf: [
        preview.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
        preview.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0),
        preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
        preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0)])
      NSLayoutConstraint.activate(previewConstraints)
    }

    let height = 0.8
    let width = height * Double(min(view.bounds.width, view.bounds.height) / max(view.bounds.width, view.bounds.height))
    let x = (1.0 - width) / 2.0
    let y = (1.0 - height) / 2.0
    initialRectOfInterest = CGRect(x: x, y: y, width: width, height: height)

    // Set up the video preview view.
    preview.session = session
  }

  private func configureSession() {
    if self.setupResult != .success {
      return
    }

    session.beginConfiguration()

    // Add video input.
    do {
      let defaultVideoDevice: AVCaptureDevice?

      // Choose the back wide angle camera if available, otherwise default to the front wide angle camera.

      if #available(iOS 10.0, *) {
        if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
          defaultVideoDevice = backCameraDevice
        } else if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
          // Default to the front wide angle camera if the back wide angle camera is unavailable.
          defaultVideoDevice = frontCameraDevice
        } else {
          defaultVideoDevice = nil
        }
      } else {
        defaultVideoDevice = AVCaptureDevice.default(for: .video)
      }

      guard let videoDevice = defaultVideoDevice else {
        delegate?.codeDetector(self, configurationFailed: "Could not get video device")
        setupResult = .configurationFailed
        session.commitConfiguration()
        return
      }

      let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)

      if session.canAddInput(videoDeviceInput) {
        session.addInput(videoDeviceInput)
        self.videoDeviceInput = videoDeviceInput

        DispatchQueue.main.async {
          /*
           Why are we dispatching this to the main queue?
           Because AVCaptureVideoPreviewLayer is the backing layer for PreviewView and UIView
           can only be manipulated on the main thread.
           Note: As an exception to the above rule, it is not necessary to serialize video orientation changes
           on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.

           Use the status bar orientation as the initial video orientation. Subsequent orientation changes are
           handled by CameraViewController.viewWillTransition(to:with:).
           */
          let statusBarOrientation = UIApplication.shared.statusBarOrientation
          var initialVideoOrientation: AVCaptureVideoOrientation = .portrait
          if statusBarOrientation != .unknown {
            if let videoOrientation = AVCaptureVideoOrientation(interfaceOrientation: statusBarOrientation) {
              initialVideoOrientation = videoOrientation
            }
          }

          self.preview.videoPreviewLayer.connection!.videoOrientation = initialVideoOrientation
        }
      } else {
        delegate?.codeDetector(self, configurationFailed: "Could not add video device input to the session")
        setupResult = .configurationFailed
        session.commitConfiguration()
        return
      }
    } catch {
      delegate?.codeDetector(self, configurationFailed: "Could not create video device input: \(error)")
      setupResult = .configurationFailed
      session.commitConfiguration()
      return
    }

    // Add metadata output.
    if session.canAddOutput(metadataOutput) {
      session.addOutput(metadataOutput)

      // Set this view controller as the delegate for metadata objects.
      metadataOutput.setMetadataObjectsDelegate(self, queue: metadataObjectsQueue)
      metadataOutput.metadataObjectTypes = metadataOutput.availableMetadataObjectTypes // Use all metadata object types by default.

      metadataOutput.rectOfInterest = initialRectOfInterest

      DispatchQueue.main.async {
        let initialRegionOfInterest = self.preview.videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: self.initialRectOfInterest)
        self.preview.setRegionOfInterestWithProposedRegionOfInterest(initialRegionOfInterest)
      }
    } else {
      delegate?.codeDetector(self, configurationFailed: "Could not add metadata output to the session")
      setupResult = .configurationFailed
      session.commitConfiguration()
      return
    }

    session.commitConfiguration()
  }

  private func addObservers() {
    var keyValueObservation: NSKeyValueObservation

    keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
      guard let isSessionRunning = change.newValue else { return }

      DispatchQueue.main.async {

        /*
         After the session stops running, remove the metadata object overlays,
         if any, so that if the view appears again, the previously displayed
         metadata object overlays are removed.
         */
        if !isSessionRunning {
          self.removeMetadataObjectOverlayLayers()
        }

        /*
         When the session starts running, the aspect ratio of the video preview may also change if a new session preset was applied.
         To keep the preview view's region of interest within the visible portion of the video preview, the preview view's region of
         interest will need to be updated.
         */
        if isSessionRunning {
          self.preview.setRegionOfInterestWithProposedRegionOfInterest(self.preview.regionOfInterest)
        }
      }
    }
    keyValueObservations.append(keyValueObservation)

    /*
     Observe the previewView's regionOfInterest to update the AVCaptureMetadataOutput's
     rectOfInterest when the user finishes resizing the region of interest.
     */
    keyValueObservation = preview.observe(\.regionOfInterest, options: .new) { _, change in
      guard let regionOfInterest = change.newValue else { return }

      DispatchQueue.main.async {
        // Ensure we are not drawing old metadata object overlays.
        self.removeMetadataObjectOverlayLayers()

        // Translate the preview view's region of interest to the metadata output's coordinate system.
        let metadataOutputRectOfInterest = self.preview.videoPreviewLayer.metadataOutputRectConverted(fromLayerRect: regionOfInterest)

        // Update the AVCaptureMetadataOutput with the new region of interest.
        self.sessionQueue.async { [weak self] in
          guard let strongSelf = self else { return }
          strongSelf.metadataOutput.rectOfInterest = metadataOutputRectOfInterest
        }
      }
    }
    keyValueObservations.append(keyValueObservation)

    let notificationCenter = NotificationCenter.default

    notificationCenter.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: session)

    /*
     A session can only run when the app is full screen. It will be interrupted
     in a multi-app layout, introduced in iOS 9, see also the documentation of
     AVCaptureSessionInterruptionReason. Add observers to handle these session
     interruptions and show a preview is paused message. See the documentation
     of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
     */
    notificationCenter.addObserver(self, selector: #selector(sessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: session)
    notificationCenter.addObserver(self, selector: #selector(sessionInterruptionEnded), name: .AVCaptureSessionInterruptionEnded, object: session)
  }

  private func checkAuthorization() {
    /*
     Check video authorization status. Video access is required and audio
     access is optional. If audio access is denied, audio is not recorded
     during movie recording.
     */
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      // The user has previously granted access to the camera.
      break

    case .notDetermined:
      /*
       The user has not yet been presented with the option to grant
       video access. We suspend the session queue to delay session
       setup until the access request has completed.
       */
      sessionQueue.suspend()
      AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
        if !granted {
          self.setupResult = .notAuthorized
        }
        self.sessionQueue.resume()
      })

    default:
      // The user has previously denied access.
      setupResult = .notAuthorized
    }

    /*
     Setup the capture session.
     In general it is not safe to mutate an AVCaptureSession or any of its
     inputs, outputs, or connections from multiple threads at the same time.

     Why not do all of this on the main queue?
     Because AVCaptureSession.startRunning() is a blocking call which can
     take a long time. We dispatch session setup to the sessionQueue so
     that the main queue isn't blocked, which keeps the UI responsive.
     */
    sessionQueue.async { [weak self] in
      guard let `self` = self else { return }
      self.configureSession()
    }

    sessionQueue.async { [weak self] in
      guard let `self` = self else { return }
      switch self.setupResult {
      case .success:
        // Only setup observers and start the session running if setup succeeded.
        self.addObservers()
        self.session.startRunning()
        self.isSessionRunning = self.session.isRunning
      case .notAuthorized:
        self.delegate?.codeDetector(self, permission: .video, granted: false)
      case .configurationFailed:
        self.delegate?.codeDetector(self, configurationFailed: "Unable to capture media.")
      }
    }
  }

  private func removeObservers() {
    NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: session)
    NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: session)
    NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)

    for keyValueObservation in keyValueObservations {
      keyValueObservation.invalidate()
    }
    keyValueObservations.removeAll()
  }

  private func sessionClear() {
    sessionQueue.async { [weak self] in
      guard let `self` = self else { return }
      if self.setupResult == .success {
        self.session.stopRunning()
        self.isSessionRunning = self.session.isRunning
        self.removeObservers()
      }
    }
  }


  @objc
  func sessionRuntimeError(notification: NSNotification) {
    guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
    delegate?.codeDetector(self, configurationFailed: "Capture session runtime error: \(error)")

    /*
     Automatically try to restart the session running if media services were
     reset and the last start running succeeded. Otherwise, enable the user
     to try to resume the session running.
     */
    if error.code == .mediaServicesWereReset {
      sessionQueue.async { [weak self] in
        guard let strongSelf = self else { return }
        if strongSelf.isSessionRunning {
          strongSelf.session.startRunning()
          strongSelf.isSessionRunning = strongSelf.session.isRunning
        }
      }
    }
  }

  @objc
  func sessionWasInterrupted(notification: NSNotification) {
    /*
     In some scenarios we want to enable the user to resume the session running.
     For example, if music playback is initiated via control center while
     using AVCamBarcode, then the user can let AVCamBarcode resume
     the session running, which will stop music playback. Note that stopping
     music playback in control center will not automatically resume the session
     running. Also note that it is not always possible to resume, see `resumeInterruptedSession(_:)`.
     */
    if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
      let reasonIntegerValue = userInfoValue.integerValue,
      let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
      delegate?.codeDetector(self, configurationFailed: "Capture session was interrupted with reason \(reason)")
    }
  }

  @objc
  func sessionInterruptionEnded(notification: NSNotification) {
    delegate?.codeDetector(self, configurationFailed: "Capture session interruption ended")
  }

  // MARK: Drawing Metadata Object Overlay Layers

  private func createMetadataObjectOverlayWithMetadataObject(_ metadataObject: AVMetadataObject) -> MetadataObjectLayer {
    // Transform the metadata object so the bounds are updated to reflect those of the video preview layer.
    let transformedMetadataObject = preview.videoPreviewLayer.transformedMetadataObject(for: metadataObject)

    // Create the initial metadata object overlay layer that can be used for either machine readable codes or faces.
    let metadataObjectOverlayLayer = MetadataObjectLayer()
    metadataObjectOverlayLayer.metadataObject = transformedMetadataObject
    metadataObjectOverlayLayer.lineJoin = kCALineJoinRound
    metadataObjectOverlayLayer.lineWidth = 7.0
    metadataObjectOverlayLayer.strokeColor = view.tintColor.withAlphaComponent(0.7).cgColor
    metadataObjectOverlayLayer.fillColor = view.tintColor.withAlphaComponent(0.3).cgColor

    if let barcodeMetadataObject = transformedMetadataObject as? AVMetadataMachineReadableCodeObject {
      delegate?.codeDetector(self, result: barcodeMetadataObject.stringValue)
      let barcodeOverlayPath = barcodeOverlayPathWithCorners(barcodeMetadataObject.corners)
      metadataObjectOverlayLayer.path = barcodeOverlayPath
    } else if let faceMetadataObject = transformedMetadataObject as? AVMetadataFaceObject {
      metadataObjectOverlayLayer.path = CGPath(rect: faceMetadataObject.bounds, transform: nil)
    }

    return metadataObjectOverlayLayer
  }

  private func barcodeOverlayPathWithCorners(_ corners: [CGPoint]) -> CGMutablePath {
    let path = CGMutablePath()

    if let corner = corners.first {
      path.move(to: corner, transform: .identity)

      for corner in corners[1..<corners.count] {
        path.addLine(to: corner)
      }

      path.closeSubpath()
    }

    return path
  }

  @objc
  private func removeMetadataObjectOverlayLayers() {
    for sublayer in metadataObjectOverlayLayers {
      sublayer.removeFromSuperlayer()
    }
    metadataObjectOverlayLayers = []

    removeMetadataObjectOverlayLayersTimer?.invalidate()
    removeMetadataObjectOverlayLayersTimer = nil
  }

  private func addMetadataObjectOverlayLayersToVideoPreviewView(_ metadataObjectOverlayLayers: [MetadataObjectLayer]) {
    // Add the metadata object overlays as sublayers of the video preview layer. We disable actions to allow for fast drawing.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for metadataObjectOverlayLayer in metadataObjectOverlayLayers {
      preview.videoPreviewLayer.addSublayer(metadataObjectOverlayLayer)
    }
    CATransaction.commit()

    // Save the new metadata object overlays.
    self.metadataObjectOverlayLayers = metadataObjectOverlayLayers

    // Create a timer to destroy the metadata object overlays.
    removeMetadataObjectOverlayLayersTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(removeMetadataObjectOverlayLayers), userInfo: nil, repeats: false)
  }

  private func zoomCamera(with factor: Float) {
    do {
      try videoDeviceInput.device.lockForConfiguration()
      videoDeviceInput.device.videoZoomFactor = CGFloat(factor)
      videoDeviceInput.device.unlockForConfiguration()
    } catch {
      delegate?.codeDetector(self, configurationFailed: "Could not lock for configuration: \(error)")
    }
  }

  private func switchCamera() {

    // Remove the metadata overlay layers, if any.
    removeMetadataObjectOverlayLayers()

    DispatchQueue.main.async {
      let currentVideoDevice = self.videoDeviceInput.device
      let currentPosition = currentVideoDevice.position

      let preferredPosition: AVCaptureDevice.Position

      switch currentPosition {
      case .unspecified, .front:
        preferredPosition = .back
      case .back:
        preferredPosition = .front
      }

      let devices: [AVCaptureDevice]
      if #available(iOS 10.0, *) {
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
      } else {
        devices = AVCaptureDevice.devices(for: .video)
      }
      let newVideoDevice = devices.first(where: { $0.position == preferredPosition })

      if let videoDevice = newVideoDevice {
        do {
          let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)

          self.session.beginConfiguration()

          // Remove the existing device input first, since using the front and back camera simultaneously is not supported.
          self.session.removeInput(self.videoDeviceInput)

          /*
           When changing devices, a session preset that may be supported
           on one device may not be supported by another. To allow the
           user to successfully switch devices, we must save the previous
           session preset, set the default session preset (High), and
           attempt to restore it after the new video device has been
           added. For example, the 4K session preset is only supported
           by the back device on the iPhone 6s and iPhone 6s Plus. As a
           result, the session will not let us add a video device that
           does not support the current session preset.
           */
          let previousSessionPreset = self.session.sessionPreset
          self.session.sessionPreset = .high

          if self.session.canAddInput(videoDeviceInput) {
            self.session.addInput(videoDeviceInput)
            self.videoDeviceInput = videoDeviceInput
          } else {
            self.session.addInput(self.videoDeviceInput)
          }

          // Restore the previous session preset if we can.
          if self.session.canSetSessionPreset(previousSessionPreset) {
            self.session.sessionPreset = previousSessionPreset
          }

          self.session.commitConfiguration()
        } catch {
          self.delegate?.codeDetector(self, configurationFailed: "Error occured while creating video device input: \(error)")
        }
      }
    }
  }

  private func setMetadataObjectTypes(_ types: [AVMetadataObject.ObjectType]) {
    sessionQueue.async { [weak self] in
      guard let strongSelf = self else { return }
      strongSelf.metadataOutput.metadataObjectTypes = types
    }
  }

  private func setSessionPreset(_ preset: AVCaptureSession.Preset) {
    sessionQueue.async { [weak self] in
      guard let strongSelf = self else { return }
      strongSelf.session.sessionPreset = preset
    }
  }

}
