//
//  OPFDocument.swift
//  Bookbinder
//
//  Created by Stone Zhang on 4/21/19.
//  Copyright © 2019 Stone Zhang. All rights reserved.
//

import Kanna
import Foundation

// https://www.w3.org/Submission/2017/SUBM-epub-packages-20170125/
// https://www.w3.org/Submission/2017/SUBM-epub-packages-20170125/#sec-package-def
// http://www.idpf.org/epub/301/spec/epub-publications.html#sec-guide-elem



public struct OPFDocument {

    public let uniqueIdentifierID: String
    public let metadata: OPFMetadata
    public let manifest: OPFManifest
    public let spine: OPFSpine



    public let document: Kanna.XMLDocument

    init?(url: URL) {
        do {
            document = try Kanna.XML(xml: try Data(contentsOf: url), encoding: .utf8)
            
            guard let package = document.at_xpath("/opf:package", namespaces: XPath.opf.namespace) else { return nil }
            // `unique-identifier` 规范要求必填，但它只服务于 `uniqueID` / `releaseID`
            // 这两个当前无人消费的属性。为它整本拒绝解析，代价太大。
            let uid = package["unique-identifier"] ?? ""
            
            guard let metadata = OPFMetadata(package: package) else { return nil }
            guard let manifest = OPFManifest(package: package) else { return nil }
            guard let spine = OPFSpine(package: package) else { return nil }
            
            uniqueIdentifierID = uid
            self.metadata = metadata
            self.manifest = manifest
            self.spine = spine
            
        } catch {
            print("Parsing the XML file at \(url) failed with error: \(error)")
            return nil
        }
    }
}


