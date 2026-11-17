//
//  ContainerDocument.swift
//  Bookbinder
//
//  Created by Stone Zhang on 5/1/19.
//  Copyright © 2019 Stone Zhang. All rights reserved.
//

import Kanna
import Foundation

public struct ContainerDocument {
    public let opfPath: String

    public let document: Kanna.XMLDocument

    init?(xmlurl: URL) {
        do {
            let xml = try Data(contentsOf: xmlurl)
            document = try Kanna.XML(xml: xml, encoding: .utf8)
            
            let xpath = "//container:rootfile[@full-path]/@full-path"
            guard let path = document.at_xpath(xpath, namespaces: XPath.container.namespace)?.text else { return nil }
            opfPath = path
        } catch {
            print("Parsing the XML file at \(xmlurl) failed with error: \(error)")
            return nil
        }
    }
}
