//
//  AVCaptureVideoOrientation.swift
//  CodeDetector
//
//  Created by 门捷夫 on 2018/7/12.
//  Copyright © 2018年 门捷夫. All rights reserved.
//

import Foundation
import AVFoundation

extension AVCaptureVideoOrientation {
  init?(deviceOrientation: UIDeviceOrientation) {
    switch deviceOrientation {
    case .portrait: self = .portrait
    case .portraitUpsideDown: self = .portraitUpsideDown
    case .landscapeLeft: self = .landscapeRight
    case .landscapeRight: self = .landscapeLeft
    default: return nil
    }
  }

  init?(interfaceOrientation: UIInterfaceOrientation) {
    switch interfaceOrientation {
    case .portrait: self = .portrait
    case .portraitUpsideDown: self = .portraitUpsideDown
    case .landscapeLeft: self = .landscapeLeft
    case .landscapeRight: self = .landscapeRight
    default: return nil
    }
  }

}
